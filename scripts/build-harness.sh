#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
npm --prefix apps/controls ci
npm --prefix apps/controls run build
swift build --jobs "$BUILD_JOBS"
if [[ ! -f artifacts/mpv-build/libmpv.2.dylib ]]; then
  echo "Patched mpv is missing; run scripts/build-mpv-adapter.sh first." >&2
  exit 1
fi
app="$PROJECT_ROOT/artifacts/HDR Player.app"
# Rebuild the generated bundle so removed libraries/resources cannot survive.
rm -rf "$app/Contents"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/debug/HDRPlayer "$app/Contents/MacOS/"
cp .build/debug/HDRHarness "$app/Contents/MacOS/"
cp -R .build/debug/MetalDLSSVideo_HDRPlayer.bundle "$app/Contents/Resources/"
cp -R .build/debug/MetalDLSSVideo_HDRHarness.bundle "$app/Contents/Resources/"
cp apps/macos/Info.plist "$app/Contents/Info.plist"
bash scripts/prepare-frame-runtime.sh "$app/Contents/MacOS"
runtime_args=("$app")
model_package="${MLXDLSS_NEURAL_RENDERING_PACKAGE:-$PROJECT_ROOT/models/neural-rendering/NeuralRendering.dlssmodel}"
if [[ "${BUNDLE_NEURAL_MODEL:-1}" == 1 && -f "$model_package/weights.safetensors" ]]; then
  runtime_args+=(--model "$model_package")
fi
python3 scripts/bundle-player-runtime.py "${runtime_args[@]}"
codesign --force --sign - "$app/Contents/MacOS/mlx.metallib"
# MLX resolves kernels beside the Mach-O that contains its runtime. The
# diagnostic executable and mpv's shared engine therefore need both locations.
cp "$app/Contents/MacOS/mlx.metallib" "$app/Contents/Frameworks/mlx.metallib"
codesign --force --sign - "$app/Contents/MacOS/HDRHarness"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built: $app"
