#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"

library_dir="$PROJECT_ROOT/.build/debug"
swift build --product FrameEngineShared --jobs "$BUILD_JOBS"
bash scripts/prepare-frame-runtime.sh
pkg_dir="$PROJECT_ROOT/artifacts/local/lib/pkgconfig"
mkdir -p "$pkg_dir"
cat > "$pkg_dir/frame-engine.pc" <<EOF
prefix=$PROJECT_ROOT
libdir=$library_dir
includedir=$PROJECT_ROOT/packages/CFrameEngine/include

Name: frame-engine
Description: Shared asynchronous HDR frame engine C ABI
Version: 1.0.0
Libs: -L\${libdir} -lFrameEngineShared -Wl,-rpath,\${libdir}
Cflags: -I\${includedir}
EOF

brew_prefix="$(brew --prefix)"
if [[ -f artifacts/mpv-build/build.ninja ]]; then
  # Refresh newly introduced Meson options before setting one on an older build.
  meson setup --reconfigure artifacts/mpv-build vendor/mpv
  meson setup --reconfigure artifacts/mpv-build vendor/mpv \
    --pkg-config-path "$pkg_dir,$brew_prefix/lib/pkgconfig" \
    -Dframe-engine=enabled -Dlibmpv=true
else
  meson setup artifacts/mpv-build vendor/mpv --buildtype=debugoptimized \
    --pkg-config-path "$pkg_dir,$brew_prefix/lib/pkgconfig" \
    -Dframe-engine=enabled -Dlibmpv=true -Dtests=true -Dvulkan=enabled \
    -Dvideotoolbox-pl=enabled -Dcocoa=enabled -Dswift-build=enabled
fi
meson compile -C artifacts/mpv-build -j "$BUILD_JOBS"
