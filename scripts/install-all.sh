#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/usr}"
GALA_BUILD_DIR="${GALA_BUILD_DIR:-$ROOT_DIR/gala/builddir}"
PANEL_BUILD_DIR="${PANEL_BUILD_DIR:-$ROOT_DIR/panel-bsp/builddir}"
RUN_GALA_TESTS="${RUN_GALA_TESTS:-1}"
INSTALL_PANEL="${INSTALL_PANEL:-1}"
WINGPANEL_PKG_CONFIG_NAME="${WINGPANEL_PKG_CONFIG_NAME:-}"
BSP_DEBUG_OVERRIDE_ACTION="leave"

msg() {
    printf '\n==> %s\n' "$1"
}

usage() {
    cat <<'EOF'
Usage: ./scripts/install-all.sh [--enable-bsp-debug|--disable-bsp-debug]

Options:
  --enable-bsp-debug   Install Gala, then enable a user systemd override that
                       exports GALA_BSP_DEBUG=1 for future Gala sessions.
  --disable-bsp-debug  Install Gala, then remove that override.
  -h, --help           Show this help text.
EOF
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

configure_bsp_debug_override() {
    local action="$1"
    local user_systemd_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local override_name="90-bsp-debug.conf"
    local units=(
        "io.elementary.gala@wayland.service"
        "io.elementary.gala@x11.service"
    )

    case "$action" in
        enable)
            for unit in "${units[@]}"; do
                local override_dir="$user_systemd_dir/$unit.d"
                mkdir -p "$override_dir"
                cat >"$override_dir/$override_name" <<'EOF'
[Service]
Environment=GALA_BSP_DEBUG=1
EOF
            done
            ;;
        disable)
            for unit in "${units[@]}"; do
                local override_dir="$user_systemd_dir/$unit.d"
                rm -f "$override_dir/$override_name"
                rmdir --ignore-fail-on-non-empty "$override_dir" 2>/dev/null || true
            done
            ;;
        leave)
            return
            ;;
        *)
            echo "Unknown BSP debug override action: $action" >&2
            exit 1
            ;;
    esac

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl --user daemon-reload; then
            echo "Warning: failed to run 'systemctl --user daemon-reload'. Re-login or reboot before checking BSP logs." >&2
        fi
    fi
}

print_bsp_debug_next_steps() {
    local session_type="${XDG_SESSION_TYPE:-}"
    local unit_selector="io.elementary.gala@*.service"

    if [[ "$session_type" == "wayland" || "$session_type" == "x11" ]]; then
        unit_selector="io.elementary.gala@${session_type}.service"
    fi

    case "$BSP_DEBUG_OVERRIDE_ACTION" in
        enable)
            cat <<EOF
BSP debug override is enabled for future Gala sessions.
After reboot or a fresh session login, confirm BSP logs with:
  journalctl --user -b -u '$unit_selector' -o short-precise --no-pager | rg '\[BSP\]'

To disable BSP logs later:
  ./scripts/install-all.sh --disable-bsp-debug
EOF
            ;;
        disable)
            cat <<'EOF'
BSP debug override is disabled for future Gala sessions.
Re-enable it later with:
  ./scripts/install-all.sh --enable-bsp-debug
EOF
            ;;
    esac
}

for arg in "$@"; do
    case "$arg" in
        --enable-bsp-debug)
            if [[ "$BSP_DEBUG_OVERRIDE_ACTION" == "disable" ]]; then
                echo "Choose either --enable-bsp-debug or --disable-bsp-debug, not both." >&2
                exit 1
            fi
            BSP_DEBUG_OVERRIDE_ACTION="enable"
            ;;
        --disable-bsp-debug)
            if [[ "$BSP_DEBUG_OVERRIDE_ACTION" == "enable" ]]; then
                echo "Choose either --enable-bsp-debug or --disable-bsp-debug, not both." >&2
                exit 1
            fi
            BSP_DEBUG_OVERRIDE_ACTION="disable"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

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

configure_bsp_debug_override "$BSP_DEBUG_OVERRIDE_ACTION"

msg "Done"
echo "A reboot or at least a fresh session login is recommended."
print_bsp_debug_next_steps
