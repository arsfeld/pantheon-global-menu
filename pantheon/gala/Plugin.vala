/*
 * Gala half of the Pantheon global menu (PoC).
 *
 * On Wayland only the compositor knows which window has focus and where that
 * window's menu lives, so this plugin publishes it on the session bus as
 * io.github.arsfeld.PantheonGlobalMenu for the Wingpanel indicator to draw:
 *
 *   - GTK apps (Wayland or X11) that export a menubar over org.gtk.Menus:
 *     mutter already holds the unique bus name and the object paths.
 *   - X11 apps that use com.canonical.dbusmenu (Qt, Electron, Chromium,
 *     Firefox under XWayland): they register with
 *     com.canonical.AppMenu.Registrar, keyed by X window id, which this
 *     plugin also implements. It lives in the compositor because it must be
 *     on the bus before those apps start, and Gala outlives the panel.
 *
 * A crash here takes the whole session down, so nothing in this file throws
 * past a handler and nothing touches the stage.
 */
namespace GlobalMenu {
    [DBus (name = "com.canonical.AppMenu.Registrar")]
    public class Registrar : Object {
        private struct Entry {
            string service;
            ObjectPath path;
        }

        private HashTable<uint, Entry?> windows = new HashTable<uint, Entry?> (direct_hash, direct_equal);

        public signal void window_registered (uint window_id, string service, ObjectPath path);
        public signal void window_unregistered (uint window_id);

        [DBus (visible = false)]
        public signal void changed (uint window_id);

        public void register_window (uint window_id, ObjectPath menu_object_path, BusName sender) throws DBusError, IOError {
            windows[window_id] = Entry () { service = sender, path = menu_object_path };
            window_registered (window_id, sender, menu_object_path);
            changed (window_id);
        }

        public void unregister_window (uint window_id) throws DBusError, IOError {
            if (windows.remove (window_id)) {
                window_unregistered (window_id);
                changed (window_id);
            }
        }

        public void get_menu_for_window (uint window_id, out string service, out ObjectPath menu_object_path) throws DBusError, IOError {
            var entry = windows[window_id];
            service = entry != null ? entry.service : "";
            menu_object_path = new ObjectPath (entry != null ? (string) entry.path : "/");
        }

        [DBus (visible = false)]
        public bool lookup (uint window_id, out string service, out string path) {
            var entry = windows[window_id];
            service = entry != null ? entry.service : "";
            path = entry != null ? (string) entry.path : "";
            return entry != null;
        }

        /* Drops every window a client registered once it leaves the bus. */
        [DBus (visible = false)]
        public void name_vanished (string unique_name) {
            uint[] gone = {};
            windows.foreach ((id, entry) => {
                if (entry.service == unique_name) {
                    gone += id;
                }
            });
            foreach (var id in gone) {
                windows.remove (id);
                window_unregistered (id);
                changed (id);
            }
        }
    }

    [DBus (name = "io.github.arsfeld.PantheonGlobalMenu")]
    public class Service : Object {
        [DBus (visible = false)]
        public HashTable<string, Variant> active = new HashTable<string, Variant> (str_hash, str_equal);

        [DBus (visible = false)]
        public signal void send_keys_requested (uint[] keyvals, uint[] modifiers);

        public HashTable<string, Variant> get_active () throws DBusError, IOError {
            return active;
        }

        /*
         * Types a shortcut into the tracked window: one chord per index,
         * modifiers as a Gdk.ModifierType mask. Only the panel may call it,
         * since it injects keystrokes into whatever app has focus.
         */
        public async void send_keys (uint[] keyvals, uint[] modifiers, BusName sender) throws DBusError, IOError {
            if (keyvals.length != modifiers.length || keyvals.length == 0) {
                throw new DBusError.INVALID_ARGS ("keyvals and modifiers must be non-empty and the same length");
            }
            var conn = yield Bus.get (BusType.SESSION);
            string owner;
            try {
                var reply = yield conn.call (
                    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
                    new Variant ("(s)", "org.elementary.wingpanel"), new VariantType ("(s)"), DBusCallFlags.NONE, -1
                );
                reply.get ("(s)", out owner);
            } catch (Error e) {
                throw new DBusError.ACCESS_DENIED ("the panel is not running");
            }
            if (owner != sender) {
                throw new DBusError.ACCESS_DENIED ("only the panel may send keys");
            }
            send_keys_requested (keyvals, modifiers);
        }

        public signal void active_changed (HashTable<string, Variant> menu);
    }

