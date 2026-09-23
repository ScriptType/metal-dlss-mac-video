#!/usr/bin/env python3
"""Judge one physical sleep/wake cycle recorded by HDRPLAYER_LIFECYCLE_LOG.

--expect paused: playback was paused before sleep and must stay paused at the same position.
--expect playing: playback was playing before sleep and must resume and advance after wake.
Only an IOKit system-will-sleep followed by system-has-powered-on counts as a cycle.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

POSITION_TOLERANCE_SECONDS = 0.1
RESUMED_ADVANCE_SECONDS = 3.0


def judge(rows: list[dict], expect: str) -> list[tuple[bool, str]]:
    events = [row["event"] for row in rows]
    try:
        sleep = events.index("system-will-sleep")
        wake = events.index("system-has-powered-on", sleep + 1)
    except ValueError:
        return [(False, "no IOKit system-will-sleep followed by system-has-powered-on in the log")]
    first_hook = min([sleep] + [i for i, name in enumerate(events[:wake]) if name == "will-sleep.before-pause"])
    before = rows[first_hook]["state"]
    after = [row["state"] for row in rows[wake + 1:] if row["event"] != "diagnostic-finish" and "position" in row["state"]]
    if not after:
        return [(False, "no player state was recorded after wake")]
    results = [
        (all(state.get("source") == before.get("source") for state in after), f"source unchanged: {before.get('source')}"),
        (all(state.get("videoTrackID") == before.get("videoTrackID") for state in after), "video track unchanged"),
    ]
    if expect == "paused":
        drift = max(abs(state["position"] - before["position"]) for state in after)
        results += [
            (before.get("paused") is True, "paused before sleep"),
            (all(state.get("paused") is True for state in after), f"paused in all {len(after)} states after wake"),
            (drift <= POSITION_TOLERANCE_SECONDS, f"position held at {before['position']:.3f} s (max drift {drift:.3f} s)"),
        ]
    else:
        advance = max(state["position"] for state in after) - after[0]["position"]
        results += [
            (before.get("paused") is False, "playing before sleep"),
            (any(state.get("paused") is False for state in after), "playing again after wake"),
            (advance >= RESUMED_ADVANCE_SECONDS, f"position advanced {advance:.2f} s after wake (needs {RESUMED_ADVANCE_SECONDS} s)"),
        ]
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log", type=Path)
    parser.add_argument("--expect", choices=["paused", "playing"], required=True)
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.log.read_text().splitlines() if line.strip()]
    results = judge(rows, args.expect)
    for ok, text in results:
        print(f"{'PASS' if ok else 'FAIL'}  {text}")
    passed = all(ok for ok, _ in results)
    print("SLEEP/WAKE CHECK:", "PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
