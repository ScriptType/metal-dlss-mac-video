# v1.0 progress

Current issue: #34 on `feat/34-prepared-only` (worktree `artifacts/wt-42`). #35 is with an implementer subagent on `feat/35-hevc-cache` (worktree `artifacts/wt-35`).
Next step: merge #34, then review and land #35. #37 needs the GPU to itself, so it waits until the #35 GPU runs are done. #39 needs a small mpv fork change (observe `NSApplication.didChangeScreenParametersNotification` in `observeEmbeddedHost`) plus an app handler; start it after #35 merges.

## Blocked

None.

## Facts

- 2026-09-22 cleanup: #38 (system PiP removed), #40 (large evidence logs removed) and #41 (rejected MLX-DLSS tests removed) are closed. A deslop pass ran over the root code and the MLX-DLSS and mpv fork additions.
- `bash scripts/check.sh` runs `doctor.sh --toolchain` first and is rerunnable on the same build tree since PR #50. Xcode updates remove the Metal Toolchain; `xcodebuild -downloadComponent MetalToolchain` restores it.
- `bash scripts/build-harness.sh` is the one app build. It builds the pinned libplacebo and the frame-engine mpv through `build-mpv-adapter.sh`, which wipes and reconfigures `artifacts/libplacebo-build` and `artifacts/mpv-build` whenever a pin, the build script or a Homebrew Cellar version changes. Stale mpv builds no longer need manual deletion.
- Prepared uses `policy=direct`; mpv `484b01b` emits no clock-holding preview under direct, so switching enhancement on while playing holds no clock. Adaptive keeps the preview.
- `HDRPLAYER_DEVELOPER_MODES=1` restores Live and Adaptive. The lifecycle smoke runs ordinary and developer modes; `prepared-playback` is the source-rate check.
- `preferences-read` smoke fails intermittently (about 1 in 5) because volume and mute are saved from polled state; seen on main before #34.
- Give a worktree its fixtures with `cp -c` (APFS clones), never symlinks. `preparedReplacementSharesCacheAndRejectsChangedSource` appends a byte to its "copy" of `hdr10-30.mp4`, and `copyItem` copies a symlink as a symlink, so a symlinked worktree corrupts the main checkout's fixture (its SHA-256 must stay `8ae84e52…`, as in `assets/test-clips/manifest.json`).
- The controls smoke (`scripts/test-player-lifecycle-playback.py`) can time out on its frame-step check right after a fresh mpv build; rerun it once before debugging (#59).
- Many scripts are pinned by SHA-256 at runtime (for example `review-reference-sequence.py`, `analyze-flash-reference.py`). CI runs tests that check those pins; `check.sh` does not.
- The Adaptive media-gate WIP for AirPods sits on `wip/*` branches in `ScriptType/mpv` (#33, deferred).
