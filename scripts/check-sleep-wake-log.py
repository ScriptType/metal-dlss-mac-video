#!/usr/bin/env python3
"""Judge one physical sleep/wake cycle recorded by HDRPLAYER_LIFECYCLE_LOG.

--expect paused: playback was paused before sleep and must stay paused on the same displayed frame.
--expect playing: playback was playing before sleep and must resume within a few seconds of wake,
with the displayed frame advancing.
Only an IOKit system-will-sleep followed by system-has-powered-on counts as a cycle, and the
player must quit cleanly at least OBSERVED_AFTER_WAKE_SECONDS after wake.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

POSITION_TOLERANCE_SECONDS = 0.1
RESUMED_ADVANCE_SECONDS = 3.0
RESUME_WITHIN_SECONDS = 5.0
OBSERVED_AFTER_WAKE_SECONDS = 10.0


def displayed(state: dict) -> int | None:
    return state.get("displayed-source-pts") if state.get("exactDisplayedPTSAvailable") else None


def judge(rows: list[dict], expect: str) -> list[tuple[bool, str]]:
    events = [row["event"] for row in rows]
    try:
        sleep = events.index("system-will-sleep")
        wake = events.index("system-has-powered-on", sleep + 1)
    except ValueError:
        return [(False, "no IOKit system-will-sleep followed by system-has-powered-on in the log")]
    first_hook = min([sleep] + [i for i, name in enumerate(events[:wake]) if name == "will-sleep.before-pause"])
    before = rows[first_hook]["state"]
    woke = rows[wake]["uptimeSeconds"]
    after = [row for row in rows[wake + 1:] if row["event"] != "diagnostic-finish" and "position" in row["state"]]
    finish = rows[-1] if events[-1] == "diagnostic-finish" else None
    results = [(finish is not None and finish["details"].get("workerDestroyed") is True,
                "player quit cleanly after wake (final diagnostic-finish with the worker destroyed)")]
    if not after:
        return results + [(False, "no player state was recorded after wake")]
    observed = after[-1]["uptimeSeconds"] - woke
    states = [row["state"] for row in after]
    results += [
        (observed >= OBSERVED_AFTER_WAKE_SECONDS, f"observed {observed:.1f} s after wake (needs {OBSERVED_AFTER_WAKE_SECONDS:.0f} s)"),
        (all(state.get("source") == before.get("source") for state in states), f"source unchanged: {before.get('source')}"),
        (all(state.get("videoTrackID") == before.get("videoTrackID") for state in states), "video track unchanged"),
    ]
    if expect == "paused":
        drift = max(abs(state["position"] - before["position"]) for state in states)
        frames = {displayed(state) for state in [before, *states]}
        results += [
            (before.get("paused") is True, "paused before sleep"),
            (all(state.get("paused") is True for state in states), f"paused in all {len(states)} states after wake"),
            (drift <= POSITION_TOLERANCE_SECONDS, f"position held at {before['position']:.3f} s (max drift {drift:.3f} s)"),
            (None not in frames and len(frames) == 1, f"displayed frame unchanged (source PTS {sorted(frames, key=str)})"),
        ]
    else:
        resumed = next((row for row in after if row["state"].get("paused") is False), None)
        resume_delay = resumed["uptimeSeconds"] - woke if resumed else float("inf")
        advance = max(state["position"] for state in states) - states[0]["position"]
        shown = [displayed(state) for state in states if displayed(state) is not None]
        results += [
            (before.get("paused") is False, "playing before sleep"),
            (resume_delay <= RESUME_WITHIN_SECONDS, f"playing again {resume_delay:.1f} s after wake (needs {RESUME_WITHIN_SECONDS:.0f} s)"),
            (advance >= RESUMED_ADVANCE_SECONDS, f"position advanced {advance:.2f} s after wake (needs {RESUMED_ADVANCE_SECONDS:.0f} s)"),
            (len(shown) >= 2 and shown[-1] > shown[0], "displayed frame advanced after wake"),
        ]
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log", type=Path)
    parser.add_argument("--expect", choices=["paused", "playing"], required=True)
    args = parser.parse_args()
    try:
        rows = [json.loads(line) for line in args.log.read_text().splitlines() if line.strip()]
        results = judge(rows, args.expect)
    except (OSError, ValueError, KeyError) as error:
        results = [(False, f"unreadable lifecycle log: {error}")]
    for ok, text in results:
        print(f"{'PASS' if ok else 'FAIL'}  {text}")
    passed = all(ok for ok, _ in results)
    print("SLEEP/WAKE CHECK:", "PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
