#!/usr/bin/env python3
"""Exercise native mpv policy through libmpv's JSON IPC command surface."""
import argparse
from bisect import bisect_left
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import statistics
import subprocess
import tempfile
import time


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            hasher.update(block)
    return hasher.hexdigest()


def revision(path):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(path), *args])
    status = git("status", "--porcelain=v1").decode().splitlines()
    untracked = git("ls-files", "--others", "--exclude-standard", "-z").decode().split("\0")
    return {"commit": git("rev-parse", "HEAD").decode().strip(), "dirty": bool(status),
            "status": status, "trackedDiffSHA256": hashlib.sha256(git("diff", "HEAD", "--binary")).hexdigest(),
            "untrackedSHA256": {name: digest(path / name) for name in untracked if name and (path / name).is_file()}}


def source_inventory(source, source_hash):
    manifest_path = source.with_suffix(".json")
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
        if manifest.get("sha256") == source_hash and manifest.get("videoPTS"):
            scale = Fraction(manifest["videoTimebase"])
            return sorted(Fraction(value) * scale for value in manifest["videoPTS"]), {
                "source": "verified fixture manifest", "manifestSHA256": digest(manifest_path),
                "profile": manifest.get("profile"), "vfr": manifest.get("vfr"),
                "nominalRate": manifest.get("nominalRate")}
    probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_frames", "-show_streams", "-show_entries", "frame=pts:stream=time_base", "-of", "json", str(source)]))
    scale = Fraction(probe["streams"][0]["time_base"])
    return sorted(Fraction(frame["pts"]) * scale for frame in probe["frames"] if "pts" in frame), {
        "source": "ffprobe exact decoded-frame PTS", "ffprobeVersion": subprocess.check_output(["ffprobe", "-version"], text=True).splitlines()[0]}


def displayed_time(state):
    if "displayed-source-pts" not in state:
        return None
    return Fraction(state["displayed-source-pts"] * state["displayed-timebase-num"], state["displayed-timebase-den"])


