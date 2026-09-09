#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
swift build --product FrameEngineShared --jobs "$BUILD_JOBS"
bash scripts/prepare-frame-runtime.sh
export ERIKA_FRAME_ENGINE_INCLUDE="$PROJECT_ROOT/packages/CFrameEngine/include"
cargo build --locked --manifest-path vendor/Erika/Cargo.toml --jobs "$BUILD_JOBS" \
  -p macos_native_demo --features shared-hdr
cp .build/debug/mlx.metallib artifacts/erika-target/debug/mlx.metallib
printf 'Shared HDR Erika prototype: %s\n' "$PROJECT_ROOT/artifacts/erika-target/debug/macos_native_demo"
