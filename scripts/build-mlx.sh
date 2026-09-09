#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
swift package --package-path vendor/MLX-DLSS resolve --force-resolved-versions
swift build --package-path vendor/MLX-DLSS -c release --jobs "$BUILD_JOBS"
MLXDLSS_PREPARE_SKIP_SWIFT_BUILD=1 vendor/MLX-DLSS/scripts/prepare-mlx-metallib.sh \
  "$PROJECT_ROOT/vendor/MLX-DLSS/.build/release"
