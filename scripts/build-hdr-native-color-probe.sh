#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
mkdir -p artifacts/hdr-native-color-probe
swiftc -swift-version 5 -O \
  -import-objc-header vendor/mpv/include/mpv/hdr_frame.h \
  tools/HDRNativeColorProbe/main.swift apps/macos/Sources/PiPBufferSnapshot.swift \
  -o artifacts/hdr-native-color-probe/HDRNativeColorProbe \
  -L "$PROJECT_ROOT/artifacts/mpv-build" -lmpv \
  -Xlinker -rpath -Xlinker "$PROJECT_ROOT/artifacts/mpv-build" \
  -Xlinker -rpath -Xlinker "$PROJECT_ROOT/.build/debug" \
  -framework AppKit -framework AVFoundation -framework CoreVideo -framework QuartzCore -framework Metal
cp .build/debug/mlx.metallib artifacts/hdr-native-color-probe/mlx.metallib
