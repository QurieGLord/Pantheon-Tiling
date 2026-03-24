#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/builddir}"
GALA_BIN="$BUILD_DIR/src/gala"
DEMO_SOURCE="$ROOT_DIR/tools/NestedDemoWindows.vala"
DEMO_BIN="$BUILD_DIR/tools/nested-demo-windows"
WAYLAND_DISPLAY_NAME="${WAYLAND_DISPLAY_NAME:-gala-demo}"
STARTUP_DELAY="${STARTUP_DELAY:-3}"
DEMO_PAUSE="${DEMO_PAUSE:-1.5}"
DEMO_WINDOWS="${DEMO_WINDOWS:-4}"

if [[ ! -x "$GALA_BIN" ]]; then
    echo "Gala binary not found: $GALA_BIN" >&2
    echo "Build it first: meson compile -C builddir ./src/gala" >&2
    exit 1
fi

if ! command -v dbus-run-session >/dev/null 2>&1; then
    echo "dbus-run-session is required" >&2
    exit 1
fi

if ! command -v valac >/dev/null 2>&1; then
    echo "valac is required to build the demo client" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$(dirname "$DEMO_BIN")"
valac --pkg gtk4 --pkg gio-2.0 --pkg glib-2.0 -o "$DEMO_BIN" "$DEMO_SOURCE"

DEMO_PAUSE_MS="$(python3 - <<PY
print(int(float("$DEMO_PAUSE") * 1000))
PY
)"

export GALA_BIN DEMO_BIN WAYLAND_DISPLAY_NAME STARTUP_DELAY DEMO_PAUSE DEMO_PAUSE_MS DEMO_WINDOWS TMP_DIR

dbus-run-session -- bash -lc '
set -euo pipefail

"$GALA_BIN" --nested --wayland-display="$WAYLAND_DISPLAY_NAME" &
gala_pid=$!
demo_pids=()

cleanup() {
    for demo_pid in "${demo_pids[@]:-}"; do
        if kill -0 "$demo_pid" 2>/dev/null; then
            kill "$demo_pid" 2>/dev/null || true
            wait "$demo_pid" 2>/dev/null || true
        fi
    done

    if kill -0 "$gala_pid" 2>/dev/null; then
        kill "$gala_pid" 2>/dev/null || true
        wait "$gala_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

sleep "$STARTUP_DELAY"

if ! kill -0 "$gala_pid" 2>/dev/null; then
    echo "Nested Gala exited before demo windows were opened" >&2
    wait "$gala_pid"
    exit 1
fi

for ((i = 1; i <= DEMO_WINDOWS; i++)); do
    WAYLAND_DISPLAY="$WAYLAND_DISPLAY_NAME" \
    GDK_BACKEND=wayland \
    "$DEMO_BIN" 1 0 "$i" &
    demo_pids+=("$!")

    if (( i < DEMO_WINDOWS )); then
        sleep "$DEMO_PAUSE"
    fi
done

echo "Nested Gala is running on WAYLAND_DISPLAY=$WAYLAND_DISPLAY_NAME"
echo "Close the nested session window or press Ctrl+C here when finished."

for demo_pid in "${demo_pids[@]}"; do
    wait "$demo_pid" || true
done

wait "$gala_pid"
'
