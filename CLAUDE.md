# Agent notes

Active goal: `docs/goal/GOAL.md`. Read it before any work, and re-read it after compaction. State lives in `docs/goal/progress.md` and in the GitHub milestone `v1.0 (M3)`.

- Oracle: `python3 scripts/goal-status.py` (`--quick` between steps). Do not edit it.
- Environment check: `bash scripts/doctor.sh`. Full check: `bash scripts/check.sh`.
- Submodule changes land on the fork's `hdr-player` branch before the root pin moves.
- No run logs or captures in `docs/`. They go in `artifacts/`.
- Never tick an item marked Human, and never claim a physical display, audio or input result nobody observed.