    public class Plugin : Gala.Plugin {
        private Meta.Display display;
        private Service service = new Service ();
        private Registrar registrar = new Registrar ();
        private Meta.Window? tracked = null;
        private ulong[] tracked_handlers = {};
        private string last = "";
        private Clutter.VirtualInputDevice? keyboard = null;

        // Gdk.ModifierType bits, without linking GDK into the compositor.
        private const uint SHIFT_MASK = 1 << 0;
        private const uint CONTROL_MASK = 1 << 2;
        private const uint ALT_MASK = 1 << 3;
        private const uint SUPER_MASK = 1 << 26;
        // The X keysyms for the left-hand modifier keys.
        private const uint SHIFT_L = 0xffe1;
        private const uint CONTROL_L = 0xffe3;
        private const uint ALT_L = 0xffe9;
        private const uint SUPER_L = 0xffeb;

        public override void initialize (Gala.WindowManager wm) {
            display = wm.get_display ();
            service.send_keys_requested.connect (send_keys);
            display.notify["focus-window"].connect (on_focus_changed);
            registrar.changed.connect ((id) => {
                if (tracked != null && xid_of (tracked) == id) {
                    publish ();
                }
            });

            Bus.own_name (BusType.SESSION, "io.github.arsfeld.PantheonGlobalMenu", BusNameOwnerFlags.NONE, (conn) => {
                try {
                    conn.register_object ("/io/github/arsfeld/PantheonGlobalMenu", service);
                } catch (Error e) {
                    warning ("GlobalMenu: cannot export service: %s", e.message);
                }
            }, null, () => warning ("GlobalMenu: lost io.github.arsfeld.PantheonGlobalMenu"));

            Bus.own_name (BusType.SESSION, "com.canonical.AppMenu.Registrar", BusNameOwnerFlags.NONE, (conn) => {
                try {
                    conn.register_object ("/com/canonical/AppMenu/Registrar", registrar);
                } catch (Error e) {
                    warning ("GlobalMenu: cannot export registrar: %s", e.message);
                }
                conn.signal_subscribe (
                    "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
                    "/org/freedesktop/DBus", null, DBusSignalFlags.NONE,
                    (c, sender, path, iface, name, parameters) => {
                        string bus_name, old_owner, new_owner;
                        parameters.get ("(sss)", out bus_name, out old_owner, out new_owner);
                        if (new_owner == "" && bus_name.has_prefix (":")) {
                            registrar.name_vanished (bus_name);
                        }
                    }
                );
            }, null, () => message ("GlobalMenu: another process owns the AppMenu registrar"));

            on_focus_changed ();
        }

        public override void destroy () {
            untrack ();
            keyboard = null;
        }

        /*
         * Gives the tracked window focus back (clicking the panel may have taken
         * it), waits for the menu to drop its grab, then plays each chord on a
         * virtual keyboard: modifiers down, key down and up, modifiers up.
         */
        private void send_keys (uint[] keyvals, uint[] modifiers) {
            var window = tracked;
            if (window == null) {
                return;
            }
            window.activate (display.get_current_time_roundtrip ());
            uint[] keys = keyvals;
            uint[] mods = modifiers;
            Timeout.add (100, () => {
                if (tracked != window) {
                    return Source.REMOVE;
                }
                if (keyboard == null) {
                    keyboard = default_seat ().create_virtual_device (Clutter.InputDeviceType.KEYBOARD_DEVICE);
                }
                var t = get_monotonic_time ();
                for (var i = 0; i < keys.length; i++) {
                    uint[] held = {};
                    if ((mods[i] & CONTROL_MASK) != 0) held += CONTROL_L;
                    if ((mods[i] & SHIFT_MASK) != 0) held += SHIFT_L;
                    if ((mods[i] & ALT_MASK) != 0) held += ALT_L;
                    if ((mods[i] & SUPER_MASK) != 0) held += SUPER_L;
                    foreach (var m in held) {
                        keyboard.notify_keyval (t += 10, m, Clutter.KeyState.PRESSED);
                    }
                    keyboard.notify_keyval (t += 10, keys[i], Clutter.KeyState.PRESSED);
                    keyboard.notify_keyval (t += 10, keys[i], Clutter.KeyState.RELEASED);
                    for (var j = held.length - 1; j >= 0; j--) {
                        keyboard.notify_keyval (t += 10, held[j], Clutter.KeyState.RELEASED);
                    }
                    // Space chords apart so a prefix key (Emacs's C-x) is seen alone.
                    t += 1000;
                }
                return Source.REMOVE;
            });
        }

