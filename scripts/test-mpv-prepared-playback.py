#!/usr/bin/env python3
"""Exercise sustained source-clock Prepared playback and persistent neural cache reuse."""
import argparse
from bisect import bisect_left
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import socket
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("mpv_policy_helpers", ROOT / "scripts/test-mpv-policy.py")
helpers = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(helpers)
digest, rational, displayed_time = helpers.digest, helpers.rational, helpers.displayed_time


def require(value, message):
    if not value:
        raise RuntimeError(message)


def seconds(value):
    return Fraction(value["value"], value["timescale"])


def finite_number(value):
    return isinstance(value, (int, float)) and math.isfinite(value)


def playback_spans(samples, inventory, segment_frames):
    """Sampled pacing by cached segment and original span; no scanout inference."""
    groups = {}
    for sample in samples:
        state = sample["state"]
        label = "uncached-original"
        if state["displayed-content-kind"] == "prepared-enhanced":
            label = f"prepared-segment-{bisect_left(inventory, displayed_time(state)) // segment_frames}"
        groups.setdefault(label, []).append(sample)
    result = {}
    for label, values in groups.items():
        first, last = values[0], values[-1]
        wall = last["elapsed"] - first["elapsed"]
        media = last["position"] - first["position"]
        offsets = [abs(value["avOffset"]) for value in values if finite_number(value["avOffset"])]
        result[label] = {"samples": len(values), "wallSeconds": wall, "mediaSeconds": media,
            "sourceRateRatio": media / wall if wall else None,
            "maximumAbsoluteAVSeconds": max(offsets) if offsets else None,
            "sampledBufferingSeconds": sum(b["elapsed"] - a["elapsed"] for a, b in zip(values, values[1:])
                if a["state"].get("buffering"))}
    return result


def resident_bytes(pid):
    try:
        return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip()) * 1024
    except (subprocess.CalledProcessError, ValueError):
        return None


def disk_usage(directory):
    files = {}
    for path in directory.rglob("*") if directory.exists() else []:
        try:
            if path.is_file():
                value = path.stat(); files[(value.st_dev, value.st_ino)] = value.st_size
        except FileNotFoundError:
            pass  # Publication atomically moves staging into the completed tree.
    return sum(files.values())


def cache_snapshot(directory, expected, model_hash, capacity, verify_pixels=False):
    usage = disk_usage(directory)
    require(usage <= capacity, "cache logical disk capacity exceeded")
    stage = directory / "staging"
    staged = sum(1 for path in stage.iterdir()) if stage.exists() else 0
    manifests = []
    for path in sorted((directory / "segments").glob("*/manifest.json")):
        manifest = json.loads(path.read_text())
        require(manifest["schemaVersion"] == 2, "Prepared provider did not publish exact timing inventory format")
        require(manifest["identity"]["settings"]["modelSHA256"] == model_hash, "cache model identity mismatch")
        require("mpv" in manifest["identity"]["source"]["interpretation"]["decoder"].lower(), "cache did not use selected-core provider")
        timings = [frame["timing"] for frame in manifest["frames"]]
        canonical = json.dumps(timings, sort_keys=True, separators=(",", ":")).encode()
        require(hashlib.sha256(canonical).hexdigest() == manifest["identity"]["timingInventorySHA256"], "timing inventory digest mismatch")
        if verify_pixels:
            for frame in manifest["frames"]:
                payload = path.parent / frame["fileName"]
                require(payload.stat().st_size == frame["byteCount"] and digest(payload) == frame["sha256"], "prepared pixel payload changed")
        manifests.append({"key": manifest["key"], "range": manifest["identity"]["range"],
            "frameCount": len(timings), "manifestSHA256": digest(path),
            "payloadInventorySHA256": hashlib.sha256(json.dumps([(frame["fileName"], frame["sha256"], frame["byteCount"])
                for frame in manifest["frames"]], separators=(",", ":")).encode()).hexdigest(),
            "pts": [seconds(value["presentationTime"]) for value in timings]})
    manifests.sort(key=lambda value: seconds(value["range"]["start"]))
    pts = [pts for entry in manifests for pts in entry.pop("pts")]
    require(pts == expected, "published source PTS inventory is incomplete or reordered")
    require(staged == 0, "completed preparation left partial staging")
    return {"logicalBytes": usage, "capacityBytes": capacity, "stagedSegments": staged, "segments": manifests,
            "pixelPayloadsVerified": verify_pixels}


