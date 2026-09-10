#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
mkdir -p artifacts/hdr-capture-probe
swiftc -parse-as-library -swift-version 5 -O \
  "$PROJECT_ROOT/tools/HDRCaptureProbe/main.swift" \
  -o artifacts/hdr-capture-probe/hdr-capture-probe \
  -framework AppKit -framework ScreenCaptureKit -framework CoreMedia \
  -framework CoreVideo -framework CoreGraphics -framework IOSurface -framework QuartzCore
printf '%s\n' "$PROJECT_ROOT/artifacts/hdr-capture-probe/hdr-capture-probe"
