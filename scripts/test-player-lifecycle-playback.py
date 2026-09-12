#!/usr/bin/env python3
"""Run the selected native/media smoke and verify native recorder teardown.

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


def floating_teardown(rows: list[dict], begin: int, destroyed: int, finish: int) -> dict:
    events = [row["event"] for row in rows]
    prepared = events.index("floating-video-termination-prepared")
    finished = events.index("floating-video-termination-finished")
    assert begin < prepared < finished < destroyed < finish, "Floating/native teardown order is incomplete"
    entered_indices = [index for index, event in enumerate(events) if event == "floating-video-entered"]
    assert entered_indices and entered_indices[-1] < begin, "No final floating entry before termination"
    entered = rows[entered_indices[-1]]["details"]
    retained = rows[prepared]["details"]
    released = rows[finished]["details"]
    assert entered["active"] is True and entered["phase"] == "floating"
    assert retained["active"] is True and retained["phase"] == "terminating"
    for key in ("nativeChildIdentities", "nativeChildLayerIdentities"):
        identities = entered[key]
        assert isinstance(identities, list) and identities and all(isinstance(value, str) and value for value in identities), \
            f"Missing native identities at entry: {key}"
        assert retained[key] == identities, f"Native identity changed before worker teardown: {key}"
        assert released[key] == [], f"Native identity survived worker teardown: {key}"
    host = entered["hostIdentity"]
    assert isinstance(host, str) and host
    assert retained["hostIdentity"] == released["hostIdentity"] == host, "Video host identity changed"
    for window in ("mainWindow", "floatingWindow"):
        identity = entered[window]["identity"]
        assert isinstance(identity, str) and identity and entered[window]["attached"] is True
        assert retained[window]["attached"] is True and retained[window]["identity"] == identity, \
            f"Window ownership changed before native teardown: {window}"
    assert retained["hostWindow"]["attached"] is True
    assert retained["hostWindow"]["identity"] == retained["floatingWindow"]["identity"]
    assert released["phase"] == "finished" and released["active"] is False
    assert released["floatingWindow"]["attached"] is False
    assert released["mainWindow"]["attached"] is True and released["hostWindow"]["attached"] is True
    assert released["hostWindow"]["identity"] == released["mainWindow"]["identity"] == entered["mainWindow"]["identity"], \
        "Finished host is not back in the same main window"
    assert released["mainSlotIdentity"] == entered["mainSlotIdentity"]
    assert released["homeConstraintsActive"] == 4 and released["floatingConstraintsActive"] == 0
    return {"lastEntered": entered, "terminationPrepared": retained, "terminationFinished": released,
            "eventIndices": {"entered": entered_indices[-1], "terminationRequested": begin,
                             "prepared": prepared, "finished": finished, "nativeWorkerDestroyed": destroyed,
                             "diagnosticFinish": finish}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=ROOT / ".build/debug/HDRPlayer")
    parser.add_argument("--source", type=Path, help="Override the repository fixture (player-controls.mkv by default; playback/pq-30-60s.mkv for floating-video)")
    parser.add_argument("--mpv", type=Path, default=ROOT / "artifacts/mpv-build/libmpv.2.dylib")
    parser.add_argument("--shared", type=Path, default=ROOT / ".build/debug/libFrameEngineShared.dylib",
                        help="Shared binary to hash; its loaded path is selected by native linkage, not this argument")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/player-lifecycle-playback")
    parser.add_argument("--scenario", choices=("controls", "pip", "pip-prepared", "pip-reconfigure", "floating-video"), default="controls")
    args = parser.parse_args()
    if args.source is None:
        args.source = (ROOT / "assets/test-clips/playback/pq-30-60s.mkv" if args.scenario == "floating-video"
                       else ROOT / "assets/test-clips/player-controls.mkv")
    output = args.output.absolute()
    # Check before resolving symlinks or touching any retained evidence.
    if output.is_symlink() or (output.exists() and (not output.is_dir() or any(output.iterdir()))):
        parser.error(f"Refusing existing nonempty output or symlink: {output}")
    executable, source, mpv, shared = (getattr(args, key).resolve() for key in ("executable", "source", "mpv", "shared"))
    output.mkdir(parents=True, exist_ok=True)
    scope = ("Programmatic native window/button dispatch and recorded teardown; no physical input, HDR, compositor, sleep or VoiceOver proof"
             if args.scenario == "floating-video" else "Actual DOM/media teardown; no physical sleep or VoiceOver qualification")
    report: dict = {"passed": False, "scenario": args.scenario, "source": str(source), "scope": scope, "checks": []}
    paths = {"HDRPlayer": executable, "libmpv": mpv, "FrameEngineShared": shared}
    report["binaries"] = {name: {"path": str(path), "beforeSHA256": sha256(path)} for name, path in paths.items()}
    env = dict(os.environ)
    env.update(METAL_DLSS_MPV_LIBRARY=str(mpv), HDRPLAYER_UI_SMOKE_KIND="lifecycle",
               HDRPLAYER_UI_SMOKE_REPORT=str(output / "dom.json"), HDRPLAYER_LIFECYCLE_LOG=str(output / "lifecycle.jsonl"))
    env.pop("HDRPLAYER_UI_SMOKE_KEEP_PREFERENCES", None)
    env.pop("HDRPLAYER_FLOATING_VIDEO", None)
    env.pop("HDRPLAYER_ENABLE_PIP", None)
    env.pop("HDRPLAYER_PIP_REPORT", None)
    if args.scenario.startswith("pip"):
        env.update(HDRPLAYER_ENABLE_PIP="1", HDRPLAYER_UI_SMOKE_KIND=args.scenario,
                   HDRPLAYER_PIP_REPORT=str(output / "pip.json"))
    elif args.scenario == "floating-video":
        env.update(HDRPLAYER_FLOATING_VIDEO="1", HDRPLAYER_UI_SMOKE_KIND="floating-video")
    try:
        with (output / "player.log").open("x") as log:
            process = subprocess.run([str(executable), str(source)], cwd=ROOT, env=env,
                                     stdout=log, stderr=subprocess.STDOUT, timeout=120, check=False)
        report["exitCode"] = process.returncode
        assert process.returncode == 0, f"Player exited {process.returncode}"
        dom = json.loads((output / "dom.json").read_text())
        assert dom.get("passed") is True, dom.get("failure", "DOM smoke failed")
        report["domChecksPassed"] = len(dom["checks"])
        report["checks"].append("Actual native/media smoke passed and the process exited cleanly")
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
        if args.scenario == "floating-video":
            report["floatingTeardown"] = floating_teardown(rows, begin, destroyed, finish)
            report["checks"].append("The floating native host/child/layer survive termination preparation, then detach before final worker-destroyed recording")
        if args.scenario.startswith("pip"):
            pip = json.loads((output / "pip.json").read_text())
            pip_events = [event["event"] for event in pip["events"]]
            assert "did-start" in pip_events and "did-stop" in pip_events
            assert pip_events[-1] == "renderer-flushed-and-leases-released"
            assert pip["state"]["submittedLeases"] == 0 and pip["state"]["pendingFrames"] == 0
            assert pip["state"]["maximumObservedExportLeases"] <= 3
            assert pip["state"]["enqueuedFrames"] >= 8
            assert pip["events"][-1]["hostSeconds"] <= rows[destroyed]["uptimeSeconds"]
            report["checks"].append("Actual PiP lifecycle and renderer flush release consumer leases before core destruction")
            report["pipState"] = pip["state"]
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
        with (output / "report.json").open("x") as handle:
            handle.write(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
