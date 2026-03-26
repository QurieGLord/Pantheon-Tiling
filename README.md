# Pantheon-Tiling

Experimental BSP tiling environment for Pantheon.

This monorepo currently contains:

- `gala/`: patched Gala window manager and compositor with BSP tiling, floating windows, promote/rotate controls, pointer focus toggles, and nested demo tooling
- `panel-bsp/`: Wingpanel indicator for controlling BSP state and related behavior

## Repository Layout

```text
Pantheon-Tiling/
├── gala/
└── panel-bsp/
```

## What Works Today

- BSP autotiling in Gala
- global and per-workspace enablement
- floating/tiled toggle for the focused window
- promote and rotate operations
- live reorder while dragging
- inner and outer gaps
- `focus-follows-mouse` and `mouse-follows-focus`
- Wingpanel indicator with runtime controls and shortcut help

## Development Workflow

Build and install both components from the repo root:

```bash
./scripts/install-all.sh
```

If you only want to rebuild and install `gala` while the Wingpanel side is still in progress:

```bash
INSTALL_PANEL=0 ./scripts/install-all.sh
```

By default the script:

- configures missing Meson build directories
- compiles `gala`
- runs Gala tests
- installs `gala`
- compiles `panel-bsp`
- installs `panel-bsp`
- recompiles system GSettings schemas

The script also supports:

- `INSTALL_PANEL=0` to skip the Wingpanel indicator
- `RUN_GALA_TESTS=0` to skip the Gala test suite
- `PREFIX=/usr` or another install prefix if you are staging files elsewhere

## Requirements

Install the currently tested dependency set on elementary OS / Ubuntu-based systems with:

```bash
sudo apt install -y git build-essential meson ninja-build valac pkg-config gettext libgtk-4-dev libgtk-3-dev libgee-0.8-dev libglib2.0-dev libgnome-desktop-4-dev libgnome-bg-4-dev libgranite-7-dev libgranite-dev libhandy-1-dev libsqlite3-dev gsettings-desktop-schemas-dev libgdk-pixbuf-2.0-dev libatk-bridge2.0-dev libxext-dev libmutter-14-dev libwingpanel-dev
```

For `gala`, install the same build dependencies you have already been using in the VM, including the correct `libmutter-*` development package for your elementary OS version.

For `panel-bsp`, the important extra dependency is a Wingpanel development package exporting either `wingpanel-9` or `wingpanel` through `pkg-config`, depending on the target elementary OS release.

You can verify that with:

```bash
pkg-config --exists wingpanel-9 && echo wingpanel-9 || pkg-config --exists wingpanel && echo wingpanel
```

If it is missing, install the relevant `wingpanel` development package or point `PKG_CONFIG_PATH` at a local Wingpanel build.

## VM Installation

From inside the elementary OS VM:

```bash
git clone <your-repo-url> Pantheon-Tiling
cd Pantheon-Tiling
./scripts/install-all.sh
sudo reboot
```

After reboot:

- Gala changes are active in the real session
- the panel indicator should be loadable by Wingpanel once the module is installed in the system indicators directory

## Future Release Path

For a clean release, the best path is packaging rather than ad-hoc install scripts:

1. Ship `gala` as a patched package or overlay package for the target elementary OS release.
2. Ship `panel-bsp` as its own Wingpanel indicator package.
3. Provide a tiny meta-package depending on both.
4. Use post-install hooks to recompile schemas and restart or refresh the relevant session components when safe.

The root install script in this repo is the development version of that flow.

## Future Steps

- tighten BSP behavior around real workspace transitions so tiling state, floating windows, and directional focus stay intuitive when moving between workspaces
- improve multi-monitor behavior so trees, monitor-aware swaps, and workspace-scoped tiling stay consistent across monitor hotplug and monitor-specific work areas
- finish polishing the Wingpanel indicator and package both components for a smoother release and update path
