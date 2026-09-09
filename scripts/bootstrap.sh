#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "Apple Silicon macOS required" >&2; exit 1; }
[[ -d "$DEVELOPER_DIR" ]] || { echo "Install full Xcode, then rerun (DEVELOPER_DIR=$DEVELOPER_DIR)" >&2; exit 1; }
command -v brew >/dev/null || { echo "Install Homebrew from https://brew.sh, then rerun" >&2; exit 1; }
mkdir -p artifacts
HOMEBREW_NO_AUTO_UPDATE=1 brew bundle install --file Brewfile --no-upgrade
if ! command -v rustup >/dev/null; then
  brew install rustup
  export PATH="$(brew --prefix rustup)/bin:$PATH"
fi
rustup toolchain install 1.98.0 --profile minimal
if ! xcrun metal --version; then
  xcodebuild -runFirstLaunch
  xcodebuild -downloadComponent MetalToolchain
fi
python3 scripts/fetch-sources.py
uv sync --frozen --all-groups
python3 scripts/fetch-models.py
uv run --frozen scripts/generate-fixtures.py
bash scripts/build-harness.sh
bash scripts/build-mlx.sh
vendor/MLX-DLSS/scripts/build-native-app.sh
bash scripts/build-playback-cores.sh
bash scripts/doctor.sh
