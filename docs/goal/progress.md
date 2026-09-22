# v1.0 progress

Current issue: none. Start with #42.
Branch: none.
Next step: follow the session start in `docs/goal/GOAL.md`.

## Blocked

None.

## Facts

- 2026-09-22 cleanup: #38 (system PiP removed), #40 (large evidence logs removed) and #41 (rejected MLX-DLSS tests removed) are closed. A deslop pass ran over the root code and the MLX-DLSS and mpv fork additions.
- `bash scripts/check.sh` passes on `main` and is rerunnable on the same build tree since PR #50. Xcode updates remove the Metal Toolchain; `xcodebuild -downloadComponent MetalToolchain` restores it.
- `scripts/bootstrap.sh` cannot finish on a fresh clone; see the comment on #42.
- A fresh worktree fails `check.sh` with `tailwindcss: command not found` until `npm --prefix apps/controls ci`.
- An `artifacts/mpv-build` built before mpv `8d24633` fails the controls smoke with a CoreAudio channel-layout error (-50). Rebuild with `bash scripts/build-mpv-adapter.sh`.
- The controls smoke (`scripts/test-player-lifecycle-playback.py`) can time out on its frame-step check right after a fresh mpv build; rerun it once before debugging (#59).
- Many scripts are pinned by SHA-256 at runtime (for example `review-reference-sequence.py`, `analyze-flash-reference.py`). CI runs tests that check those pins; `check.sh` does not.
- The Adaptive media-gate WIP for AirPods sits on `wip/*` branches in `ScriptType/mpv` (#33, deferred).
