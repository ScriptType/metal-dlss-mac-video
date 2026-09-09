#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
npm --prefix apps/controls ci
npm --prefix apps/controls run build
swift build --jobs "$BUILD_JOBS"
app="$PROJECT_ROOT/artifacts/HDR Player.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/debug/HDRPlayer "$app/Contents/MacOS/"
cp -R .build/debug/MetalDLSSVideo_HDRPlayer.bundle "$app/Contents/Resources/"
cp apps/macos/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built: $app"
