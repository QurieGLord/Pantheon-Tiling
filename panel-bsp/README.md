# panel-bsp

Wingpanel indicator for configuring Gala BSP tiling.

Current scope:
- toggle BSP tiling globally
- toggle BSP tiling for the active workspace
- adjust inner and outer gaps
- toggle `focus-follows-mouse`
- toggle `mouse-follows-focus`
- toggle live reorder on drag
- quick actions for floating, promote, and rotate
- show a centered help window with the current BSP shortcuts

## Build

This project expects the `wingpanel-9` development package to be available via `pkg-config`.

```bash
meson setup builddir --prefix=/usr
meson compile -C builddir
sudo meson install -C builddir
```

If you are building against a locally built `wingpanel`, make sure its generated pkg-config files are visible through `PKG_CONFIG_PATH`.

## Notes

The help popup reads the actual current accelerators from
`io.elementary.desktop.wm.keybindings`, so if the user remaps BSP shortcuts the
indicator will show the updated bindings instead of hard-coded defaults.
