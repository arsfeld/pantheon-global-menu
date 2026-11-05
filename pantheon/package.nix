# Nix build of the Pantheon global menu. Use with
#   pkgs.callPackage ./pantheon/package.nix {}
# then add the result to services.desktopManager.pantheon.extraWingpanelIndicators
# (the indicator) and environment.systemPackages (the Gala plugin).
{
  lib,
  stdenv,
  meson,
  ninja,
  pkg-config,
  vala,
  glib,
  gtk3,
  json-glib,
  libgee,
  libdbusmenu-gtk3,
  pantheon,
}: let
  inherit (pantheon) gala;
  # The mutter gala is built against, which is not necessarily top-level mutter.
  mutter = lib.findFirst (d: lib.hasPrefix "mutter-" d.name) null gala.buildInputs;
in
  stdenv.mkDerivation {
    pname = "pantheon-global-menu";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ./..;
      # Only this directory and the shared shortcut mappings.
      fileset = lib.fileset.unions [./. (./.. + "/global-menu@unmade.space/shortcuts/apps")];
    };

    sourceRoot = "source/pantheon";

    nativeBuildInputs = [meson ninja pkg-config vala];
    buildInputs = [glib gtk3 json-glib libgee libdbusmenu-gtk3 pantheon.granite pantheon.wingpanel gala mutter];

    meta = {
      description = "Global menu for Pantheon: the focused app's menus in Wingpanel";
      homepage = "https://github.com/arsfeld/pantheon-global-menu";
      license = lib.licenses.gpl3Plus;
      platforms = lib.platforms.linux;
    };
  }
