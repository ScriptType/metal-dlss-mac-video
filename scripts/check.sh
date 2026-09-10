#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
for script in scripts/*.sh; do bash -n "$script"; done
python3 -m compileall -q scripts
python3 -m unittest discover -s scripts -p test_adapter_visibility.py
python3 -m unittest discover -s scripts -p test_apple_hdr_samples.py
bash scripts/test-player-lifecycle.sh
npm --prefix apps/controls run check
npm --prefix apps/controls run build
swift build --build-tests --jobs "$BUILD_JOBS"
bash scripts/prepare-frame-runtime.sh
swift test --skip-build --jobs "$BUILD_JOBS"
.build/debug/hdr-benchmark --reference-sequence-self-test
bash scripts/test-frame-api.sh
uv run --frozen python scripts/test_hdr_capture.py
uv run --frozen python scripts/review-reference-sequence.py --self-test
uv run --frozen pytest -q vendor/MLX-DLSS/python/tests/test_vsr_weights.py \
  vendor/MLX-DLSS/Tests/ToolsTests/test_extract_dlssnr_weights.py \
  vendor/MLX-DLSS/Tests/ToolsTests/test_unpack_dlssnr_weights.py
uv run --frozen scripts/generate-fixtures.py
swift run --skip-build hdr-probe > artifacts/gpu-report.json
swift run --skip-build hdr-probe --video assets/test-clips/hdr10-30.mp4 > artifacts/hdr10-decode.json
swift run --skip-build hdr-probe --video assets/test-clips/hlg-60.mp4 > artifacts/hlg-decode.json
git diff --check
python3 scripts/audit-public-tree.py
