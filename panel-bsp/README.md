# panel-bsp

Wingpanel indicator for controlling Gala BSP tiling at runtime.

This module is the desktop-facing companion to the patched `gala` in the root
monorepo. It exposes the most useful BSP controls without requiring manual
`gsettings` edits or custom helper scripts.

## Current Scope

- toggle BSP globally
- toggle BSP for the active workspace
- enable or disable the dedicated master window
- choose the master side: left or right
- adjust inner and outer gaps
- toggle `focus-follows-mouse`
- toggle `mouse-follows-focus`
- toggle live reorder on drag
- quick actions for floating, promote, and rotate
- open a centered help window with the current BSP shortcuts

## Build

This project expects a Wingpanel development package to be available through
`pkg-config` under either `wingpanel-9` or `wingpanel`, depending on the target
elementary OS release.

```bash
meson setup builddir --prefix=/usr
meson compile -C builddir
sudo meson install -C builddir
```

If you are building against a locally built `wingpanel`, make sure its
generated `pkg-config` files are visible through `PKG_CONFIG_PATH`.

## Runtime Notes

- The indicator talks to Gala through the `org.pantheon.gala` D-Bus API.
- If Gala is temporarily unavailable, the panel falls back to direct
  `GSettings` writes where possible.
- The help popup reads the live values from
  `io.elementary.desktop.wm.keybindings`, so remapped shortcuts are shown
  instead of hard-coded defaults.
