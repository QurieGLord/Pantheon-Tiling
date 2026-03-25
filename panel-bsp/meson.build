project(
    'bsp',
    'vala', 'c',
    version: '0.1.0',
    meson_version: '>= 0.58.0'
)

gnome = import('gnome')

prefix = get_option('prefix')
libdir = prefix / get_option('libdir')

add_project_arguments('-DG_LOG_DOMAIN="io.elementary.panel.bsp"', language: 'c')

gresource = gnome.compile_resources(
    'panel-bsp-resources',
    'data/gresource.xml',
    source_dir: 'data'
)

wingpanel_dep = dependency('wingpanel-9')
wingpanel_indicatorsdir = wingpanel_dep.get_variable('indicatorsdir', pkgconfig_define: ['libdir', libdir])

shared_module(
    meson.project_name(),
    gresource,
    'src/GalaClient.vala',
    'src/HelpOverlay.vala',
    'src/Indicator.vala',
    dependencies: [
        dependency('gio-2.0'),
        dependency('glib-2.0'),
        dependency('gobject-2.0'),
        dependency('granite-7'),
        dependency('gtk4'),
        wingpanel_dep
    ],
    install: true,
    install_dir: wingpanel_indicatorsdir
)
