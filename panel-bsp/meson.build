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

wingpanel_dep = dependency('wingpanel-9', required: false)
wingpanel_indicatorsdir = join_paths(prefix, get_option('libdir'), 'wingpanel-9')

if not wingpanel_dep.found()
    wingpanel_dep = dependency('wingpanel')
    wingpanel_indicatorsdir = join_paths(prefix, get_option('libdir'), 'wingpanel')
endif

gtk_dep = dependency('gtk+-3.0')
granite_dep = dependency('granite', required: false)

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
        gtk_dep,
        granite_dep,
        wingpanel_dep
    ],
    install: true,
    install_dir: wingpanel_indicatorsdir
)
