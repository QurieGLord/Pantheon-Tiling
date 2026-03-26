#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/usr}"
GALA_BUILD_DIR="${GALA_BUILD_DIR:-$ROOT_DIR/gala/builddir}"
PANEL_BUILD_DIR="${PANEL_BUILD_DIR:-$ROOT_DIR/panel-bsp/builddir}"
RUN_GALA_TESTS="${RUN_GALA_TESTS:-1}"
INSTALL_PANEL="${INSTALL_PANEL:-1}"
WINGPANEL_PKG_CONFIG_NAME="${WINGPANEL_PKG_CONFIG_NAME:-}"

msg() {
    printf '\n==> %s\n' "$1"
}

ensure_meson_setup() {
    local source_dir="$1"
    local build_dir="$2"

    if [[ -f "$build_dir/build.ninja" ]]; then
        meson setup "$build_dir" "$source_dir" --reconfigure --prefix="$PREFIX"
    else
        meson setup "$build_dir" "$source_dir" --prefix="$PREFIX"
    fi
}

msg "Checking dependencies"

if ! command -v meson >/dev/null 2>&1; then
    echo "meson is required" >&2
    exit 1
fi

if ! command -v pkg-config >/dev/null 2>&1; then
    echo "pkg-config is required" >&2
    exit 1
fi

if ! command -v glib-compile-schemas >/dev/null 2>&1; then
    echo "glib-compile-schemas is required" >&2
    exit 1
fi

msg "Configuring Gala"
ensure_meson_setup "$ROOT_DIR/gala" "$GALA_BUILD_DIR"

msg "Building Gala"
meson compile -C "$GALA_BUILD_DIR"

if [[ "$RUN_GALA_TESTS" != "0" ]]; then
    msg "Running Gala tests"
    meson test -C "$GALA_BUILD_DIR" --print-errorlogs
fi

msg "Installing Gala"
sudo meson install -C "$GALA_BUILD_DIR"

if [[ "$INSTALL_PANEL" == "0" ]]; then
    msg "Skipping panel-bsp"
else
    msg "Configuring panel-bsp"
    if [[ -z "$WINGPANEL_PKG_CONFIG_NAME" ]]; then
        if pkg-config --exists wingpanel-9; then
            WINGPANEL_PKG_CONFIG_NAME="wingpanel-9"
        elif pkg-config --exists wingpanel; then
            WINGPANEL_PKG_CONFIG_NAME="wingpanel"
        fi
    fi

    if [[ -z "$WINGPANEL_PKG_CONFIG_NAME" ]]; then
        cat >&2 <<'EOF'
Neither wingpanel-9 nor wingpanel was found via pkg-config.

Install a Wingpanel development package or export PKG_CONFIG_PATH so that
the appropriate Wingpanel .pc file is discoverable before running this script again.
EOF
        exit 1
    fi

    msg "Using Wingpanel pkg-config package: $WINGPANEL_PKG_CONFIG_NAME"
    ensure_meson_setup "$ROOT_DIR/panel-bsp" "$PANEL_BUILD_DIR"

    msg "Building panel-bsp"
    meson compile -C "$PANEL_BUILD_DIR"

    msg "Installing panel-bsp"
    sudo meson install -C "$PANEL_BUILD_DIR"
fi

msg "Recompiling GSettings schemas"
sudo glib-compile-schemas "$PREFIX/share/glib-2.0/schemas"

msg "Done"
echo "A reboot or at least a fresh session login is recommended."
