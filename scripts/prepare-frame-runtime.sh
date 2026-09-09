#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
frame_bin="$(swift build --show-bin-path)"
destinations=("$frame_bin")
while IFS= read -r destination; do destinations+=("$destination"); done < <(
  find "$frame_bin" -type d -path '*.xctest/Contents/MacOS' -print
)
MLXDLSS_PREPARE_SKIP_SWIFT_BUILD=1 vendor/MLX-DLSS/scripts/prepare-mlx-metallib.sh "${destinations[@]}" "$@"
