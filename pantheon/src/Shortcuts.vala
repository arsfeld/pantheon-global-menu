/*
 * Shortcut menus for apps that publish no menu of their own, read from
 * orbit-global-menu's mapping files (format 1, see its
 * docs/shortcut-mappings.md). Each item carries a GTK-style accelerator, and
 * choosing it asks the Gala plugin to type that shortcut into the window.
 *
 * Files in the user directory replace the built-in file of the same name.
 */
[CCode (cname = "SHORTCUTS_DIR")]
extern const string SHORTCUTS_DIR;

public class GlobalMenu.Mapping : Object {
    public string name { get; construct; }
    public bool blank { get; construct; }
    public Json.Array menus { get; construct; }

    public Mapping (string name, bool blank, Json.Array menus) {
        Object (name: name, blank: blank, menus: menus);
    }

    /*
     * The menubar sections: one submenu per top-level menu. Items point at
     * "globalmenu.send" with the shortcut as target; an item without a usable
     * shortcut points at an action that does not exist, which GTK greys out.
     */
    public void append_to (GLib.Menu bar) {
        menus.foreach_element ((array, index, node) => {
            var menu = node.get_object ();
            if (menu != null && menu.has_member ("label") && menu.has_member ("items")) {
                bar.append_submenu (menu.get_string_member ("label"), build (menu.get_array_member ("items")));
            }
        });
    }

    private static GLib.Menu build (Json.Array items) {
        var menu = new GLib.Menu ();
        var section = new GLib.Menu ();
        items.foreach_element ((array, index, node) => {
            var item = node.get_object ();
            if (item == null) {
                return;
            }
            if (item.has_member ("separator") && item.get_boolean_member ("separator")) {
                if (section.get_n_items () > 0) {
                    menu.append_section (null, section);
                }
                section = new GLib.Menu ();
                return;
            }
            if (!item.has_member ("label")) {
                return;
            }
            var label = item.get_string_member ("label");
            if (item.has_member ("items")) {
                section.append_submenu (label, build (item.get_array_member ("items")));
                return;
            }
            var entry = new GLib.MenuItem (label, null);
            var shortcut = item.has_member ("shortcut") ? item.get_string_member ("shortcut") : null;
            uint[] keyvals = {}, modifiers = {};
            if (shortcut != null && Shortcuts.parse (shortcut, out keyvals, out modifiers)) {
                entry.set_action_and_target_value ("globalmenu.send", new Variant.string (shortcut));
                if (keyvals.length == 1) {
                    entry.set_attribute_value ("accel", new Variant.string (Gtk.accelerator_name (keyvals[0], (Gdk.ModifierType) modifiers[0])));
                }
            } else {
                if (shortcut != null) {
                    message ("GlobalMenu: unparseable shortcut %s", shortcut);
                }
                entry.set_action_and_target_value ("globalmenu.unavailable", null);
            }
            section.append_item (entry);
        });
        if (section.get_n_items () > 0) {
            menu.append_section (null, section);
        }
        return menu;
    }
}

public class GlobalMenu.Shortcuts : Object {
    // Lowercased identifier -> mapping. The first file claiming one wins.
    private HashTable<string, Mapping> by_identifier = new HashTable<string, Mapping> (str_hash, str_equal);

    construct {
        var files = new HashTable<string, File> (str_hash, str_equal);
        var user = Path.build_filename (Environment.get_user_config_dir (), "global-menu", "shortcuts", "apps");
        // Built-ins first, then the user's, so a user file replaces its namesake.
        foreach (var dir in new string[] { SHORTCUTS_DIR, user }) {
            try {
                var enumerator = File.new_for_path (dir).enumerate_children (FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NONE);
                FileInfo? info;
                while ((info = enumerator.next_file ()) != null) {
                    if (info.get_name ().has_suffix (".json")) {
                        files[info.get_name ()] = enumerator.get_child (info);
                    }
                }
            } catch (Error e) {
                // A missing user directory is normal.
            }
        }

        var names = files.get_keys ();
        names.sort (strcmp);
        foreach (var name in names) {
            load (files[name]);
        }
        message ("GlobalMenu: %u shortcut identifiers from %u files", by_identifier.size (), files.size ());
    }

    private void load (File file) {
        try {
            var parser = new Json.Parser ();
            parser.load_from_file (file.get_path ());
            var root = parser.get_root ().get_object ();
            if (root.get_int_member_with_default ("format", 0) != 1) {
                return;
            }
            var mapping = new Mapping (
                root.get_string_member_with_default ("name", ""),
                root.get_boolean_member_with_default ("blank", false),
                root.has_member ("menus") ? root.get_array_member ("menus") : new Json.Array ()
            );
            if (!root.has_member ("identifiers")) {
                return;
            }
            root.get_array_member ("identifiers").foreach_element ((array, index, node) => {
                var id = node.get_string ().down ();
                if (!by_identifier.contains (id)) {
                    by_identifier[id] = mapping;
                }
            });
        } catch (Error e) {
            message ("GlobalMenu: cannot read %s: %s", file.get_path (), e.message);
        }
    }

    /* Matches desktop id (with and without .desktop), WM class and app name. */
    public Mapping? find (string?[] candidates) {
        foreach (var candidate in candidates) {
            if (candidate == null || candidate == "") {
                continue;
            }
            var id = candidate.down ();
            var mapping = by_identifier[id] ?? by_identifier[id + ".desktop"];
            if (mapping != null) {
                return mapping;
            }
        }
        return null;
    }

    /*
     * Parses "<Ctrl><Shift>P", "F11" or a chord sequence "<Ctrl>x <Ctrl>s"
     * into one keyval and one Gdk.ModifierType mask per chord. <Meta> is
     * refused, as orbit does, because it means different things on different
     * setups. A capital letter alone is not Shift.
     */
    public static bool parse (string accel, out uint[] keyvals, out uint[] modifiers) {
        keyvals = {};
        modifiers = {};
        uint[] keys = {};
        uint[] masks = {};
        foreach (var chord in accel.strip ().split (" ")) {
            if (chord == "") {
                continue;
            }
            uint mods = 0;
            var rest = chord;
            while (rest.has_prefix ("<") && rest.index_of_char ('>') > 0) {
                var close = rest.index_of_char ('>');
                var mod = rest.substring (1, close - 1).down ();
                rest = rest.substring (close + 1);
                switch (mod) {
                    case "ctrl":
                    case "control":
                    case "primary":
                        mods |= Gdk.ModifierType.CONTROL_MASK;
                        break;
                    case "shift":
                        mods |= Gdk.ModifierType.SHIFT_MASK;
                        break;
                    case "alt":
                        mods |= Gdk.ModifierType.MOD1_MASK;
                        break;
                    case "super":
                        mods |= Gdk.ModifierType.SUPER_MASK;
                        break;
                    default:
                        return false;
                }
            }
            if (rest == "") {
                return false;
            }
            uint keyval;
            if (rest.char_count () == 1) {
                keyval = Gdk.unicode_to_keyval (rest.get_char (0));
            } else {
                keyval = Gdk.keyval_from_name (rest);
            }
            if (keyval == 0 || keyval == Gdk.Key.VoidSymbol) {
                return false;
            }
            keys += keyval;
            masks += mods;
        }
        keyvals = keys;
        modifiers = masks;
        return keys.length > 0;
    }
}
