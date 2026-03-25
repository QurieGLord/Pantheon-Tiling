src_test_sources = files(
    meson.project_source_root() / 'src' / 'BspLayout.vala',
)

tests = [
    'BspLayoutTest',
]

foreach test : tests
    test_executable = executable(
        test,
        '@0@.vala'.format(test),
        common_test_sources,
        src_test_sources,
        dependencies: gala_base_dep,
        install: false,
    )

    test(test, test_executable, suite: ['Gala', 'Gala/src'])
endforeach
