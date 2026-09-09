#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
brew_prefix="$(brew --prefix)"
mkdir -p artifacts/local
if [[ ! -f artifacts/libplacebo-build/build.ninja ]]; then
  # The pinned upstream include-header test omits dav1d's include directory.
  meson setup artifacts/libplacebo-build vendor/libplacebo \
    --prefix "$PROJECT_ROOT/artifacts/local" -Dtests=true -Ddemos=false \
    -Dopengl=disabled -Dvulkan=enabled -Dshaderc=enabled \
    "-Dc_args=-I$brew_prefix/opt/dav1d/include" "-Dcpp_args=-I$brew_prefix/opt/dav1d/include"
fi
meson compile -C artifacts/libplacebo-build -j "$BUILD_JOBS"
meson install -C artifacts/libplacebo-build
if [[ ! -f artifacts/mpv-build/build.ninja ]]; then
  meson setup artifacts/mpv-build vendor/mpv --buildtype=debugoptimized \
    --pkg-config-path "$PROJECT_ROOT/artifacts/local/lib/pkgconfig,$brew_prefix/lib/pkgconfig" \
    -Dlibmpv=true -Dtests=true -Dvulkan=enabled -Dvideotoolbox-pl=enabled \
    -Dcocoa=enabled -Dswift-build=enabled
fi
meson compile -C artifacts/mpv-build -j "$BUILD_JOBS"
cargo run --manifest-path vendor/Erika/Cargo.toml --locked -p xtask -- \
  deps build --all --profile lgpl --jobs "$BUILD_JOBS"
cargo build --manifest-path vendor/Erika/Cargo.toml --locked \
  -p erika_capi -p macos_native_demo -p metal_import_videotoolbox
