# v1.0 progress

Current issue: #35 on `feat/35-hevc-cache` (PR open). #39 is in PR #73 (`Refs #39`). #37 (`perf/37-enhancement-floor`, worktree `artifacts/wt-37`) is with an implementer subagent.
Next step: merge #35 and #39, then #36 (brief in the coordinator's `artifacts/goal-run/36-brief.md`), then #3's agent parts (settled capture script and human steps).

## Blocked

None.

## Facts

- 2026-09-22 cleanup: #38 (system PiP removed), #40 (large evidence logs removed) and #41 (rejected MLX-DLSS tests removed) are closed. A deslop pass ran over the root code and the MLX-DLSS and mpv fork additions.
- `bash scripts/check.sh` runs `doctor.sh --toolchain` first and is rerunnable on the same build tree since PR #50. Xcode updates remove the Metal Toolchain; `xcodebuild -downloadComponent MetalToolchain` restores it.
- `bash scripts/build-harness.sh` is the one app build. It builds the pinned libplacebo and the frame-engine mpv through `build-mpv-adapter.sh`, which wipes and reconfigures `artifacts/libplacebo-build` and `artifacts/mpv-build` whenever a pin, the build script or a Homebrew Cellar version changes. Stale mpv builds no longer need manual deletion.
- Prepared uses `policy=direct`; mpv `484b01b` emits no clock-holding preview under direct, so switching enhancement on while playing holds no clock. Adaptive keeps the preview.
- `HDRPLAYER_DEVELOPER_MODES=1` restores Live and Adaptive. The lifecycle smoke runs ordinary and developer modes; `prepared-playback` is the source-rate check.
- `preferences-read` smoke fails intermittently (about 1 in 5) because volume and mute are saved from polled state; seen on main before #34.
- Float Video is a `VideoPlacement` enum (`apps/macos/Sources/VideoPlacement.swift`); `scripts/test-floating-video.py` drives it on the real app, including over another app's fullscreen Space with the local helper in `tools/FloatingSpaceReference`.
- Prepared segments are HEVC Main10 PQ frame files (`HDRCacheFrames.swift`); Float32 stays as the reference storage the old tests pin. `PreparedHEVCReferenceTests` need `artifacts/public-hdr-source-audit/apple-advanced-hdr10plus-aac.mp4` and add about 100 s to `swift test`.
- App smokes hang if the player window opens off the active Space (#74); run them while the desktop Space is active.
- Give a worktree its fixtures with `cp -c` (APFS clones), never symlinks. `preparedReplacementSharesCacheAndRejectsChangedSource` appends a byte to its "copy" of `hdr10-30.mp4`, and `copyItem` copies a symlink as a symlink, so a symlinked worktree corrupts the main checkout's fixture (its SHA-256 must stay `8ae84e52…`, as in `assets/test-clips/manifest.json`).
- The controls smoke (`scripts/test-player-lifecycle-playback.py`) can time out on its frame-step check right after a fresh mpv build; rerun it once before debugging (#59).
- Many scripts are pinned by SHA-256 at runtime (for example `review-reference-sequence.py`, `analyze-flash-reference.py`). CI runs tests that check those pins; `check.sh` does not.
- The Adaptive media-gate WIP for AirPods sits on `wip/*` branches in `ScriptType/mpv` (#33, deferred).
