/*
 * Wingpanel half of the Pantheon global menu (PoC): the focused app's menus
 * as a real Gtk.MenuBar in the panel, next to Applications.
 *
 * Which window has focus, and where its menu lives, comes from the Gala
 * plugin in ../gala over io.github.arsfeld.PantheonGlobalMenu. Two kinds of menu:
 *
 *   - org.gtk.Menus (GTK apps): a DBusMenuModel plus the app's "app", "win"
 *     and "unity" action groups, bound straight into the menubar. Checkmarks,
 *     greyed-out items and accelerators come for free.
 *   - com.canonical.dbusmenu (Qt/Electron/Chromium/Firefox under XWayland):
 *     libdbusmenu-gtk3 builds the Gtk.MenuItems.
 *
 * Every menu change logs one "GlobalMenu: <app> <kind>" line.
 */
[DBus (name = "io.github.arsfeld.PantheonGlobalMenu")]
interface GlobalMenu.MenuSource : Object {
    public abstract HashTable<string, Variant> get_active () throws DBusError, IOError;
    public abstract async void send_keys (uint[] keyvals, uint[] modifiers) throws DBusError, IOError;
    public signal void active_changed (HashTable<string, Variant> menu);
}

delegate void GlobalMenu.Rebuild ();

public class GlobalMenu.Indicator : Wingpanel.Indicator {
    private const string CSS = """
        .globalmenu menubar,
        .globalmenu menubar > menuitem {
            background: none;
            border: none;
            box-shadow: none;
            padding: 0 6px;
            min-height: 0;
        }
        .globalmenu menubar > menuitem:first-child label {
            font-weight: bold;
        }
        /* GTK3 menus inherit style from the widget they are attached to, so
           without this the dropdowns pick up Wingpanel's panel-text shadow
           (.composited-indicator) and every label looks blurred. */
        menu, menu * {
            text-shadow: none;
            -gtk-icon-shadow: none;
            font-weight: normal;
        }
    """;

    private Gtk.Box? box = null;
    private Gtk.MenuBar? bar = null;
    private MenuSource? source = null;
    private DBusConnection? bus = null;
    private DbusmenuGtk.Client? dbusmenu = null;
    private string last = "";
    private bool moved = false;
    private Shortcuts shortcuts = new Shortcuts ();
    private SimpleActionGroup shortcut_actions = new SimpleActionGroup ();

    public Indicator () {
        Object (code_name: "globalmenu");
    }

    construct {
        // Always visible: Wingpanel re-inserts an indicator into the right-hand
        // bar every time it becomes visible, which would undo move_left ().
        visible = true;

        var send = new SimpleAction ("send", VariantType.STRING);
        send.activate.connect ((param) => send_shortcut.begin (param.get_string ()));
        shortcut_actions.add_action (send);
    }

    private async void send_shortcut (string shortcut) {
        uint[] keyvals = {}, modifiers = {};
        if (source == null || !Shortcuts.parse (shortcut, out keyvals, out modifiers)) {
            return;
        }
        try {
            yield source.send_keys (keyvals, modifiers);
        } catch (Error e) {
            message ("GlobalMenu: SendKeys %s failed: %s", shortcut, e.message);
        }
    }

