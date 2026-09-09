#!/usr/bin/env python3
"""Exercise native mpv policy through libmpv's JSON IPC command surface."""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--seconds", type=float, default=12)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {"source": str(args.source.resolve()), "model": str(args.model),
              "conditions": "M3 native gpu-next/macvk, source-rate audio clock, muted CoreAudio; Adaptive explicitly buffers both clocks; lifecycle excluded from steady samples",
              "samples": [], "errors": []}
    with tempfile.TemporaryDirectory(prefix="mpv-policy-") as directory:
        ipc = Path(directory) / "ipc"
        options = "@enhance:metal-hdr=policy=adaptive:processing-width=32:processing-height=24:strength=1:maximum-luminance-ratio=2"
        if args.model:
            model = str(args.model.resolve())
            options += f":model=%{len(model.encode())}%{model}"
        source_stream = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,avg_frame_rate", "-of", "json", str(args.source)]))["streams"][0]
        def digest(path):
            hasher = hashlib.sha256()
            with path.open("rb") as source:
                while block := source.read(1024 * 1024): hasher.update(block)
            return hasher.hexdigest()
        model_id = digest(args.model / "weights.safetensors") if args.model else "original"
        config = {"adapter": "mpv-metal-hdr-policy", "source": digest(args.source),
            "sourceWidth": source_stream["width"], "sourceHeight": source_stream["height"],
            "processingWidth": 32, "processingHeight": 24, "displayWidth": 960, "displayHeight": 496,
            "sourceFPS": float(Fraction(source_stream["avg_frame_rate"])), "modelVersion": model_id,
            "implementationRevision": "mpv-hdr-policy-working-tree", "warmupFrames": 3,
            "settingsJSON": json.dumps({"strength": 1, "colourStrength": 1, "referenceWhiteNits": 203,
                                       "maximumLuminanceRatio": 2, "policy": "adaptive"}),
            "displayConfiguration": "gpu-next/macvk; requested drawable960x496 verified against osd-dimensions; physical calibration and brightness unreported",
            "powerConfiguration": subprocess.check_output(["pmset", "-g", "batt"], text=True).strip()}
        config_path = args.report.with_suffix(".configuration.json").resolve()
        config_path.write_text(json.dumps(config, indent=2) + "\n")
        engine_report = args.report.with_suffix(".engine.json").resolve()
        for key, path in (("measurement-config", config_path), ("engine-report", engine_report)):
            value = str(path)
            options += f":{key}=%{len(value.encode())}%{value}"
        cmd = [str(root / "artifacts/mpv-build/mpv"), "--no-config", "--vo=gpu-next",
               "--gpu-api=vulkan", "--gpu-context=macvk", "--target-colorspace-hint=yes",
               "--hwdec=videotoolbox", "--ao=coreaudio", "--mute=yes", "--pause=yes",
               "--keep-open=yes", "--osc=no", "--geometry=960x496", "--keepaspect-window=no",
               "--input-default-bindings=no", "--input-builtin-bindings=no", "--input-vo-keyboard=no",
               "--input-terminal=no",
               f"--input-ipc-server={ipc}", f"--vf={options}",
               f"--log-file={args.report.with_suffix('.log')}", str(args.source.resolve())]
        process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   cwd=root, env=dict(os.environ))
        client = socket.socket(socket.AF_UNIX)
        try:
            deadline = time.monotonic() + 30
            while not ipc.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("mpv did not open IPC")
                time.sleep(.02)
            client.connect(str(ipc))
            client.settimeout(30)
            stream = client.makefile("rwb", buffering=0)
            sequence = 0

            def command(*values, allow_error=False):
                nonlocal sequence
                sequence += 1
                stream.write((json.dumps({"command": values, "request_id": sequence}) + "\n").encode())
                while True:
                    line = stream.readline()
                    if not line:
                        raise RuntimeError("mpv closed IPC")
                    event = json.loads(line)
                    if event.get("request_id") == sequence:
                        if event.get("error") != "success" and not allow_error:
                            raise RuntimeError(f"{values}: {event}")
                        return event

            def state():
                return command("get_property", "enhancement-state").get("data", {})

            def await_pair(generation=-1):
                deadline = time.monotonic() + 30
                seen = []
                while time.monotonic() < deadline:
                    current = state()
                    seen.append({"host": time.monotonic(), **current})
                    if current.get("compare-ready") and current.get("generation", -1) > generation:
                        return current, seen
                    time.sleep(.02)
                raise RuntimeError(f"same-frame pair not ready: {current}")

            initial, report["initialLifecycle"] = await_pair()
            report["initial"] = initial
            drawable_deadline = time.monotonic() + 2
            while True:
                report["drawable"] = command("get_property", "osd-dimensions").get("data")
                if report["drawable"].get("w") or time.monotonic() >= drawable_deadline:
                    break
                time.sleep(.02)
            if (report["drawable"].get("w"), report["drawable"].get("h")) != (960, 496):
                raise RuntimeError("actual drawable does not match measurement configuration")
            report["liveRejection"] = command("vf-command", "enhance", "policy", "live", allow_error=True)
            if report["liveRejection"].get("error") == "success":
                raise RuntimeError("tiny/cold configuration incorrectly qualified Live")
            # Queue three accurate seeks together. mpv coalesces their target;
            # old generation work may finish but must never replace this target.
            before = initial["generation"]
            seek_start = time.monotonic()
            for target in (.2, 1.2, .7):
                sequence += 1
                stream.write((json.dumps({"command": ["seek", target, "absolute+exact"],
                                          "request_id": sequence}) + "\n").encode())
            final, report["seekLifecycle"] = await_pair(before)
            report["seekSecondsToEnhancedPair"] = time.monotonic() - seek_start
            pts = final["displayed-source-pts"] * final["displayed-timebase-num"] / final["displayed-timebase-den"]
            if not .695 <= pts <= .74:
                raise RuntimeError(f"wrong final seek timestamp: {pts}")
            pair_identity = [final.get(key) for key in ("displayed-source-pts", "displayed-timebase-num", "displayed-timebase-den", "displayed-generation")]
            previews = [s for s in report["seekLifecycle"] if s.get("comparison") == "original" and
                        s.get("displayed-generation") == final["displayed-generation"] and
                        s.get("displayed-source-pts") == final["displayed-source-pts"]]
            report["seekSecondsToOriginalPreview"] = previews[0]["host"] - seek_start if previews else None
            submitted = final["submitted-frames"]
            report["comparison"] = []
            for variant in ("original", "enhanced") * 3:
                command("vf-command", "enhance", "compare", variant)
                current = state()
                identity = [current.get(key) for key in ("displayed-source-pts", "displayed-timebase-num", "displayed-timebase-den", "displayed-generation")]
                if identity != pair_identity or current["submitted-frames"] != submitted:
                    raise RuntimeError("comparison changed timestamp/generation or resubmitted inference")
                if current["comparison"] != variant:
                    raise RuntimeError("comparison did not switch the retained variant")
                report["comparison"].append({"variant": variant, "state": current,
                    "transfer": command("get_property", "video-out-params/gamma", allow_error=True).get("data")})
            command("set_property", "pause", False)
            started = time.monotonic()
            while time.monotonic() - started < args.seconds:
                current = state()
                offset = command("get_property", "avsync", allow_error=True).get("data")
                position = command("get_property", "time-pos", allow_error=True).get("data")
                report["samples"].append({"elapsed": time.monotonic() - started,
                    "avOffset": offset, "position": position, "state": current})
                if current.get("generation") != final["generation"]:
                    raise RuntimeError("unexpected seek or discontinuity during controlled playback")
                if command("get_property", "eof-reached", allow_error=True).get("data"):
                    break
                time.sleep(.025)
            steady = [s["avOffset"] for s in report["samples"]
                      if s["elapsed"] >= 2 and isinstance(s["avOffset"], (int, float))]
            report["steadyMaximumAbsoluteAVOffsetSeconds"] = max(map(abs, steady), default=None)
            absolute = sorted(map(abs, steady))
            report["steadyP95AbsoluteAVOffsetSeconds"] = absolute[int((len(absolute) - 1) * .95)] if absolute else None
            report["steadyMedianAVOffsetSeconds"] = statistics.median(steady) if steady else None
            report["synchronisation20msTargetMet"] = max(absolute) <= .020 if absolute else None
            report["maximumPendingFrames"] = max((s["state"]["pending-frames"] for s in report["samples"]), default=0)
            if report["maximumPendingFrames"] > 3:
                raise RuntimeError("unbounded enhancement admission")
            report["final"] = state()
            report["passed"] = True
            command("quit")
        except Exception as error:
            report["errors"].append(str(error))
            report["passed"] = False
            process.terminate()
        finally:
            client.close()
            try:
                report["exitCode"] = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                report["exitCode"] = process.wait()
                report["errors"].append("shutdown timed out")
                report["passed"] = False
            args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items()
                      if key not in ("samples", "initialLifecycle", "seekLifecycle", "comparison")}, indent=2))
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
