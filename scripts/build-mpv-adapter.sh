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
sources="$(git -C vendor/libplacebo rev-parse HEAD) $(git -C vendor/mpv rev-parse HEAD)
$(ls -d "$brew_prefix"/Cellar/*/*)"
# A configured build caches versioned Homebrew Cellar paths, so any source or
# Homebrew change configures from scratch.
configure() {
  local build="$1"
  local inputs="$sources
$*"
  if [[ "$(cat "$build/build-inputs.txt" 2>/dev/null)" != "$inputs" ]]; then
    rm -rf "$build"
    meson setup "$@"
    printf '%s\n' "$inputs" > "$build/build-inputs.txt"
  fi
}

# The pinned upstream include-header test omits dav1d's include directory.
configure artifacts/libplacebo-build vendor/libplacebo \
  --prefix "$PROJECT_ROOT/artifacts/local" -Dtests=true -Ddemos=false \
  -Dopengl=disabled -Dvulkan=enabled -Dshaderc=enabled \
  "-Dc_args=-I$brew_prefix/opt/dav1d/include" "-Dcpp_args=-I$brew_prefix/opt/dav1d/include"
meson compile -C artifacts/libplacebo-build -j "$BUILD_JOBS"
meson install -C artifacts/libplacebo-build
configure artifacts/mpv-build vendor/mpv --buildtype=debugoptimized \
  --pkg-config-path "$pkg_dir,$brew_prefix/lib/pkgconfig" \
  -Dframe-engine=enabled -Dlibmpv=true -Dtests=true -Dvulkan=enabled \
  -Dvideotoolbox-pl=enabled -Dcocoa=enabled -Dswift-build=enabled
meson compile -C artifacts/mpv-build -j "$BUILD_JOBS"