        /* The seat lookup moved twice; these are gala's own variants (InternalUtils.bell_notify). */
        private Clutter.Seat default_seat () {
#if HAS_MUTTER48
            return display.get_compositor ().get_stage ().context.get_backend ().get_default_seat ();
#elif HAS_MUTTER47
            return display.get_stage ().context.get_backend ().get_default_seat ();
#else
            return Clutter.get_default_backend ().get_default_seat ();
#endif
        }

        /*
         * Only ordinary app windows move the menu. Focus passing to the panel,
         * the dock, a popup menu or the desktop keeps the last app's menu,
         * otherwise clicking the menu bar would empty it.
         */
        private static bool is_app_window (Meta.Window window) {
            var type = window.get_window_type ();
            if (type != Meta.WindowType.NORMAL && type != Meta.WindowType.DIALOG && type != Meta.WindowType.MODAL_DIALOG) {
                return false;
            }
            if (window.is_skip_taskbar ()) {
                return false;
            }
            var id = app_id_of (window);
            return !(id.has_prefix ("io.elementary.wingpanel") || id.has_prefix ("io.elementary.dock"));
        }

        private static string app_id_of (Meta.Window window) {
            var id = window.get_gtk_application_id () ?? window.get_sandboxed_app_id () ?? window.get_wm_class () ?? "";
            return id;
        }

        private static uint xid_of (Meta.Window window) {
            if (window.get_client_type () != Meta.WindowClientType.X11) {
                return 0;
            }
            ulong xid = 0;
            window.get ("xwindow", out xid);
            return (uint) xid;
        }

        private void on_focus_changed () {
            var window = display.get_focus_window ();
            if (window == null || !is_app_window (window)) {
                return;
            }
            // A dialog gets its parent's menu, the way macOS keeps the app's bar.
            var parent = window.get_transient_for ();
            if (parent != null && window.get_gtk_menubar_object_path () == null) {
                window = parent;
            }
            if (window == tracked) {
                return;
            }
            untrack ();
            tracked = window;
            // GTK sets its D-Bus paths after mapping, and titles change.
            tracked_handlers = {
                window.notify["gtk-menubar-object-path"].connect (publish),
                window.notify["gtk-unique-bus-name"].connect (publish),
                window.notify["title"].connect (publish),
                window.unmanaging.connect (() => {
                    untrack ();
                    publish ();
                }),
            };
            publish ();
        }

        private void untrack () {
            if (tracked != null) {
                foreach (var id in tracked_handlers) {
                    SignalHandler.disconnect (tracked, id);
                }
            }
            tracked_handlers = {};
            tracked = null;
        }

        private static void put (HashTable<string, Variant> table, string key, string? value) {
            if (value != null && value != "") {
                table[key] = new Variant.string (value);
            }
        }

        private void publish () {
            var table = new HashTable<string, Variant> (str_hash, str_equal);
            var window = tracked;
            if (window != null) {
                put (table, "app-id", app_id_of (window));
                put (table, "wm-class", window.get_wm_class ());
                put (table, "wm-class-instance", window.get_wm_class_instance ());
                put (table, "sandboxed-app-id", window.get_sandboxed_app_id ());
                put (table, "title", window.get_title ());
                put (table, "bus-name", window.get_gtk_unique_bus_name ());
                put (table, "app-path", window.get_gtk_application_object_path ());
                put (table, "window-path", window.get_gtk_window_object_path ());
                put (table, "menubar-path", window.get_gtk_menubar_object_path ());
                put (table, "app-menu-path", window.get_gtk_app_menu_object_path ());
                string dbusmenu_service, dbusmenu_path;
                if (registrar.lookup (xid_of (window), out dbusmenu_service, out dbusmenu_path)) {
                    put (table, "dbusmenu-bus-name", dbusmenu_service);
                    put (table, "dbusmenu-path", dbusmenu_path);
                }
            }
            Variant serialized = table;
            var printed = serialized.print (false);
            if (printed == last) {
                return;
            }
            last = printed;
            message ("GlobalMenu: %s", printed);
            service.active = table;
            service.active_changed (table);
        }
    }
}

public Gala.PluginInfo register_plugin () {
    return Gala.PluginInfo () {
        name = "Global Menu",
        author = "arsfeld",
        plugin_type = typeof (GlobalMenu.Plugin),
        provides = Gala.PluginFunction.ADDITION,
        load_priority = Gala.LoadPriority.IMMEDIATE
    };
}
