# v1.0 progress

Current issue: none. Start with #42.
Branch: none.
Next step: follow the session start in `docs/goal/GOAL.md`.

## Blocked

None.

## Facts

- 2026-09-22: `bash scripts/check.sh` passes on `main` 55ce82c after `xcodebuild -downloadComponent MetalToolchain`. Xcode 27 had removed the toolchain.
- The mpv pin 8d24633 is on `origin/hdr-player`. Adaptive media-gate WIP sits on `wip/*` branches in `ScriptType/mpv` (see #33). It is deferred.
- `artifacts/HDR Player.app` is stale (2026-09-10). Rebuild before any app check.
- Worktrees under `artifacts/*-checkout` belong to merged branches. They are clean. Leave them alone unless the owner asks for cleanup.