    public override Gtk.Widget get_display_widget () {
        if (box == null) {
            var css = new Gtk.CssProvider ();
            try {
                css.load_from_data (CSS);
            } catch (Error e) {
                warning ("GlobalMenu: %s", e.message);
            }
            Gtk.StyleContext.add_provider_for_screen (Gdk.Screen.get_default (), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

            box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            box.get_style_context ().add_class ("globalmenu");
            box.map.connect (() => Idle.add (() => {
                move_left ();
                return Source.REMOVE;
            }));
            connect_source.begin ();
            add_test_hook ();
        }
        return box;
    }

    /* Clicks land on the menubar; this only shows if one falls between items. */
    public override Gtk.Widget? get_widget () {
        return new Gtk.Label ("No menu") { margin = 12 };
    }

    public override void opened () {}
    public override void closed () {}

    /*
     * Wingpanel puts every indicator but the app launcher and the clock on the
     * right. A global menu belongs on the left, so once our entry is in the
     * panel, move it from the right-hand bar to the end of the left-hand one.
     * Widget tree: panel box > IndicatorBar > IndicatorEntry > Revealer > box.
     */
    private void move_left () {
        if (moved || box == null) {
            return;
        }
        var entry = box.get_parent ()?.get_parent ();
        var right = entry?.get_parent () as Gtk.Box;
        var panel = right?.get_parent () as Gtk.Box;
        if (entry == null || right == null || panel == null) {
            return;
        }
        Gtk.Box? left = null;
        foreach (var child in panel.get_children ()) {
            if (child != right && child != panel.get_center_widget () && child is Gtk.Box) {
                left = (Gtk.Box) child;
                break;
            }
        }
        if (left == null) {
            return;
        }
        entry.ref ();
        right.remove (entry);
        left.add (entry);
        entry.unref ();
        moved = true;
    }

    private async void connect_source () {
        try {
            bus = yield Bus.get (BusType.SESSION);
            source = yield bus.get_proxy<MenuSource> ("io.github.arsfeld.PantheonGlobalMenu", "/io/github/arsfeld/PantheonGlobalMenu");
            source.active_changed.connect (show_menu);
            // The plugin may (re)appear after us; refetch whenever it owns the name.
            ((DBusProxy) source).notify["g-name-owner"].connect (fetch);
            fetch ();
        } catch (Error e) {
            message ("GlobalMenu: no source: %s", e.message);
        }
    }

    private void fetch () {
        if (((DBusProxy) source).g_name_owner == null) {
            show_menu (new HashTable<string, Variant> (str_hash, str_equal));
            return;
        }
        try {
            show_menu (source.get_active ());
        } catch (Error e) {
            message ("GlobalMenu: GetActive failed: %s", e.message);
        }
    }

    private static string? str (HashTable<string, Variant> menu, string key) {
        var value = menu[key];
        return value != null && value.is_of_type (VariantType.STRING) ? value.get_string () : null;
    }

    /* The app's name from its desktop file, falling back to the window title. */
    private static string app_name (HashTable<string, Variant> menu) {
        var id = str (menu, "app-id");
        if (id != null) {
            foreach (var candidate in new string[] { id, id.down () }) {
                var info = new DesktopAppInfo (candidate + ".desktop");
                if (info != null) {
                    return info.get_name ();
                }
            }
        }
        return str (menu, "title") ?? id ?? "";
    }

    private void show_menu (HashTable<string, Variant> menu) {
        Variant serialized = menu;
        var printed = serialized.print (false);
        if (printed == last) {
            return;
        }
        last = printed;

        if (bar != null) {
            bar.destroy ();
            bar = null;
        }
        dbusmenu = null;

        var name = app_name (menu);
        var bus_name = str (menu, "bus-name");
        var menubar_path = str (menu, "menubar-path");
        var dbusmenu_name = str (menu, "dbusmenu-bus-name");
        var dbusmenu_path = str (menu, "dbusmenu-path");

        var mapping = shortcuts.find ({
            str (menu, "app-id"), str (menu, "sandboxed-app-id"),
            str (menu, "wm-class"), str (menu, "wm-class-instance"), name
        });

        string kind;
        if (mapping != null && mapping.blank) {
            kind = "blank";
        } else if (bus_name != null && menubar_path != null) {
            bar = gtk_menubar (name, menu, bus_name, menubar_path);
            kind = "gtk";
        } else if (dbusmenu_name != null && dbusmenu_path != null) {
            bar = dbus_menubar (name, dbusmenu_name, dbusmenu_path);
            kind = "dbusmenu";
        } else if (mapping != null) {
            bar = gtk_menubar (name, menu, bus_name, null, mapping);
            kind = "shortcuts";
        } else if (name != "") {
            bar = gtk_menubar (name, menu, bus_name, null);
            kind = "none";
        } else {
            kind = "empty";
        }
        message ("GlobalMenu: %s %s", name, kind);

        if (bar != null) {
            box.add (bar);
            bar.show_all ();
        }
    }

    /*
     * Test hook: the panel's exported action "globalmenu-open" (int32 n) pops
     * the n-th top-level menu, so a screenshot can show it without injecting
     * input:
     *   gdbus call --session --dest org.elementary.wingpanel \
     *     --object-path /org/elementary/wingpanel \
     *     --method org.gtk.Actions.Activate globalmenu-open "[<1>]" "{}"
     */
    private void add_test_hook () {
        var app = GLib.Application.get_default ();
        if (app == null) {
            return;
        }
        var open = new SimpleAction ("globalmenu-open", VariantType.INT32);
        open.activate.connect ((param) => {
            if (bar == null) {
                return;
            }
            var item = bar.get_children ().nth_data (param.get_int32 ()) as Gtk.MenuItem;
            var submenu = item?.submenu as Gtk.Menu;
            if (submenu != null) {
                submenu.popup_at_widget (item, Gdk.Gravity.SOUTH_WEST, Gdk.Gravity.NORTH_WEST, null);
            }
        });
        app.add_action (open);
    }

    /*
     * The bold app-name menu first (the app menu if it exports one, else
     * Quit), then the exported menubar as a section, which GTK flattens into
     * top-level items.
     */
    private Gtk.MenuBar gtk_menubar (string name, HashTable<string, Variant> menu, string? bus_name, string? menubar_path, Mapping? mapping = null) {
        var model = new GLib.Menu ();
        MenuModel? app_menu = null;
        var app_menu_path = str (menu, "app-menu-path");
        if (bus_name != null && app_menu_path != null) {
            app_menu = DBusMenuModel.get (bus, bus_name, app_menu_path);
        }
        if (app_menu == null) {
            var quit = new GLib.Menu ();
            quit.append ("Quit %s".printf (name), "app.quit");
            app_menu = quit;
        }
        model.append_submenu (name, app_menu);
        if (bus_name != null && menubar_path != null) {
            model.append_section (null, DBusMenuModel.get (bus, bus_name, menubar_path));
        } else if (mapping != null) {
            mapping.append_to (model);
        }

        var menubar = new Gtk.MenuBar.from_model (model);
        menubar.insert_action_group ("globalmenu", shortcut_actions);
        if (bus_name != null) {
            var prefixes = new HashTable<string, string> (str_hash, str_equal);
            prefixes["app"] = "app-path";
            prefixes["win"] = "window-path";
            prefixes["unity"] = "menubar-path";
            prefixes.foreach ((prefix, key) => {
                var path = str (menu, key);
                if (path != null) {
                    menubar.insert_action_group (prefix, DBusActionGroup.get (bus, bus_name, path));
                }
            });
        }
        return menubar;
    }

    private Gtk.MenuBar dbus_menubar (string name, string bus_name, string path) {
        var menubar = new Gtk.MenuBar ();
        menubar.append (new Gtk.MenuItem.with_label (name) { submenu = new Gtk.Menu () });

        var client = new DbusmenuGtk.Client (bus_name, path);
        dbusmenu = client;
        var items = new GenericArray<Gtk.Widget> ();
        unowned Gtk.MenuBar weak_bar = menubar;

        // Rebuilds the top level whenever the layout changes. The client makes
        // a Gtk.MenuItem, submenu included, for every dbusmenu item and keeps
        // it current; only the top level is ours to place.
        Rebuild rebuild = () => {
            foreach (var item in items) {
                weak_bar.remove (item);
            }
            items.length = 0;
            var root = client.get_root ();
            if (root == null) {
                return;
            }
            foreach (var child in root.get_children ()) {
                var item = client.menuitem_get (child);
                if (item == null) {
                    continue;
                }
                item.get_parent ()?.remove (item);
                weak_bar.append (item);
                items.add (item);
            }
            weak_bar.show_all ();
        };
        client.root_changed.connect ((obj) => {
            var root = obj as Dbusmenu.Menuitem;
            if (root != null) {
                root.child_added.connect (() => rebuild ());
                root.child_removed.connect (() => rebuild ());
                root.child_moved.connect (() => rebuild ());
            }
            rebuild ();
        });
        client.layout_updated.connect (() => rebuild ());
        return menubar;
    }
}

public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.IndicatorManager.ServerType server_type) {
    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }
    return new GlobalMenu.Indicator ();
}
