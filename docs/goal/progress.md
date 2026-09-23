# v1.0 progress

Current issues: #16 agent part on `docs/16-human-checks`. #34 on `feat/34-prepared-only` (worktree `artifacts/wt-42`) and #35 on `feat/35-hevc-cache` (worktree `artifacts/wt-35`) are with implementer subagents.
Next step: land #16's agent part, then review and land #34 and #35. #37 needs the GPU to itself, so it waits until the #34 and #35 GPU runs are done.

## Blocked

None.

## Facts

- 2026-09-22 cleanup: #38 (system PiP removed), #40 (large evidence logs removed) and #41 (rejected MLX-DLSS tests removed) are closed. A deslop pass ran over the root code and the MLX-DLSS and mpv fork additions.
- `bash scripts/check.sh` runs `doctor.sh --toolchain` first and is rerunnable on the same build tree since PR #50. Xcode updates remove the Metal Toolchain; `xcodebuild -downloadComponent MetalToolchain` restores it.
- `bash scripts/build-harness.sh` is the one app build. It builds the pinned libplacebo and the frame-engine mpv through `build-mpv-adapter.sh`, which wipes and reconfigures `artifacts/libplacebo-build` and `artifacts/mpv-build` whenever a pin, the build script or a Homebrew Cellar version changes. Stale mpv builds no longer need manual deletion.
- The controls smoke (`scripts/test-player-lifecycle-playback.py`) can time out on its frame-step check right after a fresh mpv build; rerun it once before debugging (#59).
- Many scripts are pinned by SHA-256 at runtime (for example `review-reference-sequence.py`, `analyze-flash-reference.py`). CI runs tests that check those pins; `check.sh` does not.
- The Adaptive media-gate WIP for AirPods sits on `wip/*` branches in `ScriptType/mpv` (#33, deferred).
