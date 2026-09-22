#!/usr/bin/env bash
# --toolchain runs only the build-tool checks, for scripts/check.sh.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
failed=0
for command_name in swift xcrun cmake ninja meson pkg-config uv node npm cargo ffmpeg ffprobe; do
  if ! command -v "$command_name" >/dev/null; then
    echo "MISSING: $command_name" >&2
    failed=1
  fi
done
if [[ ! -d "$DEVELOPER_DIR" ]]; then echo "MISSING: full Xcode at $DEVELOPER_DIR" >&2; failed=1; fi
if ! xcrun metal --version; then echo "MISSING: Metal Toolchain. Run: xcodebuild -downloadComponent MetalToolchain" >&2; failed=1; fi
if [[ ! -x /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ]]; then
  echo "MISSING: ffmpeg-full (fixture generator needs zscale)" >&2; failed=1
fi
if [[ "${1:-}" == --toolchain ]]; then exit "$failed"; fi
free_gib=$(( $(df -Pk . | awk 'NR == 2 {print $4}') / 1024 / 1024 ))
if (( free_gib < 15 )); then echo "LOW DISK: ${free_gib} GiB free on the project volume; builds need 15 GiB" >&2; failed=1; fi
sw_vers
swift --version
df -h .
git submodule status
if [[ -x .build/debug/hdr-probe ]]; then .build/debug/hdr-probe; fi
python3 scripts/fetch-models.py --verify
exit "$failed"
