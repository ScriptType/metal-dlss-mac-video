#!/usr/bin/env bash
# Uses Erika's prepared native dependencies; does not open a window or run MLX.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
export ERIKA_FRAME_ENGINE_INCLUDE="$PROJECT_ROOT/packages/CFrameEngine/include"

cargo test --locked --manifest-path vendor/Erika/Cargo.toml --jobs "$BUILD_JOBS" \
  -p erika --features shared-hdr --lib -- --test-threads=1 \
  enhancement_ playback::tests::playback_fixture_ playback::tests::buffering_ \
  playback::tests::audio_only_mode playback::tests::playback_clock_ \
  core::tests::frame_output_ core::tests::pause_publishes_ core::tests::failed_pause_ \
  core::tests::buffering_ core::tests::stale_worker_generation_ core::tests::newer_command_ \
  presenter::tests::video_frame_backpressure_ core::tests::audio_observation_ core::tests::audio_capture_ \
  eof_drain_ video_upload_
cargo test --locked --manifest-path vendor/Erika/Cargo.toml --jobs "$BUILD_JOBS" \
  -p macos_native_demo --features shared-hdr adapter_schedule -- --test-threads=1
cargo build --locked --manifest-path vendor/Erika/Cargo.toml --jobs "$BUILD_JOBS" \
  -p macos_native_demo --features shared-hdr
