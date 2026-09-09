#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
missing=0
for command_name in swift xcrun cmake ninja meson pkg-config uv node npm cargo ffmpeg ffprobe; do
  if ! command -v "$command_name" >/dev/null; then
    echo "MISSING: $command_name"
    missing=1
  fi
done
if [[ ! -d "$DEVELOPER_DIR" ]]; then echo "MISSING: full Xcode at $DEVELOPER_DIR"; missing=1; fi
if ! xcrun metal --version; then echo "Run: xcodebuild -downloadComponent MetalToolchain"; missing=1; fi
if [[ ! -x /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ]]; then
  echo "MISSING: ffmpeg-full (fixture generator needs zscale)"; missing=1
fi
sw_vers
swift --version
df -h .
git submodule status
if [[ -x .build/debug/hdr-probe ]]; then .build/debug/hdr-probe; fi
python3 scripts/fetch-models.py --verify
exit "$missing"
