#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-builddir}"

cd "${REPO_ROOT}"

meson compile -C "${BUILD_DIR}"
sudo meson install -C "${BUILD_DIR}"
sudo glib-compile-schemas /usr/share/glib-2.0/schemas
