#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
meson test -C artifacts/mpv-build --print-errorlogs
meson test -C artifacts/libplacebo-build --print-errorlogs
swift test --package-path vendor/MLX-DLSS -c release --jobs "$BUILD_JOBS" --filter DLSSCoreTests
