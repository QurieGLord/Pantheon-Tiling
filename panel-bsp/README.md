# panel-bsp

Wingpanel indicator prototype for configuring Gala BSP tiling.

Current scope:
- toggle BSP tiling globally
- toggle BSP tiling for the active workspace
- adjust inner and outer gaps
- toggle `focus-follows-mouse`
- toggle `mouse-follows-focus`
- toggle live reorder on drag
- quick actions for floating, promote, and rotate

## Build

This project expects the `wingpanel-9` development package to be available via `pkg-config`.

```bash
meson setup builddir --prefix=/usr
meson compile -C builddir
sudo meson install -C builddir
```

If you are building against a locally built `wingpanel`, make sure its generated pkg-config files are visible through `PKG_CONFIG_PATH`.
