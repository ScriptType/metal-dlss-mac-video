#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
mkdir -p artifacts/mpv-host
swiftc -swift-version 5 -O -import-objc-header vendor/mpv/include/mpv/client.h \
  tools/MpvHDRHost/main.swift -o artifacts/mpv-host/MpvHDRHost \
  -L "$PROJECT_ROOT/artifacts/mpv-build" -lmpv \
  -Xlinker -rpath -Xlinker "$PROJECT_ROOT/artifacts/mpv-build" \
  -Xlinker -rpath -Xlinker "$PROJECT_ROOT/.build/debug" \
  -framework AppKit -framework Metal -framework QuartzCore
cp vendor/MLX-DLSS/.build/release/mlx.metallib artifacts/mpv-host/mlx.metallib
