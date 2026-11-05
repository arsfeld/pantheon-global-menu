project('pantheon-global-menu', 'vala', 'c', version: '0.1.0', meson_version: '>= 0.60')

# Two plugins from one tree:
#   - a Wingpanel indicator that draws the focused app's menus, and
#   - a Gala plugin that tells it which window has focus, where that window's
#     menu lives, and types shortcuts on its behalf.
# The shortcut menus are orbit-global-menu's mapping files, installed from the
# shared directory one level up.

add_project_arguments('-DG_LOG_DOMAIN="pantheon-global-menu"', language: 'c')

vapi_dir = meson.current_source_dir() / 'vapi'
add_project_arguments('--vapidir', vapi_dir, language: 'vala')

shortcuts_install_dir = get_option('prefix') / get_option('datadir') / 'pantheon-global-menu' / 'shortcuts'
install_subdir(
    '..' / 'global-menu@unmade.space' / 'shortcuts' / 'apps',
    install_dir: shortcuts_install_dir,
)

wingpanel_dep = dependency('wingpanel')
shared_module(
    'globalmenu-indicator',
    'src/Shortcuts.vala',
    'src/Indicator.vala',
    c_args: ['-DSHORTCUTS_DIR="@0@"'.format(shortcuts_install_dir / 'apps')],
    dependencies: [
        dependency('glib-2.0'),
        dependency('gobject-2.0'),
        dependency('gio-2.0'),
        dependency('gio-unix-2.0'),
        dependency('gtk+-3.0'),
        dependency('json-glib-1.0'),
        # vapi/ carries these under their pkg-config names; libdbusmenu
        # installs them as Dbusmenu-0.4 and DbusmenuGtk3-0.4.
        dependency('dbusmenu-glib-0.4'),
        dependency('dbusmenu-gtk3-0.4'),
        wingpanel_dep,
    ],
    install: true,
    install_dir: wingpanel_dep.get_variable(
        pkgconfig: 'indicatorsdir',
        pkgconfig_define: ['libdir', get_option('prefix') / get_option('libdir')],
    ),
)

# Gala plugins load from gala's own PLUGINDIR, $libdir/gala/plugins.
# Distributions install there; NixOS patches PLUGINDIR to
# /run/current-system/sw/lib/gala/plugins, so installing under this prefix and
# adding the package to the system profile is enough.
#
# The plugin must be built against the mutter gala itself uses, so probe for
# each supported libmutter API version in turn, as gala and wingpanel's own
# Gala plugin do. mutter does not install Vala bindings; vapi/ carries the
# ones from gala's source tree (tag 8.6.2) for each version listed here.
# Supporting another one means copying its libmutter-N, mutter-clutter-N,
# mutter-cogl-N and mutter-mtk-N vapis (and .deps) over and adding a row.
#   [API version, mutter release, vala defines gala's vapis guard on]
supported_mutters = [
    ['14', '46', []],                                       # elementary OS 8
    ['16', '48', ['HAS_MUTTER47', 'HAS_MUTTER48']],         # NixOS
]
mutter_deps = []
mutter_vala_args = []
foreach m : supported_mutters
    api = m[0]
    release = m[1].to_int()
    probe = dependency(
        'libmutter-' + api,
        version: ['>= @0@'.format(release), '< @0@'.format(release + 1)],
        required: false,
    )
    if probe.found()
        mutter_deps = [
            probe,
            dependency('mutter-clutter-' + api),
            dependency('mutter-cogl-' + api),
            dependency('mutter-mtk-' + api),
        ]
        mutter_vala_args = []
        foreach define : m[2]
            mutter_vala_args += ['--define', define]
        endforeach
    endif
endforeach
if mutter_deps.length() == 0
    error('No supported mutter found: need mutter 46 (libmutter-14) or 48 (libmutter-16).')
endif

shared_module(
    'gala-globalmenu',
    'gala/Plugin.vala',
    dependencies: mutter_deps + [
        dependency('gala'),
        dependency('gio-2.0'),
        dependency('gio-unix-2.0'),
        dependency('gee-0.8'),
        dependency('gdk-pixbuf-2.0'),
        dependency('pango'),
        dependency('cairo-gobject'),
    ],
    vala_args: mutter_vala_args,
    # Debian and Ubuntu keep mutter's clutter and cogl in a private directory,
    # the same one as its typelibs; gala's own plugins carry this rpath too.
    install_rpath: mutter_deps[0].get_variable(pkgconfig: 'typelibdir'),
    install: true,
    install_dir: get_option('prefix') / get_option('libdir') / 'gala' / 'plugins',
)
