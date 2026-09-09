#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
swift build --product FrameEngineShared --jobs "$BUILD_JOBS"
mkdir -p artifacts
bash scripts/prepare-frame-runtime.sh "$PROJECT_ROOT/artifacts"
xcrun clang -std=c11 -Wall -Wextra -Werror tools/CFrameConsumer/main.c \
  -I packages/CFrameEngine/include -L .build/debug -lFrameEngineShared \
  -framework CoreFoundation -framework CoreVideo \
  -Wl,-rpath,"$PROJECT_ROOT/.build/debug" -o artifacts/frame-api-consumer
artifacts/frame-api-consumer
