# Running the v1.0 goal

`GOAL.md` is the agent's specification. `condition.txt` is the `/goal` completion condition. It stays under the 4,000-character limit and points to `GOAL.md`. `progress.md` is the handoff between sessions. `scripts/goal-status.py` is the oracle both refer to.

## Before the first run

- Merge the PR that adds these files, so every branch cut from `main` carries them.
- Grant the terminal Screen Recording, Accessibility and Automation permissions. Several issues drive the app and capture its window, and nobody will be there to answer a prompt.
- Turn off the screen lock and keep the Mac on power.

## Start

```sh
caffeinate -dimsu env ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-opus-5-5 \
  claude --model claude-opus-5-5 --permission-mode auto
```

Then paste `/goal ` followed by the contents of `condition.txt`.

`ANTHROPIC_DEFAULT_HAIKU_MODEL` moves the `/goal` evaluator from Haiku to Opus 5.5. It also moves Claude Code's other small-model work, such as session summaries, to Opus 5.5. The evaluator cannot be set to `low` on its own. On Claude Code 2.1.280 it sends the lower of the session's effort and `medium`. The worker session keeps its own effort.

To run headless and watch the stream:

```sh
caffeinate -dimsu env ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-opus-5-5 \
  claude -p "/goal $(cat docs/goal/condition.txt)" --model claude-opus-5-5 \
  --permission-mode auto --output-format stream-json --verbose
```

If auto mode blocks `gh pr merge` or pushes to the forks, run one attended issue first and allow those commands.

## While it runs

- `python3 scripts/goal-status.py --quick` shows what remains.
- The evaluator reads only the transcript. It relies on the oracle output pasted there.
- Issues labeled `ready-for-human` have numbered steps in `docs/human-checks.md`. Do them, tick the **Human** boxes, and close the issue, or comment what failed.
- To change the playback-mode policy, comment on #34 before the agent reaches it.