class Player:
    def __init__(self, args, source, prepared_config, suffix, provenance, stream):
        self.directory = tempfile.TemporaryDirectory(prefix="prepared-playback-ipc-")
        ipc = Path(self.directory.name) / "ipc"
        self.log = args.report.with_suffix(f".{suffix}.log")
        self.engine_report = args.report.with_suffix(f".{suffix}.engine.json")
        self.sequence, self.closed = 0, False
        config = {"adapter": "mpv-source-core-prepared-playback", "source": provenance["sourceSHA256"],
            "sourceWidth": stream["width"], "sourceHeight": stream["height"],
            "processingWidth": args.width, "processingHeight": args.height, "displayWidth": 960, "displayHeight": 496,
            "sourceFPS": float(Fraction(stream["avg_frame_rate"])), "modelVersion": provenance["modelSHA256"],
            "implementationRevision": json.dumps(provenance["revisions"], sort_keys=True, separators=(",", ":")),
            "warmupFrames": 3, "settingsJSON": json.dumps({"strength": 1, "colourStrength": 1,
                "referenceWhiteNits": 203, "maximumLuminanceRatio": 2, "mode": "prepared", "policy": "adaptive"}),
            "displayConfiguration": "gpu-next/macvk; native960x496 swapchain verified; no physical scanout measurement",
            "powerConfiguration": subprocess.check_output(["pmset", "-g", "batt"], text=True).strip()}
        config_path = args.report.with_suffix(f".{suffix}.configuration.json")
        config_path.write_text(json.dumps(config, indent=2) + "\n")
        options = f"@enhance:metal-hdr=policy=adaptive:processing-width={args.width}:processing-height={args.height}:strength=1:maximum-luminance-ratio=2"
        for key, path in [("prepared-config", prepared_config), ("model", args.model.resolve()),
                          ("measurement-config", config_path.resolve()), ("engine-report", self.engine_report.resolve())]:
            value = str(path)
            options += f":{key}=%{len(value.encode())}%{value}"
        self.process = subprocess.Popen([str(ROOT / "artifacts/mpv-build/mpv"), "--no-config", "--vo=gpu-next",
            "--gpu-api=vulkan", "--gpu-context=macvk", "--target-colorspace-hint=yes", "--hwdec=videotoolbox",
            "--ao=coreaudio", "--mute=yes", "--pause=yes", "--keep-open=yes", "--osc=no", "--geometry=960x496",
            "--keepaspect-window=no", "--input-default-bindings=no", "--input-builtin-bindings=no", "--input-vo-keyboard=no",
            "--input-terminal=no", f"--input-ipc-server={ipc}", f"--vf={options}", f"--log-file={self.log}", str(source)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=ROOT, env=dict(os.environ))
        self.socket = socket.socket(socket.AF_UNIX)
        try:
            deadline = time.monotonic() + 30
            while not ipc.exists():
                require(self.process.poll() is None and time.monotonic() < deadline, "mpv did not open IPC")
                time.sleep(.02)
            self.socket.connect(str(ipc)); self.socket.settimeout(30)
            self.stream = self.socket.makefile("rwb", buffering=0)
        except Exception:
            self.process.terminate(); self.process.wait(timeout=30); self.directory.cleanup(); raise

    def command(self, *values, optional=False):
        self.sequence += 1
        self.stream.write((json.dumps({"command": values, "request_id": self.sequence}) + "\n").encode())
        while line := self.stream.readline():
            response = json.loads(line)
            if response.get("request_id") == self.sequence:
                if response["error"] != "success":
                    if optional:
                        return None
                    raise RuntimeError(str(response))
                return response.get("data")
        raise RuntimeError("mpv closed IPC")

    def state(self):
        state = self.command("get_property", "enhancement-state", optional=True) or {}
        require(not state.get("prepared", {}).get("error"), str(state.get("prepared", {}).get("error")))
        return state

    def wait(self, predicate, timeout=180, observe=None):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = self.state()
            if observe:
                observe(state)
            if predicate(state):
                return state
            time.sleep(.05)
        raise RuntimeError(f"Prepared state timed out: {state}")

    def seek(self, target, kind):
        previous = self.state()["generation"]
        start = time.monotonic()
        self.command("seek", float(target), "absolute+exact")
        result = self.wait(lambda state: state.get("generation", 0) > previous and state.get("compare-ready") and
            displayed_time(state) == target and state.get("displayed-content-kind") == kind, timeout=30)
        require(result["displayed-generation"] == result["generation"], "seek displayed a stale generation")
        return {"requested": rational(target), "secondsToPair": time.monotonic() - start, "state": result}

    def counters(self):
        return {name: self.command("get_property", name, optional=True) for name in
            ["frame-drop-count", "decoder-frame-drop-count", "mistimed-frame-count", "vo-delayed-frame-count"]}

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self.command("quit")
        finally:
            self.socket.close()
            try:
                status = self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(); raise RuntimeError("Prepared shutdown timed out")
            finally:
                self.directory.cleanup()
            require(status == 0, f"Prepared process exited with status{status}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "assets/test-clips/playback/pq-30-60s.mkv")
    parser.add_argument("--model", type=Path, default=ROOT / "models/neural-rendering/NeuralRendering.dlssmodel")
    parser.add_argument("--prepare-seconds", default="6")
    parser.add_argument("--play-seconds", type=float, default=30)
    parser.add_argument("--segment-frames", type=int, default=60)
    parser.add_argument("--preroll-frames", type=int, default=8)
    parser.add_argument("--width", type=int, default=160)
    parser.add_argument("--height", type=int, default=96)
    parser.add_argument("--capacity-mib", type=int, default=512)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    require(10 <= args.play_seconds <= 120 and 1 <= args.segment_frames <= 600 and 0 <= args.preroll_frames <= 600, "invalid bounded run length/segment settings")
    require(1 <= args.width <= 512 and 1 <= args.height <= 288 and 32 <= args.capacity_mib <= 8192, "invalid processing/cache limits")
    source = args.source.resolve(); args.report = args.report.resolve()
    source_hash, model_hash = digest(source), digest(args.model / "weights.safetensors")
    inventory, inventory_provenance = helpers.source_inventory(source, source_hash)
    end_index = bisect_left(inventory, Fraction(args.prepare_seconds))
    require(2 * args.segment_frames <= end_index < len(inventory) and float(inventory[end_index]) < args.play_seconds - 5,
            "prepare at least two segments and leave at least five seconds of uncached playback")
    require(float(inventory[-1]) > args.play_seconds + 5, "source is too short for controlled playback")
    expected = inventory[:end_index]; start, end = inventory[0], inventory[end_index]
    frame_set = set(inventory)
    binaries = [ROOT / "artifacts/mpv-build/mpv", ROOT / "artifacts/mpv-build/libmpv.2.dylib",
                ROOT / ".build/debug/libFrameEngineShared.dylib", ROOT / ".build/debug/mlx.metallib"]
    provenance = {"recordedUTC": datetime.now(timezone.utc).isoformat(), "sourceSHA256": source_hash,
        "modelSHA256": model_hash, "scriptSHA256": digest(Path(__file__)), "inventory": inventory_provenance,
        "revisions": {"root": helpers.revision(ROOT), "mpv": helpers.revision(ROOT / "vendor/mpv"),
                      "MLX-DLSS": helpers.revision(ROOT / "vendor/MLX-DLSS")},
        "binaries": {str(path.relative_to(ROOT)): {"sha256": digest(path), "bytes": path.stat().st_size} for path in binaries}}
    source_stream = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,avg_frame_rate", "-of", "json", str(source)]))["streams"][0]
    args.report.parent.mkdir(parents=True, exist_ok=True)
    require(not args.report.exists(), "use a new report path; existing evidence will not be overwritten")
    report = {"schemaVersion": 1, "provenance": provenance, "source": source.name, "errors": [], "functionalPassed": False,
        "scope": "Source-clock native Prepared playback; raw mpv avsync is audio-minus-video, cached at queue updates; no physical scanout claim",
        "prepareRange": {"start": rational(start), "end": rational(end)}, "expectedPreparedFrames": len(expected),
        "processingWidth": args.width, "processingHeight": args.height, "samples": [], "preparationSamples": [], "boundarySeeks": []}
    with tempfile.TemporaryDirectory(prefix="mpv-prepared-sustained-") as temporary:
        cache = Path(temporary) / "cache"; capacity = args.capacity_mib * 1_048_576
        prepared_config = Path(temporary) / "prepared.json"
        prepared_config.write_text(json.dumps({"sourcePath": str(source), "cacheDirectory": str(cache), "capacityBytes": capacity,
            "rangeStart": rational(start), "rangeEnd": rational(end), "segmentFrames": args.segment_frames, "prerollFrames": args.preroll_frames}))
        player = None
        try:
            player = Player(args, source, prepared_config, "first", provenance, source_stream)
            initial = player.wait(lambda state: state.get("compare-ready") and state.get("prepared", {}).get("configurationState") == "ready")
            report["initial"] = initial
            drawable = player.command("get_property", "osd-dimensions", optional=True) or {}
            allocations = re.findall(r"\(Re\)creating swapchain of size (\d+)x(\d+)", player.log.read_text())
            if not drawable.get("w") and allocations:
                drawable = dict(zip(("w", "h"), map(int, allocations[-1])))
            require((drawable.get("w"), drawable.get("h")) == (960, 496), "actual drawable differs from960x496 configuration")
            require((initial.get("processing-width"), initial.get("processing-height")) == (args.width, args.height), "processing dimensions differ from requested workload")
            report["drawable"] = drawable
            began = time.monotonic(); last_resource = 0
            def observe(state):
                nonlocal last_resource
                now = time.monotonic()
                if now - last_resource >= .5:
                    usage = disk_usage(cache)
                    require(usage <= capacity, "sampled preparation cache capacity exceeded")
                    report["preparationSamples"].append({"elapsed": now - began, "residentBytes": resident_bytes(player.process.pid),
                        "cacheLogicalBytes": usage, "prepared": state.get("prepared"), "pendingFrames": state.get("pending-frames")})
                    last_resource = now
            player.command("vf-command", "enhance", "prepare", "start")
            complete = player.wait(lambda state: state.get("prepared", {}).get("jobState") == "complete", observe=observe)
            report["preparationSeconds"] = time.monotonic() - began; report["complete"] = complete
            require(complete["prepared"]["processedFrames"] == len(expected), "first preparation did not process the full exact inventory")
            report["cacheBeforePlayback"] = cache_snapshot(cache, expected, model_hash, capacity, verify_pixels=True)
            boundaries = list(range(args.segment_frames, end_index, args.segment_frames)) + [end_index]
            for boundary in boundaries:
                for index in [boundary - 1, boundary, boundary + 1]:
                    target = inventory[index]; kind = "prepared-enhanced" if target < end else "original"
                    report["boundarySeeks"].append(player.seek(target, kind))
            ready = player.seek(start, "prepared-enhanced")["state"]
            report["playbackStart"] = ready; report["initialCounters"] = player.counters()
            player.command("set_property", "pause", False)
            began = time.monotonic(); last_resource = 0
            while time.monotonic() - began < args.play_seconds:
                state = player.state(); pts = displayed_time(state)
                require(state["generation"] == ready["generation"] and state.get("displayed-generation") == state["generation"], "stale/unexpected generation during controlled playback")
                require(pts in frame_set, "displayed PTS is not an exact source frame")
                kind = "prepared-enhanced" if start <= pts < end else "original"
                require(state.get("displayed-content-kind") == kind, f"wrong displayed provenance at{pts}: expected{kind}")
                require(state.get("pending-frames", 0) <= 3, "unbounded playback admission")
                sample = {"elapsed": time.monotonic() - began, "state": state,
                    "avOffset": player.command("get_property", "avsync", optional=True),
                    "position": player.command("get_property", "time-pos", optional=True)}
                require(finite_number(sample["position"]), "media clock position unavailable or nonfinite")
                if sample["elapsed"] - last_resource >= .5:
                    sample["residentBytes"] = resident_bytes(player.process.pid); last_resource = sample["elapsed"]
                report["samples"].append(sample)
                require(not player.command("get_property", "eof-reached", optional=True), "source ended during controlled playback")
                time.sleep(.025)
            player.command("set_property", "pause", True)
            report["final"] = player.state(); report["finalCounters"] = player.counters()
            report["cacheAfterPlayback"] = cache_snapshot(cache, expected, model_hash, capacity)
            player.close(); first_engine = json.loads(player.engine_report.read_text()); player = None
            report["firstEngine"] = {key: value for key, value in first_engine.items() if key != "frames"}
            last_displayed = displayed_time(report["final"])
            completed_pts = [Fraction(frame["ptsValue"], frame["ptsTimescale"]) for frame in first_engine["frames"]
                if frame["generation"] == ready["generation"] and Fraction(frame["ptsValue"], frame["ptsTimescale"]) <= last_displayed]
            expected_pts = [pts for pts in inventory if start <= pts <= last_displayed]
            require(completed_pts == expected_pts, "shared output skipped or duplicated an exact source PTS before the last displayed frame")
            report["completedInventoryThroughLastDisplayed"] = {"frames": len(completed_pts), "exact": True,
                "lastPTS": rational(last_displayed), "scope": "completed shared outputs; physical scanout unavailable"}
            report["counterDeltas"] = {key: report["finalCounters"][key] - value
                for key, value in report["initialCounters"].items()
                if finite_number(value) and finite_number(report["finalCounters"][key])}
            require(all(report["counterDeltas"].get(key) == 0 for key in ["frame-drop-count", "decoder-frame-drop-count"]),
                "decoder or VO reported frame drops during controlled playback")
            require(first_engine["maximumQueueSlots"] <= 3 and first_engine["peakRetainedBytes"] <= 512 * 1_048_576, "shared frame limits exceeded")
            payload_peak = first_engine["maximumAllocatorBytes"].get("resident_model_payload")
            require(payload_peak is not None and 0 < payload_peak <= 1024 * 1_048_576, "preparation model payload accounting unavailable or over policy")
            report["sampledResidentModelPayloadBytes"] = payload_peak
            player = Player(args, source, prepared_config, "restart", provenance, source_stream)
            player.wait(lambda state: state.get("compare-ready") and state.get("prepared", {}).get("configurationState") == "ready")
            player.command("vf-command", "enhance", "prepare", "start")
            reused = player.wait(lambda state: state.get("prepared", {}).get("jobState") == "complete")
            require(reused["prepared"]["processedFrames"] == 0 and reused["prepared"]["reusedSegments"] == len(boundaries), "restart failed exact completed-segment reuse")
            report["restart"] = {"complete": reused, "hit": player.seek(inventory[args.segment_frames], "prepared-enhanced"),
                "miss": player.seek(inventory[end_index + 1], "original")}
            report["cacheAfterRestart"] = cache_snapshot(cache, expected, model_hash, capacity, verify_pixels=True)
            require(report["cacheAfterRestart"]["segments"] == report["cacheBeforePlayback"]["segments"], "restart changed committed pixels/identity")
            player.close(); player = None
            steady = [sample for sample in report["samples"] if sample["elapsed"] >= 2]
            offsets = [sample["avOffset"] for sample in steady if finite_number(sample["avOffset"])]
            require(offsets, "audio-clock offset samples unavailable")
            absolute = sorted(map(abs, offsets)); quarter = max(1, len(offsets) // 4)
            report["steadyAV"] = {"samples": len(offsets), "maximumAbsoluteSeconds": max(absolute),
                "p95AbsoluteSeconds": absolute[int((len(absolute) - 1) * .95)], "medianSeconds": statistics.median(offsets),
                "firstQuarterMedianSeconds": statistics.median(offsets[:quarter]), "lastQuarterMedianSeconds": statistics.median(offsets[-quarter:]),
                "medianDriftSeconds": statistics.median(offsets[-quarter:]) - statistics.median(offsets[:quarter])}
            report["synchronisation20msTargetMet"] = max(absolute) <= .020
            first, last = report["samples"][0], report["samples"][-1]
            wall_advance, media_advance = last["elapsed"] - first["elapsed"], last["position"] - first["position"]
            ratio = media_advance / wall_advance
            report["sourceRate"] = {"mediaSeconds": media_advance, "wallSeconds": wall_advance, "ratio": ratio,
                "minimumRatio": .97, "maximumRatio": 1.03}
            report["sourceRateTargetMet"] = .97 <= ratio <= 1.03
            report["playbackSpans"] = playback_spans(report["samples"], inventory, args.segment_frames)
            report["observedContentKinds"] = sorted({sample["state"]["displayed-content-kind"] for sample in report["samples"]})
            require(report["observedContentKinds"] == ["original", "prepared-enhanced"], "continuous playback did not cross cached/original boundary")
            require(last["position"] > float(end) + 5, "insufficient uncached playback after the boundary")
            report["functionalPassed"] = True
        except Exception as error:
            report["errors"].append(str(error))
        finally:
            if player:
                try: player.close()
                except Exception as error: report["errors"].append(str(error)); report["functionalPassed"] = False
            report["binaryHashesUnchanged"] = all(digest(ROOT / path) == value["sha256"] for path, value in provenance["binaries"].items())
            report["sourceHashUnchanged"] = digest(source) == source_hash
            if not report["binaryHashesUnchanged"] or not report["sourceHashUnchanged"]:
                report["functionalPassed"] = False; report["errors"].append("measured source/binary changed during run")
            report["acceptanceTargetsMet"] = report["functionalPassed"] and report.get("sourceRateTargetMet", False) and report.get("synchronisation20msTargetMet", False)
            args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report.get(key) for key in ["functionalPassed", "acceptanceTargetsMet", "errors", "preparationSeconds",
        "steadyAV", "sourceRate", "observedContentKinds", "binaryHashesUnchanged"]}, indent=2))
    return 0 if report["functionalPassed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
