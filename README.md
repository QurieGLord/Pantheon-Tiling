# Pantheon-Tiling

Experimental BSP tiling environment for Pantheon.

This monorepo currently contains:

- `gala/`: patched Gala window manager and compositor with BSP tiling, floating windows, promote/rotate controls, pointer focus toggles, and nested demo tooling
- `panel-bsp/`: Wingpanel indicator prototype for controlling BSP state and related behavior

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
- Wingpanel indicator scaffold for runtime controls

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

For `gala`, install the same build dependencies you have already been using in the VM, including the correct `libmutter-*` development package for your elementary OS version.

For `panel-bsp`, the important extra dependency is a Wingpanel development package exporting `wingpanel-9` through `pkg-config`.

You can verify that with:

```bash
pkg-config --exists wingpanel-9 && echo ok
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
