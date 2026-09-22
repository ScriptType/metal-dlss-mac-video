# Goal: v1.0 (M3)

You are finishing the first daily-usable release of this macOS HDR video player on the owner's MacBook Pro. The Mac is a Mac15,3 with an M3, 16 GB of memory and a built-in XDR display. The owner is not watching. Work through the milestone one issue at a time until the oracle reports the goal as met.

Read this file in full at the start of every session, after every compaction, and before every new issue.

## What v1.0 means

A person opens a local HDR10, HLG or Dolby Vision file and it plays correctly through mpv. They prepare it for neural enhancement, which runs in the background overnight if needed and resumes after a relaunch. They then watch the enhanced version at source rate from a cache that holds a whole film. The floating video window replaces picture-in-picture. Anything that needs M5 Max hardware (#8) or real-time neural playback is out of scope.

#34 sets the playback-mode policy. Its recommendation is the default: Prepared is the only user-facing enhancement mode on the M3. If the owner has commented otherwise on #34 by the time you reach it, follow the comment.

## Definition of done

A full run of `python3 scripts/goal-status.py` ends with a status line reading MET at the current `origin/main` commit. That requires all of the following:

- #34, #35, #36, #37, #38, #40, #41 and #42 are closed as completed by a merged PR, with every box ticked.
- #3, #16, #17 and #39 are either closed as completed with every box ticked, or open with `needs-human` and `ready-for-human` and only items marked **Human** left unticked.
- The "Done when" text of those twelve issues is unchanged. Ticking boxes is fine. Rewording, adding or removing items fails the oracle.
- Any other issue added to the milestone is closed. No PR is open.
- `bash scripts/check.sh` exits 0, and the tree is clean at `origin/main` before and after it.
- Every submodule pin is on its fork's `origin/hdr-player` branch.

`scripts/goal-status.py` is the oracle. Do not edit it; it checks that it has a single commit on `origin/main`. If you believe it is wrong, stop as described under "When stuck".

## Session start

1. Run `pwd` and `git status`. Read `docs/goal/progress.md` and `git log --oneline -15`.
2. Run `bash scripts/doctor.sh` and `df -h .`. If either fails, fix the environment first. Xcode updates remove the Metal Toolchain; `xcodebuild -downloadComponent MetalToolchain` restores it. Keep at least 15 GiB free.
3. Run `python3 scripts/goal-status.py --quick` to see which issues remain.
4. Pick the first remaining issue in the work order below that is not labeled `blocked`.

## Work order

Build the base first, then the features:

1. #42 Fail fast on a missing toolchain, and build the app fresh from one command.
2. #34 Playback-mode policy.
3. #37 Attribute the ~90 ms per-frame enhancement floor.
4. #49 Store mastering-display primaries in R/G/B order.
5. #35 10-bit HEVC Prepared cache.
6. #36 Whole-file background preparation with resume.
7. #17 Floating video window. Start from the core of PR #22, not its branch. The PR comment explains what to take.
8. #39 Re-read EDR headroom on screen change.
9. #3 and #16. Write the agent parts and `docs/human-checks.md`.

#38, #40 and #41 were finished during the 2026-09-22 cleanup.

## One issue at a time

1. Re-read the issue and its comments. Its "Done when" list is the contract. Do not edit it. If an item is vague, state your stricter reading in an issue comment before coding.
2. Create a branch from `origin/main`. Use a worktree under `artifacts/` if a long build must keep running elsewhere. A new worktree needs `git submodule update --init vendor/MLX-DLSS vendor/mpv`, `npm --prefix apps/controls ci`, and its own `bash scripts/build-mpv-adapter.sh` before any app check.
3. Make the smallest change that meets the contract. Commit in small steps that each build.
4. Verify on the real artifact. For app behavior, build the app and drive it with the existing smoke and lifecycle tooling. Paste the relevant command output into the issue.
5. Spawn a fresh reviewer subagent that sees only the diff and the issue. Tell it to assume the code is wrong and to report only correctness gaps. Fix real findings and dismiss noise with a reason.
6. Tick the finished boxes in the issue body. Update `docs/goal/progress.md` on the branch. Open a PR. For an agent issue, the PR body says `Closes #N`. For a `needs-human` issue, it says `Refs #N`, never `Closes`.
7. Wait for CI with `gh pr checks <PR> --watch --interval 60` as a foreground command with a 10-minute tool timeout; repeat until it finishes. Never end a turn just to wait. Squash-merge when CI is green and the review has no open correctness findings. Delete the branch.
8. Run `git switch main && git pull --ff-only`, then `python3 scripts/goal-status.py --quick`, and paste its output.

## Repository rules

- Submodule changes land on the fork's `hdr-player` branch (`ScriptType/mpv`, `ScriptType/MLX-DLSS`, `ScriptType/Erika`) before the root pin moves. Never pin a commit that is only on a `wip/*` branch.
- Documentation states results in a few sentences with the numbers that matter. Do not write evidence essays. Do not commit run logs, JSON traces or captures. They go in `artifacts/`, which is ignored.
- Earlier agents wrote a lot of confident prose. Treat claims in `docs/` as hypotheses and check them against the code before you rely on them.
- `CONTRIBUTING.md` still applies. Never commit models, media, credentials or build outputs.
- If a workaround needs a paragraph-long comment to justify it, the code is wrong. Fix the code.

## Forbidden

- Editing, skipping, deleting or weakening a test or check so that it passes. If a test is wrong, fix it in its own commit with the reason in the message, and mention it in the PR.
- Stubs, placeholders, `TODO` bodies or hard-coded values that only satisfy a test.
- Claiming a physical display, audio, sleep or input result that no person observed. Automated captures are not physical verification.
- Closing an issue without pasting the output that proves each "Done when" item.
- Force-pushing `main` or any `hdr-player` branch. Rewriting published history. Deleting another person's branch.
- Widening scope. A bug found on the way becomes a new issue, labeled and added to the milestone only if v1.0 needs it.

## Human-only checks

Some items need a person looking at the XDR display, listening, closing the lid or pressing keys. For those:

1. Do every agent-side part of the issue.
2. Add numbered steps to `docs/human-checks.md` with exact commands, clips and what to look for. Each step must take under five minutes.
3. Tick every agent item in the issue body, then comment with what is ready. Add the label `ready-for-human` and move on. Never tick an item marked **Human**, and never close a `needs-human` issue yourself.

Do not wait for the owner. Do not ask questions in the chat. The run is unattended.

## When stuck

After two different attempts at the same problem fail, stop retrying. Write the hypothesis, what you tried and the evidence in an issue comment and in `docs/goal/progress.md`. Add the label `blocked`, then continue with the next issue. A new approach must attack a different assumption, not repeat the last one with small changes. Before stopping, revisit each `blocked` issue once with what you learned since.

Stop the whole run only in these cases. Write a note in `docs/goal/progress.md`, commit it through a PR, and end your turn with the line `GOAL BLOCKED: <reason>`.

- Every remaining agent issue is `blocked` after the revisit.
- The oracle contradicts the issues, for example it requires something an issue forbids.
- The next step needs one of these irreversible actions: force-push, deleting a remote branch, tag or release, deleting files in `artifacts/` you did not create, or changing repository settings.

Deleting tracked files in a PR is reversible and is not a reason to stop.

## Machine limits

- 16 GB of memory. Run one heavy build or GPU benchmark at a time. Keep `BUILD_JOBS=2`, the default in `scripts/env.sh`.
- Evaluation of the goal is skipped while background shells or subagents run. Stop them before the final oracle run.
- GPU timing is only valid with no other GPU work running. Record the input, the processing size and the warmed frame count for every number.
- `artifacts/` already holds about 40 GB. Delete only what you created, and only when it is merged or no longer needed.

## Progress file

`docs/goal/progress.md` is the handoff to the next session. Keep it under 60 lines. Overwrite it; do not append a log. It holds:

- the current issue and branch
- the next step
- any blocked issues, with one line each on why
- facts learned that the next session would otherwise rediscover

Commit it on the issue branch, so it merges with the issue's PR.
