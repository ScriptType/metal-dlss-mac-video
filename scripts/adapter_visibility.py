#!/usr/bin/env python3
"""Qualify measured adapter intervals from actual native window observations."""
import argparse
import json
import math
from pathlib import Path


def window_events(text, adapter):
    events = []
    for line in text.splitlines():
        if adapter == "mpv":
            prefix = "HDRPLAYER_MPV_WINDOW_STATE "
            if not line.startswith(prefix):
                continue
            raw = json.loads(line[len(prefix):])
            event = {key: raw.get(key) for key in (
                "hostSeconds", "isVisible", "occlusionVisible", "isMiniaturized",
                "appActive", "windowNumber")}
        elif adapter == "erika":
            if not line.startswith('{') or '"erika_native_window"' not in line:
                continue
            raw = json.loads(line)
            if raw.get("event") != "erika_native_window":
                continue
            state = raw["state"]
            event = dict(hostSeconds=raw.get("host"), isVisible=state.get("visible"),
                occlusionVisible=state.get("occlusionVisible"), isMiniaturized=state.get("miniaturized"),
                appActive=state.get("active"), windowNumber=state.get("windowNumber"))
        else:
            raise ValueError("unknown adapter")
        if not isinstance(event["hostSeconds"], (int, float)) or not math.isfinite(event["hostSeconds"]):
            raise ValueError("invalid native window host timestamp")
        events.append(event)
    return sorted(events, key=lambda event: event["hostSeconds"])


def completed_window(engine):
    frames = [frame for frame in engine.get("frames", []) if not frame.get("warmup", True)
              and "completedHostSeconds" in frame]
    if not frames or engine.get("retainedSamples") != engine.get("completedTotal"):
        raise ValueError("complete retained warmed-frame inventory required for visibility qualification")
    return (min(frame["submittedHostSeconds"] for frame in frames),
            max(frame["completedHostSeconds"] for frame in frames))


def qualify_visibility(events, start, end, maximum_gap=1.5):
    if not all(math.isfinite(value) for value in (start, end, maximum_gap)) or end <= start or maximum_gap <= 0:
        raise ValueError("invalid measured window")
    events = sorted(events, key=lambda event: event["hostSeconds"])
    before = [event for event in events if event["hostSeconds"] <= start]
    selected = before[-1:] + [event for event in events if start < event["hostSeconds"] <= end]
    reasons = []
    if not before:
        reasons.append("no native state at or before measured start")
    if not selected:
        reasons.append("no native observations in measured interval")
    gaps = []
    if selected:
        gaps = [max(0, start - selected[0]["hostSeconds"])]
        gaps += [b["hostSeconds"] - a["hostSeconds"] for a, b in zip(selected, selected[1:])]
        gaps.append(end - selected[-1]["hostSeconds"])
    if gaps and max(gaps) > maximum_gap:
        reasons.append("native observation gap exceeds allowed interval")
    visible_seconds = 0.0
    inactive_seconds = 0.0
    invalid = []
    window_numbers = set()
    for index, event in enumerate(selected):
        duration = max(0, min(end, selected[index + 1]["hostSeconds"] if index + 1 < len(selected) else end)
                       - max(start, event["hostSeconds"]))
        valid = (event.get("isVisible") in (True, 1) and event.get("occlusionVisible") in (True, 1)
                 and event.get("isMiniaturized") in (False, 0)
                 and isinstance(event.get("windowNumber"), int) and event["windowNumber"] > 0)
        if valid:
            visible_seconds += duration
        else:
            invalid.append(event)
        if event.get("appActive") in (False, 0):
            inactive_seconds += duration
        if event.get("windowNumber") is not None:
            window_numbers.add(event["windowNumber"])
    if invalid:
        reasons.append("native window was hidden, occluded, minimized or its state was unavailable")
    if len(window_numbers) > 1:
        reasons.append("native window identity changed within measured interval")
    return {"eligible": not reasons, "startHostSeconds": start, "endHostSeconds": end,
        "durationSeconds": end - start, "nativeObservationCount": len(selected),
        "maximumAllowedObservationGapSeconds": maximum_gap, "maximumObservationGapSeconds": max(gaps, default=None),
        "observedVisibleSeconds": visible_seconds, "observedInactiveSeconds": inactive_seconds,
        "ineligibleObservations": invalid, "reasons": reasons,
        "scope": "Native NSWindow state and bounded periodic/transition coverage; app activation is informational; no physical scanout measurement"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = qualify_visibility(window_events(args.log.read_text(), "erika"),
                                    *completed_window(json.loads(args.engine.read_text())))
    except (ValueError, KeyError, OSError) as error:
        result = {"eligible": False, "reasons": [str(error)]}
    args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"visibilityEligible": result["eligible"], "report": str(args.report)}))
    return 0 if result["eligible"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
