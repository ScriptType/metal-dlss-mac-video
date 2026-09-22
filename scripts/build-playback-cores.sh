#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
bash scripts/build-mpv-adapter.sh
cargo run --manifest-path vendor/Erika/Cargo.toml --locked -p xtask -- \
  deps build --all --profile lgpl --jobs "$BUILD_JOBS"
cargo build --manifest-path vendor/Erika/Cargo.toml --locked \
  -p erika_capi -p macos_native_demo -p metal_import_videotoolbox
