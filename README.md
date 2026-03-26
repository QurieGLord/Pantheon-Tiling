# Pantheon-Tiling

Experimental BSP tiling for Pantheon, built as a monorepo around a patched
`gala` and a companion Wingpanel indicator.

Pantheon-Tiling aims to make elementary OS feel closer to `bspwm` /
`Hyprland`-style workflows while staying native to the Pantheon session model.
Instead of bolting on a separate tiler, the project teaches Gala itself how to
manage BSP trees, floating windows, runtime layout controls, and panel-driven
configuration.

## What This Repo Contains

- `gala/`
  A patched Gala compositor / window manager with BSP tiling, floating windows,
  directional focus and swaps, promote / rotate operations, gap controls,
  pointer-focus toggles, and development tooling for nested demos.
- `panel-bsp/`
  A Wingpanel indicator for live BSP control: global and per-workspace toggles,
  master-window settings, gap controls, mouse-focus behavior, live reorder, and
  a centered help window that reflects current shortcut bindings.
- `scripts/`
  Helper scripts for development installs. The main entrypoint is
  `scripts/install-all.sh`.

## Current Feature Set

- BSP autotiling implemented directly inside Gala
- global enablement and per-workspace enablement
- floating / tiled toggle for the focused window
- directional focus and directional window swaps
- promote and rotate operations
- live reorder while dragging tiled windows
- inner and outer gap control
- optional dedicated master window
- configurable master side: left or right
- `focus-follows-mouse`
- `mouse-follows-focus`
- Wingpanel indicator with live controls
- centered shortcut / help popup from the panel

## Default Shortcuts

These are the default bindings currently shipped in the schema. The panel help
window reads the actual current bindings from GSettings, so remapped shortcuts
show up there automatically.

- `Super + Arrow`:
  focus tiled windows by direction while BSP is active
- `Super + Shift + Arrow`:
  swap / move tiled windows by direction
- `Super + B`:
  toggle BSP globally
- `Super + Shift + B`:
  toggle BSP for the active workspace
- `Super + V`:
  toggle the focused window between tiled and floating
- `Super + Enter`:
  promote the focused window into the master slot
- `Super + R`:
  rotate the BSP tree forward
- `Super + Shift + R`:
  rotate the BSP tree backward
- `Super + I` / `Super + Shift + I`:
  increase / decrease inner gap
- `Super + O` / `Super + Shift + O`:
  increase / decrease outer gap

## Repository Layout

```text
Pantheon-Tiling/
├── gala/
├── panel-bsp/
└── scripts/
    └── install-all.sh
```

## Dependencies

Install the currently tested dependency set on elementary OS / Ubuntu-based
systems with:

```bash
sudo apt install -y git build-essential meson ninja-build valac pkg-config gettext libgtk-4-dev libgtk-3-dev libgee-0.8-dev libglib2.0-dev libgnome-desktop-4-dev libgnome-bg-4-dev libgranite-7-dev libgranite-dev libhandy-1-dev libsqlite3-dev gsettings-desktop-schemas-dev libgdk-pixbuf-2.0-dev libatk-bridge2.0-dev libxext-dev libmutter-14-dev libwingpanel-dev
```

Notes:

- `gala` still depends on the correct `libmutter-*` development package for the
  target elementary OS release.
- `panel-bsp` expects a Wingpanel development package visible through
  `pkg-config` as either `wingpanel-9` or `wingpanel`, depending on the target
  system.

You can verify the available Wingpanel ABI name with:

```bash
pkg-config --exists wingpanel-9 && echo wingpanel-9 || pkg-config --exists wingpanel && echo wingpanel
```

## Quick Start In A VM

For the cleanest test loop, use a dedicated elementary OS VM snapshot.

```bash
git clone https://github.com/QurieGLord/Pantheon-Tiling.git
cd Pantheon-Tiling
./scripts/install-all.sh
sudo reboot
```

After reboot or a fresh session login:

- the patched Gala is active in the real Pantheon session
- the Wingpanel indicator is installed into the system indicators directory
- updated GSettings schemas are already compiled by the install script

## Development Install Flow

From the repo root:

```bash
./scripts/install-all.sh
```

Useful variants:

- install only Gala:
  `INSTALL_PANEL=0 ./scripts/install-all.sh`
- skip Gala tests during a fast iteration:
  `RUN_GALA_TESTS=0 ./scripts/install-all.sh`
- stage to a different prefix:
  `PREFIX=/usr ./scripts/install-all.sh`

By default the script:

- configures Meson build directories if needed
- compiles `gala`
- runs Gala tests
- installs `gala`
- compiles `panel-bsp`
- installs `panel-bsp`
- recompiles system GSettings schemas

## Panel Indicator

The Wingpanel side is meant to be the everyday control surface for the tiler.
Right now it exposes:

- BSP on / off
- workspace-scoped BSP enablement
- master-window mode on / off
- master side selection
- inner and outer gaps
- live reorder toggle
- `focus-follows-mouse`
- `mouse-follows-focus`
- quick actions for float, promote, and rotate
- a centered help window showing the current keyboard shortcuts

## Project Status

This is still an experimental environment, not a polished desktop product yet.

What is already in decent shape:

- core BSP behavior in Gala
- floating windows
- promote / rotate / swap interactions
- runtime control through the Wingpanel indicator
- install flow for a test VM

What still deserves caution:

- compositor animation polish during some reflow paths
- session edge cases during longer real-world runs
- upstream packaging and release integration

## Future Release Path

The long-term clean release path is packaging, not manual install scripts:

1. Ship patched `gala` as a package or overlay package for the target
   elementary OS release.
2. Ship `panel-bsp` as its own Wingpanel indicator package.
3. Provide a tiny meta-package depending on both.
4. Use post-install hooks to recompile schemas and refresh session components
   safely.

The root install script in this repo is the development version of that future
flow.

## Future Steps

- tighten BSP behavior around real workspace transitions so tiling state,
  floating windows, and directional focus stay intuitive when moving between
  workspaces
- improve multi-monitor behavior so trees, monitor-aware swaps, and
  workspace-scoped tiling stay consistent across monitor hotplug and
  monitor-specific work areas
- keep polishing reflow animations so layout changes feel fully native inside
  Pantheon
- package both components for smoother installation and updates
