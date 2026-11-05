# Pantheon Global Menu

A menu bar for Pantheon, elementary OS's desktop. The focused application's
menus appear in Wingpanel, next to Applications.

This is a port of [Orbit Global Menu](https://github.com/Unmade760/orbit-global-menu)
from GNOME Shell to Pantheon. It reuses Orbit's per-app shortcut menus
(`../global-menu@unmade.space/shortcuts/apps`) unchanged, and adds mappings
for elementary's own apps there.

**Status: proof of concept.** It runs daily on one NixOS machine with Gala
8.6.2 and mutter 48 on Wayland. The elementary OS 8 package (Gala 8.6.2,
mutter 46) builds and installs cleanly but has not yet been run in a
session.

## How it works

On Wayland only the compositor knows which window has focus, so the work is
split in two:

- **A Gala plugin** (`gala/Plugin.vala`) follows the focused window and
  publishes where its menu lives on the session bus as
  `io.github.arsfeld.PantheonGlobalMenu`. It also implements
  `com.canonical.AppMenu.Registrar`, the name Qt, Electron, Chromium and
  Firefox register their menus with under X11, and types keyboard shortcuts
  into the focused window through a virtual keyboard when the panel asks.
  Only the panel's own bus name may ask.
- **A Wingpanel indicator** (`src/`) draws the menu as a GTK menubar. It
  moves itself from the right-hand side of the panel to the left, next to
  Applications. Wingpanel has no slot there for third-party indicators, so
  this depends on Wingpanel's widget layout.

Menus come from the first of these that applies:

1. **The app's own menu**, when it exports one: `org.gtk.Menus` for GTK
   apps (and LibreOffice), `com.canonical.dbusmenu` for X11 apps that
   register with the registrar. Checkmarks, greyed-out items and accelerators
   are the app's.
2. **A shortcut menu** from the mapping files. Choosing an item types its
   shortcut into the window. User files in
   `~/.config/global-menu/shortcuts/apps` replace the built-in file of the
   same name, as in Orbit. The format is in
   [../docs/shortcut-mappings.md](../docs/shortcut-mappings.md).
3. **Just the app's name.**

elementary's apps publish no menubar (their commands live in headerbar
buttons and popovers) and only a few app-level actions over D-Bus, so they
are covered by shortcut mappings written from each app's source.

## Installing on elementary OS 8

Every push to `main` that touches this directory or the shortcut mappings
builds a package against elementary OS 8's own Gala and Wingpanel and
publishes it to a signed apt repository at
<https://arsfeld.github.io/pantheon-global-menu/>:

```sh
sudo install -d -m 0755 /etc/apt/keyrings
sudo wget -qO /etc/apt/keyrings/pantheon-global-menu.asc \
  https://arsfeld.github.io/pantheon-global-menu/pantheon-global-menu.asc
echo "deb [signed-by=/etc/apt/keyrings/pantheon-global-menu.asc] https://arsfeld.github.io/pantheon-global-menu circe main" \
  | sudo tee /etc/apt/sources.list.d/pantheon-global-menu.list
sudo apt update
sudo apt install pantheon-global-menu
```

Then log out and back in: Gala loads plugins only at startup. The signing
key is [`apt/pantheon-global-menu.asc`](apt/pantheon-global-menu.asc),
fingerprint `4178 4193 8D02 EFB7 B362  7937 F4C1 F363 9BEF 0B54`.

The repository is rebuilt from scratch on each publish, so it holds only the
latest build. The package depends on the exact mutter ABI it was built
against (`libmutter-14-0`), so an elementary OS release with a different
mutter needs a new build, not this one.

## Building

Needs Gala and Wingpanel development files, mutter 46 or 48, GTK 3,
json-glib, libgee and libdbusmenu-gtk3. mutter installs no Vala bindings, so
`vapi/` carries Gala 8.6.2's for mutter 46 (`libmutter-14`, elementary OS 8)
and mutter 48 (`libmutter-16`, NixOS); `meson.build` picks whichever is
installed, as Gala's own build does.

```sh
meson setup build pantheon --prefix=/usr
ninja -C build
sudo ninja -C build install
```

Run that from the repository root, so the shortcut mappings are found. Then
log out and back in: Gala loads plugins only at startup.

To build the .deb the way CI does, from the repository root:

```sh
docker run --rm -v "$PWD:/src" -w /src ghcr.io/elementary/docker:circe-stable \
    sh pantheon/debian/build.sh out
```

`debian/` is this package's (the repository root's `debian/` is the Python
daemon's), `apt/build-repo.sh` turns the result into the signed repository,
and `.github/workflows/pantheon-apt.yml` runs both and deploys to Pages.

On NixOS, `package.nix` here is a callPackage-able derivation. Add the
result to both `services.desktopManager.pantheon.extraWingpanelIndicators`
(the indicator) and `environment.systemPackages` (the Gala plugin; nixpkgs
points Gala's plugin directory at `/run/current-system/sw/lib/gala/plugins`).

## Caveats

- A crash in the Gala plugin ends the session. It stays away from the stage
  and handles every error, but it is still compositor code.
- Shortcut menus send keystrokes, so an item does whatever the app binds
  that key to. The mappings come from source and can go stale when an app
  changes its shortcuts.
- Only native-Wayland GTK apps that export `org.gtk.Menus`, and X11 apps
  through the registrar, get real menus. Qt and Electron on native Wayland
  publish nothing Gala can see.

## Testing hook

The panel exports an action that opens the n-th top-level menu without
injecting input:

```sh
gdbus call --session --dest org.elementary.wingpanel \
  --object-path /org/elementary/wingpanel \
  --method org.gtk.Actions.Activate globalmenu-open "[<1>]" "{}"
```

GTK 3 on Wayland refuses to pop up a menu with no input event behind it, so
this works only under X11.

## License

GPL-3.0-or-later, as Orbit. The vendored bindings in `vapi/` are Gala's
(GPL-3.0-or-later) and libdbusmenu's (LGPL-3.0).
