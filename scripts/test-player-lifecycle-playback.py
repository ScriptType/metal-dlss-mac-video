#!/usr/bin/env python3
"""Run the existing real DOM/media smoke and verify native recorder teardown.

Uses the GPU/window. Run only in a coordinated test window. This never requests
sleep, posts a lifecycle notification, or changes VoiceOver preferences.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=ROOT / ".build/debug/HDRPlayer")
    parser.add_argument("--source", type=Path, default=ROOT / "assets/test-clips/player-controls.mkv")
    parser.add_argument("--mpv", type=Path, default=ROOT / "artifacts/mpv-build/libmpv.2.dylib")
    parser.add_argument("--shared", type=Path, default=ROOT / ".build/debug/libFrameEngineShared.dylib")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/player-lifecycle-playback")
    args = parser.parse_args()
    executable, source, mpv, shared = (getattr(args, key).resolve() for key in ("executable", "source", "mpv", "shared"))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report: dict = {"passed": False, "scope": "Actual DOM/media teardown; no physical sleep or VoiceOver qualification", "checks": []}
    paths = {"HDRPlayer": executable, "libmpv": mpv, "FrameEngineShared": shared}
    report["binaries"] = {name: {"path": str(path), "beforeSHA256": sha256(path)} for name, path in paths.items()}
    env = dict(os.environ)
    env.update(METAL_DLSS_MPV_LIBRARY=str(mpv), HDRPLAYER_UI_SMOKE_KIND="lifecycle",
               HDRPLAYER_UI_SMOKE_REPORT=str(output / "dom.json"), HDRPLAYER_LIFECYCLE_LOG=str(output / "lifecycle.jsonl"))
    env.pop("HDRPLAYER_UI_SMOKE_KEEP_PREFERENCES", None)
    # Avoid accepting stale success after a launch failure.
    for name in ("dom.json", "lifecycle.jsonl"):
        (output / name).unlink(missing_ok=True)
    try:
        with (output / "player.log").open("w") as log:
            process = subprocess.run([str(executable), str(source)], cwd=ROOT, env=env,
                                     stdout=log, stderr=subprocess.STDOUT, timeout=120, check=False)
        report["exitCode"] = process.returncode
        assert process.returncode == 0, f"Player exited {process.returncode}"
        dom = json.loads((output / "dom.json").read_text())
        assert dom.get("passed") is True, dom.get("failure", "DOM smoke failed")
        report["domChecksPassed"] = len(dom["checks"])
        report["checks"].append("Existing DOM/media smoke passed and the process exited cleanly")
        rows = [json.loads(line) for line in (output / "lifecycle.jsonl").read_text().splitlines()]
        events = [row["event"] for row in rows]
        begin, destroyed, finish = (events.index(name) for name in
            ("termination-requested", "native-worker-destroyed", "diagnostic-finish"))
        assert begin < destroyed < finish == len(rows) - 1, "Teardown sequence or final flush is incomplete"
        assert rows[begin]["details"]["nativeChildViews"] > 0, "No native media view existed before teardown"
        assert rows[destroyed]["details"]["nativeChildViews"] == 0, "Native child view survived core destruction"
        assert rows[finish]["details"]["workerDestroyed"] is True
        assert rows[finish]["details"]["nativeChildViews"] == 0
        report["checks"].append("Termination request precedes native view/core destruction and final log flush")
        exact = [row["state"] for row in rows if row["state"].get("exactDisplayedPTSAvailable") is True]
        assert exact, "No native exact displayed timestamp was recorded"
        assert all(type(state["displayed-source-pts"]) is int and
                   type(state["displayed-timebase-num"]) is int and state["displayed-timebase-num"] > 0 and
                   type(state["displayed-timebase-den"]) is int and state["displayed-timebase-den"] > 0 for state in exact)
        assert rows[begin]["state"]["source"] == str(source)
        assert rows[begin]["state"]["paused"] is True, "DOM smoke should finish with native playback paused"
        report["exactTimestampSnapshots"] = len(exact)
        report["checks"].append("Source, paused transport state and native rational displayed timestamps were recorded")
        assert all(row["kernelSleepWakeCycles"] == 0 and row["physicalSleepWakeObserved"] is False for row in rows)
        report["checks"].append("No physical sleep cycle was inferred during the media-only check")
        report["passed"] = True
    except (AssertionError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        report["failure"] = str(error)
    finally:
        for name, path in paths.items():
            report["binaries"][name]["afterSHA256"] = sha256(path)
        unchanged = all(item["beforeSHA256"] == item["afterSHA256"] for item in report["binaries"].values())
        report["binariesUnchanged"] = unchanged
        if not unchanged:
            report["passed"] = False
            report["failure"] = "A measured binary changed during the smoke"
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
