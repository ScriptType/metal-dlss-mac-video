#!/usr/bin/env python3
"""Start bounded PiP inspection; use the AX helper externally, then create OUTPUT/finish.

Default discovery is read-only. This launcher does not press a system control or
invoke an AVKit delegate. Run only in an available GPU/UI test window.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=ROOT / "assets/test-clips/playback/pq-30-60s.mkv")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        raise RuntimeError("Use a new output directory to preserve prior captures")
    output.mkdir(parents=True)
    paths = {name: path.resolve() for name, path in {
        "HDRPlayer": ROOT / ".build/debug/HDRPlayer", "libmpv": ROOT / "artifacts/mpv-build/libmpv.2.dylib",
        "FrameEngineShared": ROOT / ".build/debug/libFrameEngineShared.dylib",
        "AXHelper": ROOT / "artifacts/pip-accessibility/SystemPiPAccessibility"}.items()}
    report = {"setupAndTeardownPassed": False, "controlEffectsQualified": False,
        "scope": "Actual PiP owner inspection session; action and delegate evidence must be evaluated separately",
        "sourceSHA256": digest(args.source.resolve()),
        "binaries": {name: {"path": str(path), "beforeSHA256": digest(path)} for name, path in paths.items()}}
    env = dict(os.environ, HDRPLAYER_ENABLE_PIP="1", HDRPLAYER_UI_SMOKE_KIND="pip-system",
        HDRPLAYER_UI_SMOKE_REPORT=str(output / "dom.json"), HDRPLAYER_PIP_REPORT=str(output / "pip.json"),
        HDRPLAYER_LIFECYCLE_LOG=str(output / "lifecycle.jsonl"), HDRPLAYER_SYSTEM_PIP_DIRECTORY=str(output),
        METAL_DLSS_MPV_LIBRARY=str(paths["libmpv"]))
    env.pop("HDRPLAYER_UI_SMOKE_KEEP_PREFERENCES", None)
    process = None
    try:
        with (output / "player.log").open("w") as log:
            process = subprocess.Popen([str(paths["HDRPlayer"]), str(args.source.resolve())], cwd=ROOT,
                env=env, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 50
            while not (output / "live.json").exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Player did not reach active PiP inspection state")
                time.sleep(.1)
            report["playerPID"] = process.pid
            initial = json.loads((output / "live.json").read_text())
            report["initialState"] = initial
            result = subprocess.run([str(paths["AXHelper"]), "--output", str(output / "discovery.json")],
                capture_output=True, text=True, timeout=15)
            report["discoveryExitCode"] = result.returncode
            report["discovery"] = json.loads(result.stdout)
            print(f"READY {output}", flush=True)
            samples = []
            deadline = time.monotonic() + 135
            while process.poll() is None and time.monotonic() < deadline:
                live = json.loads((output / "live.json").read_text())
                state = live["state"]; pip = state.get("pip", {}); native = state.get("nativeEnhancement", {})
                samples.append({"hostSeconds": live["hostSeconds"], "position": state.get("position"),
                    "paused": state.get("paused"), "active": pip.get("active"), "available": pip.get("available"),
                    "sourceWindow": live.get("sourceWindow"),
                    "sourcePTS": pip.get("sourcePTS"), "generation": pip.get("generation"), "revision": pip.get("revision"),
                    "clockRate": pip.get("clockRate"), "submittedFrames": native.get("submitted-frames")})
                time.sleep(.2)
            report["stateSamples"] = samples
            if process.poll() is None:
                (output / "finish").touch()
            report["exitCode"] = process.wait(timeout=20)
            dom = json.loads((output / "dom.json").read_text())
            report["setupAndTeardownPassed"] = report["exitCode"] == 0 and dom["passed"]
            if not report["setupAndTeardownPassed"]:
                report["failure"] = dom.get("failure", "Player process failed")
    except Exception as error:
        report["failure"] = str(error)
    finally:
        if process is not None and process.poll() is None:
            (output / "finish").touch()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
                report["forcedTermination"] = True
        for name, path in paths.items():
            report["binaries"][name]["afterSHA256"] = digest(path)
        report["binariesUnchanged"] = all(value["beforeSHA256"] == value["afterSHA256"] for value in report["binaries"].values())
        if not report["binariesUnchanged"]:
            report["setupAndTeardownPassed"] = False
            report["failure"] = "A measured binary changed during inspection"
        (output / "session.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report.get(key) for key in ("setupAndTeardownPassed", "failure", "binariesUnchanged")}))
    return 0 if report["setupAndTeardownPassed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
