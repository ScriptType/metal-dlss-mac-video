#!/usr/bin/env bash
# Source this from project scripts; does not change the system xcode-select.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  task_env_script="${BASH_SOURCE[0]}"
else
  task_env_script="${(%):-%x}"
fi
PROJECT_ROOT="$(cd "$(dirname "$task_env_script")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export BUILD_JOBS="${BUILD_JOBS:-2}"
export MLXDLSS_BUILD_JOBS="$BUILD_JOBS"
export CARGO_BUILD_JOBS="$BUILD_JOBS"
export CMAKE_BUILD_PARALLEL_LEVEL="$BUILD_JOBS"
export UV_PROJECT_ENVIRONMENT="$PROJECT_ROOT/.venv"
export CARGO_TARGET_DIR="$PROJECT_ROOT/artifacts/erika-target"
export MACOSX_DEPLOYMENT_TARGET=26.0
export LIBCLANG_PATH="${LIBCLANG_PATH:-$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib}"