def rational(value):
    return {"value": value.numerator, "timescale": value.denominator}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--seconds", type=float, default=12)
    parser.add_argument("--width", type=int, default=32)
    parser.add_argument("--height", type=int, default=24)
    parser.add_argument("--seek-target", default="0.73", help="Decimal final target; expected frame comes from exact source timestamps")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if not (1 <= args.width <= 16384 and 1 <= args.height <= 16384):
        parser.error("processing dimensions must be within 1…16384")
    root = Path(__file__).resolve().parents[1]
    source_path = args.source.resolve()
    source_hash = digest(source_path)
    inventory, inventory_provenance = source_inventory(source_path, source_hash)
    seek_target = Fraction(args.seek_target)
    expected_index = bisect_left(inventory, seek_target - Fraction(5, 1000))
    if expected_index >= len(inventory):
        parser.error("seek target is outside the decoded source inventory")
    expected_pts = inventory[expected_index]
    binaries = [root / "artifacts/mpv-build/mpv", root / "artifacts/mpv-build/libmpv.2.dylib",
                root / ".build/debug/libFrameEngineShared.dylib", root / ".build/debug/mlx.metallib"]
    provenance = {"root": revision(root), "mpv": revision(root / "vendor/mpv"),
        "MLX-DLSS": revision(root / "vendor/MLX-DLSS"),
        "binaries": {str(path.relative_to(root)): {"sha256": digest(path), "bytes": path.stat().st_size,
            "modifiedNanoseconds": path.stat().st_mtime_ns} for path in binaries if path.is_file()},
        "scriptSHA256": digest(Path(__file__)),
        "recordedUTC": datetime.now(timezone.utc).isoformat()}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {"source": str(args.source.resolve()), "model": str(args.model),
              "reportSchemaVersion": 2,
              "avOffsetDefinition": "raw mpv avsync: audioPTS - videoPTS + audioDelay + audioOffset; cached at video queue updates, opposite the shared engine video-minus-audio sign",
              "conditions": "M3 native gpu-next/macvk, source-rate audio clock, muted CoreAudio; Adaptive explicitly buffers both clocks; lifecycle excluded from steady samples",
              "samples": [], "errors": []}
    report.update({"provenance": provenance, "sourceSHA256": source_hash, "inventoryProvenance": inventory_provenance,
        "seekTarget": rational(seek_target), "expectedSeekPTS": rational(expected_pts),
        "seekSelection": "first exact source PTS >= target -5ms, matching mpv accurate-seek tolerance",
        "requestedPlaybackWallSeconds": args.seconds})
    with tempfile.TemporaryDirectory(prefix="mpv-policy-") as directory:
        ipc = Path(directory) / "ipc"
        options = f"@enhance:metal-hdr=policy=adaptive:processing-width={args.width}:processing-height={args.height}:strength=1:maximum-luminance-ratio=2"
        if args.model:
            model = str(args.model.resolve())
            options += f":model=%{len(model.encode())}%{model}"
        source_stream = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,avg_frame_rate", "-of", "json", str(args.source)]))["streams"][0]
        model_id = digest(args.model / "weights.safetensors") if args.model else "original"
        config = {"adapter": "mpv-metal-hdr-policy", "source": source_hash,
            "sourceWidth": source_stream["width"], "sourceHeight": source_stream["height"],
            "processingWidth": args.width, "processingHeight": args.height, "displayWidth": 960, "displayHeight": 496,
            "sourceFPS": float(Fraction(source_stream["avg_frame_rate"])), "modelVersion": model_id,
            "implementationRevision": json.dumps(provenance, sort_keys=True, separators=(",", ":")), "warmupFrames": 3,
            "settingsJSON": json.dumps({"strength": 1, "colourStrength": 1, "referenceWhiteNits": 203,
                                       "maximumLuminanceRatio": 2, "policy": "adaptive"}),
            "displayConfiguration": "gpu-next/macvk; requested drawable960x496 verified against OSD dimensions or native Vulkan swapchain log; physical calibration and brightness unreported",
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
        with args.report.with_suffix('.native.log').open('w') as native_log:
            process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=native_log,
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

            def counters():
                return {name: command("get_property", name, allow_error=True).get("data")
                        for name in ("frame-drop-count", "decoder-frame-drop-count", "vo-delayed-frame-count")}

            def await_pair(generation=-1, expected=None):
                deadline = time.monotonic() + 30
                seen = []
                while time.monotonic() < deadline:
                    current = state()
                    seen.append({"host": time.monotonic(), **current})
                    if current.get("compare-ready") and current.get("generation", -1) > generation and \
                            (expected is None or displayed_time(current) == expected):
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
            report["drawableEvidence"] = "osd-dimensions"
            if not report["drawable"].get("w"):
                # OSD resolution may remain unavailable while paused. The
                # native swapchain allocation records actual drawable pixels,
                # independently of whether an OSD object has been rendered.
                allocations = re.findall(r"\(Re\)creating swapchain of size (\d+)x(\d+)",
                    args.report.with_suffix(".log").read_text())
                if allocations:
                    report["osdDimensions"] = report["drawable"]
                    report["drawable"] = dict(zip(("w", "h"), map(int, allocations[-1])))
                    report["drawableEvidence"] = "native Vulkan swapchain allocation in mpv log"
            if (report["drawable"].get("w"), report["drawable"].get("h")) != (960, 496):
                raise RuntimeError("actual drawable does not match measurement configuration")
            report["liveRejection"] = command("vf-command", "enhance", "policy", "live", allow_error=True)
            if report["liveRejection"].get("error") == "success":
                raise RuntimeError("tiny/cold configuration incorrectly qualified Live")
            # Queue three accurate seeks together. mpv coalesces their target;
            # old generation work may finish but must never replace this target.
            before = initial["generation"]
            seek_start = time.monotonic()
            for target in (.2, 1.2, float(seek_target)):
                sequence += 1
                stream.write((json.dumps({"command": ["seek", target, "absolute+exact"],
                                          "request_id": sequence}) + "\n").encode())
            final, report["seekLifecycle"] = await_pair(before, expected_pts)
            report["seekSecondsToEnhancedPair"] = time.monotonic() - seek_start
            if displayed_time(final) != expected_pts:
                raise RuntimeError("final seek differs from exact source inventory")
            pair_identity = [final.get(key) for key in ("displayed-source-pts", "displayed-timebase-num", "displayed-timebase-den", "displayed-generation")]
            previews = [s for s in report["seekLifecycle"] if s.get("comparison") == "original" and
                        s.get("displayed-generation") == final["displayed-generation"] and
                        s.get("displayed-source-pts") == final["displayed-source-pts"]]
            report["seekSecondsToOriginalPreview"] = previews[0]["host"] - seek_start if previews else None
            report["exactOriginalPreviewObserved"] = bool(previews)
            if args.model and not previews:
                raise RuntimeError("no exact source original preview observed before enhancement")
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
            report["playbackInitialCounters"] = counters()
            command("set_property", "pause", False)
            started = time.monotonic()
            report["playbackStartedHostSeconds"] = started
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
            report["playbackEndedHostSeconds"] = time.monotonic()
            steady = [s["avOffset"] for s in report["samples"]
                      if s["elapsed"] >= 2 and isinstance(s["avOffset"], (int, float))]
            report["steadyMaximumAbsoluteAVOffsetSeconds"] = max(map(abs, steady), default=None)
            absolute = sorted(map(abs, steady))
            report["steadyP95AbsoluteAVOffsetSeconds"] = absolute[int((len(absolute) - 1) * .95)] if absolute else None
            report["steadyMedianAVOffsetSeconds"] = statistics.median(steady) if steady else None
            if steady:
                window = max(1, len(steady) // 4)
                report["steadyFirstQuarterMedianAVOffsetSeconds"] = statistics.median(steady[:window])
                report["steadyLastQuarterMedianAVOffsetSeconds"] = statistics.median(steady[-window:])
                report["steadyMedianAVDriftSeconds"] = statistics.median(steady[-window:]) - statistics.median(steady[:window])
            report["steadySampleCount"] = len(steady)
            report["synchronisation20msTargetMet"] = max(absolute) <= .020 if absolute else None
            report["maximumPendingFrames"] = max((s["state"]["pending-frames"] for s in report["samples"]), default=0)
            if report["maximumPendingFrames"] > 3:
                raise RuntimeError("unbounded enhancement admission")
            report["final"] = state()
            report["playbackFinalCounters"] = counters()
            report["playbackCounterDeltas"] = {key: value - report["playbackInitialCounters"][key]
                for key, value in report["playbackFinalCounters"].items()
                if isinstance(value, (float, int)) and isinstance(report["playbackInitialCounters"].get(key), (float, int))}
            report["adaptiveBufferEpisodes"] = report["final"]["buffer-count"] - final["buffer-count"]
            report["adaptiveBufferedSeconds"] = report["final"]["buffer-seconds"] - final["buffer-seconds"]
            observed = [sample["state"] for sample in report["samples"]]
            report["staleGenerationObservations"] = sum(s.get("displayed-generation", s.get("generation")) != s.get("generation") for s in observed)
            report["displayedContentKinds"] = sorted({s.get("displayed-content-kind", "unavailable") for s in observed})
            report["liveDeadlineFallback"] = "unexercised: Live request rejected before warmed qualification; Adaptive deadline buffering measured directly"
            if report["staleGenerationObservations"]:
                raise RuntimeError("stale generation observed during controlled playback")
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
            if report["exitCode"] != 0:
                report["passed"] = False
                report["errors"].append(f"mpv exited with status {report['exitCode']}")
            report["binaryHashesUnchanged"] = all(
                digest(root / name) == recorded["sha256"]
                for name, recorded in provenance["binaries"].items())
            if not report["binaryHashesUnchanged"]:
                report["passed"] = False
                report["errors"].append("a measured binary changed during the run")
            args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items()
                      if key not in ("samples", "initialLifecycle", "seekLifecycle", "comparison", "provenance")}, indent=2))
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
