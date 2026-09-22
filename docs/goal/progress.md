# v1.0 progress

Current issue: #42. Branch: `fix/42-toolchain-fresh-build`.
Next step: merge the #42 PR, then start #34.

## Blocked

None.

## Facts

- 2026-09-22 cleanup: #38 (system PiP removed), #40 (large evidence logs removed) and #41 (rejected MLX-DLSS tests removed) are closed. A deslop pass ran over the root code and the MLX-DLSS and mpv fork additions.
- `bash scripts/check.sh` runs `doctor.sh --toolchain` first and is rerunnable on the same build tree since PR #50. Xcode updates remove the Metal Toolchain; `xcodebuild -downloadComponent MetalToolchain` restores it.
- `bash scripts/build-harness.sh` is the one app build. It builds the pinned libplacebo and the frame-engine mpv through `build-mpv-adapter.sh`, which wipes and reconfigures `artifacts/libplacebo-build` and `artifacts/mpv-build` whenever a pin, a configure argument or a Homebrew Cellar version changes. Stale mpv builds no longer need manual deletion.
- A new worktree needs `vendor/libplacebo` and its four nested `3rdparty` submodules (see `scripts/fetch-sources.py`) in addition to `vendor/MLX-DLSS` and `vendor/mpv`, plus `npm --prefix apps/controls ci` before `check.sh`.
- The controls smoke (`scripts/test-player-lifecycle-playback.py`) can time out on its frame-step check right after a fresh mpv build; rerun it once before debugging (#59).
- Many scripts are pinned by SHA-256 at runtime (for example `review-reference-sequence.py`, `analyze-flash-reference.py`). CI runs tests that check those pins; `check.sh` does not.
- The Adaptive media-gate WIP for AirPods sits on `wip/*` branches in `ScriptType/mpv` (#33, deferred).
