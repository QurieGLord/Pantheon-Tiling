#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/builddir}"
GALA_BIN="$BUILD_DIR/src/gala"
WAYLAND_DISPLAY_NAME="${WAYLAND_DISPLAY_NAME:-gala-pantheon-$$}"
STARTUP_DELAY="${STARTUP_DELAY:-4}"
SHELL_DELAY="${SHELL_DELAY:-2}"
APP_DELAY="${APP_DELAY:-1.2}"
SESSION_APPS="${SESSION_APPS:-io.elementary.files:io.elementary.terminal:gnome-text-editor}"
ISOLATE_XDG="${ISOLATE_XDG:-1}"

if [[ ! -x "$GALA_BIN" ]]; then
    echo "Gala binary not found: $GALA_BIN" >&2
    echo "Build it first: meson compile -C builddir ./src/gala" >&2
    exit 1
fi

if ! command -v dbus-run-session >/dev/null 2>&1; then
    echo "dbus-run-session is required" >&2
    exit 1
fi

for required_bin in gala-daemon io.elementary.settings-daemon; do
    if ! command -v "$required_bin" >/dev/null 2>&1; then
        echo "Required binary not found: $required_bin" >&2
        exit 1
    fi
done

TMP_DIR=""
cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

if [[ "$ISOLATE_XDG" == "1" ]]; then
    TMP_DIR="$(mktemp -d)"
fi

export ROOT_DIR GALA_BIN WAYLAND_DISPLAY_NAME STARTUP_DELAY SHELL_DELAY APP_DELAY SESSION_APPS ISOLATE_XDG TMP_DIR

dbus-run-session -- bash -lc '
set -euo pipefail

HOST_DISPLAY="${DISPLAY:-}"
export XDG_CURRENT_DESKTOP=Pantheon
export XDG_SESSION_DESKTOP=pantheon
export DESKTOP_SESSION=pantheon
export XDG_SESSION_TYPE=wayland
export XDG_CONFIG_DIRS="$ROOT_DIR/data:${XDG_CONFIG_DIRS:-/etc/xdg}"
export WAYLAND_DISPLAY="$WAYLAND_DISPLAY_NAME"
export GDK_BACKEND=wayland
export QT_QPA_PLATFORM=wayland
export SDL_VIDEODRIVER=wayland
export CLUTTER_BACKEND=wayland

if [[ "$ISOLATE_XDG" == "1" ]]; then
    export XDG_CONFIG_HOME="$TMP_DIR/config"
    export XDG_CACHE_HOME="$TMP_DIR/cache"
    export XDG_DATA_HOME="$TMP_DIR/data"
    export XDG_STATE_HOME="$TMP_DIR/state"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
fi

pids=()

start_client() {
    "$@" &
    pids+=("$!")
}

cleanup() {
    for ((i = ${#pids[@]} - 1; i >= 0; i--)); do
        pid="${pids[$i]}"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT INT TERM

if [[ -n "$HOST_DISPLAY" ]]; then
    DISPLAY="$HOST_DISPLAY" start_client "$GALA_BIN" --nested --wayland-display="$WAYLAND_DISPLAY_NAME"
else
    start_client "$GALA_BIN" --nested --wayland-display="$WAYLAND_DISPLAY_NAME"
fi
gala_pid="${pids[${#pids[@]} - 1]}"

sleep "$STARTUP_DELAY"

if ! kill -0 "$gala_pid" 2>/dev/null; then
    echo "Nested Gala exited before the shell session finished booting" >&2
    wait "$gala_pid"
    exit 1
fi

if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    dbus-update-activation-environment WAYLAND_DISPLAY GDK_BACKEND QT_QPA_PLATFORM SDL_VIDEODRIVER CLUTTER_BACKEND XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION XDG_SESSION_TYPE XDG_CONFIG_DIRS XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME PATH
fi

unset DISPLAY

start_client io.elementary.settings-daemon
start_client gala-daemon

sleep "$SHELL_DELAY"

IFS=":" read -r -a session_apps <<< "$SESSION_APPS"
for app in "${session_apps[@]}"; do
    if [[ -z "$app" ]]; then
        continue
    fi

    if ! command -v "$app" >/dev/null 2>&1; then
        echo "Skipping unavailable app: $app" >&2
        continue
    fi

    start_client "$app"
    sleep "$APP_DELAY"
done

echo "Nested Pantheon session is running on WAYLAND_DISPLAY=$WAYLAND_DISPLAY_NAME"
if [[ "$ISOLATE_XDG" == "1" ]]; then
    echo "Using isolated XDG dirs rooted at $TMP_DIR"
fi
echo "Gala uses shell clients from $XDG_CONFIG_DIRS, so dock and wingpanel should appear if they start cleanly."
echo "Close the nested session window or press Ctrl+C here when finished."

wait "$gala_pid"
'
