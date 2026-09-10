#!/usr/bin/env python3
"""Exercise native mpv policy through libmpv's JSON IPC command surface."""
import argparse
from bisect import bisect_left
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
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

from adapter_visibility import completed_window, qualify_visibility, window_events

CORE_SOURCES = ("demux/demux_lavf.c", "demux/lavf_timing.h", "player/video.c", "player/command.c",
    "video/filter/vf_metal_hdr.m", "video/filter/metal_hdr_live_policy.h", "audio/out/buffer.c", "audio/out/ao_coreaudio.c",
    "video/out/vo.c", "video/out/mac_common.swift", "video/out/mac/common.swift", "video/out/mac/metal_layer.swift",
    "video/out/vulkan/context_mac.m")


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
                "timebase": rational(scale),
                "profile": manifest.get("profile"), "vfr": manifest.get("vfr"),
                "nominalRate": manifest.get("nominalRate")}
    probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_frames", "-show_streams", "-show_entries", "frame=pts:stream=time_base", "-of", "json", str(source)]))
    scale = Fraction(probe["streams"][0]["time_base"])
    return sorted(Fraction(frame["pts"]) * scale for frame in probe["frames"] if "pts" in frame), {
        "timebase": rational(scale),
        "source": "ffprobe exact decoded-frame PTS", "ffprobeVersion": subprocess.check_output(["ffprobe", "-version"], text=True).splitlines()[0]}


def displayed_time(state):
    if "displayed-source-pts" not in state:
        return None
    return Fraction(state["displayed-source-pts"] * state["displayed-timebase-num"], state["displayed-timebase-den"])


def rational(value):
    return {"value": value.numerator, "timescale": value.denominator}


def seconds(value):
    return Fraction(value["value"], value["timescale"])


def mapping_from_observation(first_file_pts, timebase, native_start, rebased, decoder_pts, player_pts):
    """Validate the same native timeline contract as test-mpv-prepared.py."""
    if timebase <= 0 or type(rebased) is not bool or not all(
            type(value) in (int, float) and math.isfinite(value) for value in (native_start, player_pts)):
        raise ValueError("Missing finite native start/rebase/player observation")
    offset_ticks = (-native_start if rebased else 0) / float(timebase)
    if not math.isfinite(offset_ticks) or abs(offset_ticks - round(offset_ticks)) >= 1e-6 or abs(round(offset_ticks)) >= 2**63:
        raise ValueError("Native packet offset is not exactly representable in file ticks")
    packet_offset = round(offset_ticks) * timebase
    if decoder_pts - packet_offset != first_file_pts:
        raise ValueError("Native decoder PTS does not recover exact first file PTS")
    # The adapter descriptor requires source rational PTS == image->pts. Once
    # restart_complete is true, time-pos uses that selected video PTS. Validate
    # the zero decoder-to-player offset; never infer it from startup seek state.
    if abs(player_pts - float(decoder_pts)) > 1e-6:
        raise ValueError("Settled player PTS differs from the native decoder timeline")
    return {"nativeDemuxerStartSeconds": native_start, "rebaseStartTime": rebased,
        "packetOffset": rational(packet_offset), "decoderToPlayerSeconds": 0,
        "heldFirstFilePTS": rational(first_file_pts), "heldFirstDecoderPTS": rational(decoder_pts),
        "heldFirstPlayerSeconds": player_pts}


def observe_mapping(property_value, inventory, timebase, observations):
    native_start = property_value("demuxer-start-time")
    rebased = property_value("rebase-start-time")
    stable = []
    started = time.monotonic()
    while time.monotonic() - started < 20:
        seeking_before = property_value("seeking")
        before = property_value("enhancement-state")
        position = property_value("time-pos")
        after = property_value("enhancement-state")
        paused = property_value("pause")
        seeking_after = property_value("seeking")
        stamp = time.monotonic() - started
        unchanged = displayed_time(before) is not None and displayed_time(before) == displayed_time(after)
        held = seeking_before is False and seeking_after is False and paused is True and unchanged
        sample = {"elapsedSeconds": stamp, "seekingBefore": seeking_before, "seekingAfter": seeking_after,
            "paused": paused, "unchangedSelectedPTS": unchanged, "playerSeconds": position,
            "decoderPTS": rational(displayed_time(after)) if displayed_time(after) is not None else None}
        observations.append(sample)
        if held:
            mapping = mapping_from_observation(inventory[0], timebase, native_start, rebased,
                                               displayed_time(after), position)
            stable.append(sample)
            if len(stable) >= 3 and stamp - stable[0]["elapsedSeconds"] >= .1:
                mapping.update(nativeVersion=property_value("mpv-version"),
                    nativeDurationSeconds=property_value("duration"),
                    clockValidation="restart_complete bracket; three held paused decoder/time-pos pairs over at least100ms; zero decoder-to-player offset validated within1us, not estimated")
                return mapping
        else:
            stable.clear()
        time.sleep(.05)
    raise RuntimeError("Native mapping did not settle on a held paused frame; see mappingObservations")


def select_target(inventory, mapping, player_target=None, file_target=None):
    if not inventory or (player_target is None) == (file_target is None):
        raise ValueError("Exactly one player or file target and a nonempty inventory are required")
    offset = seconds(mapping["packetOffset"])
    player_offset = Fraction(str(mapping["decoderToPlayerSeconds"]))
    requested_player = file_target + offset + player_offset if file_target is not None else player_target
    requested_file = requested_player - player_offset - offset
    index = bisect_left(inventory, requested_file - Fraction(5, 1000))
    if requested_player < 0 or index >= len(inventory):
        raise ValueError("Seek target is outside the decoded source inventory")
    return {"seekTarget": rational(requested_player), "requestedFileTarget": rational(requested_file),
        "expectedFilePTS": rational(inventory[index]), "expectedSeekPTS": rational(inventory[index] + offset),
        "expectedPlayerSeconds": float(inventory[index] + offset + player_offset), "expectedFileFrameIndex": index,
        "seekTargetCoordinate": "file" if file_target is not None else "player"}


def evidence_paths(report):
    return [report] + [report.with_suffix(suffix) for suffix in
        (".configuration.json", ".engine.json", ".source-timing.json", ".visibility.json", ".log", ".native.log")]


def require_new_evidence(report):
    # Child mpv runs from the checkout, while Python may be invoked elsewhere.
    # Preserve the caller's destination without following a report symlink.
    report = report.absolute()
    paths = evidence_paths(report)
    if len(paths) != len(set(paths)):
        raise ValueError("Report path collides with one of its sidecars")
    existing = [str(path) for path in paths if path.exists() or path.is_symlink()]
    if existing:
        raise FileExistsError("Refusing to overwrite retained evidence: " + ", ".join(existing))
    return report


def reap_process(process, report):
    try:
        report["exitCode"] = process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        report["exitCode"] = process.wait(timeout=10)
        report["errors"].append("shutdown timed out; process killed")
        report["passed"] = False
    if report["exitCode"] != 0:
        report["passed"] = False
        report["errors"].append(f"mpv exited with status {report['exitCode']}")


def capture_visibility(engine, events, playback_start, playback_end):
    visibility = {"completedWork": qualify_visibility(events, *completed_window(engine)),
                  "playbackClock": qualify_visibility(events, playback_start, playback_end)}
    visibility["eligible"] = all(value["eligible"] for value in visibility.values())
    return visibility


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--seconds", type=float, default=12)
    parser.add_argument("--width", type=int, default=32)
    parser.add_argument("--height", type=int, default=24)
    targets = parser.add_mutually_exclusive_group()
    targets.add_argument("--seek-target", help="Final target in player seconds (default 0.73); exact source inventory is mapped after native origin settles")
    targets.add_argument("--file-seek-target", help="Final target in original file seconds, accepting an exact fraction such as 1742501/24000")
    parser.add_argument("--require-visible", action="store_true", help="Require native window coverage over warmed completed work and playback clocks")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if not (1 <= args.width <= 16384 and 1 <= args.height <= 16384):
        parser.error("processing dimensions must be within 1…16384")
    if not math.isfinite(args.seconds) or not 1 <= args.seconds <= 3600:
        parser.error("playback duration must be within1…3600seconds")
    try:
        args.report = require_new_evidence(args.report)
        player_target = Fraction(args.seek_target or "0.73") if args.file_seek_target is None else None
        file_target = Fraction(args.file_seek_target) if args.file_seek_target is not None else None
    except (ValueError, ZeroDivisionError, OSError) as error:
        parser.error(str(error))
    root = Path(__file__).resolve().parents[1]
    core_sources = {name: digest(root / "vendor/mpv" / name) for name in CORE_SOURCES}
    source_path = args.source.resolve()
    source_hash = digest(source_path)
    inventory, inventory_provenance = source_inventory(source_path, source_hash)
    if not inventory:
        parser.error("source has no exact decoded presentation timestamps")
    binaries = [root / "artifacts/mpv-build/mpv", root / "artifacts/mpv-build/libmpv.2.dylib",
                root / ".build/debug/libFrameEngineShared.dylib", root / ".build/debug/mlx.metallib"]
    provenance = {"root": revision(root), "mpv": revision(root / "vendor/mpv"),
        "MLX-DLSS": revision(root / "vendor/MLX-DLSS"),
        "binaries": {str(path.relative_to(root)): {"sha256": digest(path), "bytes": path.stat().st_size,
            "modifiedNanoseconds": path.stat().st_mtime_ns} for path in binaries if path.is_file()},
        "scriptSHA256": digest(Path(__file__)),
        "diagnosticSources": {name: digest(root / name) for name in
            ("scripts/test-mpv-policy.py", "scripts/adapter_visibility.py")},
        "coreSourceSHA256": core_sources,
        "recordedUTC": datetime.now(timezone.utc).isoformat()}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {"source": str(args.source.resolve()), "model": str(args.model),
              "reportSchemaVersion": 3,
              "avOffsetDefinition": "raw mpv avsync: audioPTS - videoPTS + audioDelay + audioOffset; cached at video queue updates, opposite the shared engine video-minus-audio sign",
              "conditions": "M3 native gpu-next/macvk, source-rate audio clock, muted CoreAudio; Adaptive explicitly buffers both clocks; lifecycle excluded from steady samples",
              "samples": [], "errors": []}
    report.update({"provenance": provenance, "sourceSHA256": source_hash, "inventoryProvenance": inventory_provenance,
        "seekSelection": "first exact file PTS >= mapped file target -5ms; expected decoder PTS includes the measured native packet offset",
        "requestedPlaybackWallSeconds": args.seconds})
    with args.report.with_suffix(".source-timing.json").open("x") as inventory_file:
        json.dump({"sourceSHA256": source_hash, "provenance": inventory_provenance,
                   "filePTS": [rational(value) for value in inventory]}, inventory_file, indent=2)
    with tempfile.TemporaryDirectory(prefix="mpv-policy-") as directory:
        ipc = Path(directory) / "ipc"
        options = f"@enhance:metal-hdr=policy=adaptive:processing-width={args.width}:processing-height={args.height}:strength=1:colour-strength=1:reference-white=203:maximum-luminance-ratio=2"
        if args.model:
            model = str(args.model.resolve())
            options += f":model=%{len(model.encode())}%{model}"
        source_stream = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,avg_frame_rate", "-of", "json", str(args.source)]))["streams"][0]
        report["sourceStream"] = source_stream
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
        with config_path.open("x") as configuration_file:
            configuration_file.write(json.dumps(config, indent=2) + "\n")
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
        report["arguments"] = cmd
        environment = dict(os.environ)
        if args.require_visible:
            environment["HDRPLAYER_MPV_VISIBILITY"] = "1"
        with args.report.with_suffix('.native.log').open('x') as native_log:
            process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=native_log,
                                       cwd=root, env=environment)
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

            def await_pair(seen, generation=-1, expected=None):
                deadline = time.monotonic() + 30
                current = {}
                while time.monotonic() < deadline:
                    current = state()
                    seen.append({"host": time.monotonic(), **current})
                    if current.get("compare-ready") and current.get("generation", -1) > generation and \
                            (expected is None or displayed_time(current) == expected):
                        return current
                    time.sleep(.02)
                raise RuntimeError(f"same-frame pair not ready: {current}")

            report["initialLifecycle"] = []
            initial = await_pair(report["initialLifecycle"])
            report["initial"] = initial
            if (initial.get("source-width"), initial.get("source-height"), initial.get("processing-width"),
                    initial.get("processing-height")) != (source_stream["width"], source_stream["height"], args.width, args.height):
                raise RuntimeError("native source or processing dimensions differ from requested configuration")
            report["mappingObservations"] = []
            report["timelineMapping"] = observe_mapping(
                lambda name: command("get_property", name).get("data"), inventory,
                seconds(inventory_provenance["timebase"]), report["mappingObservations"])
            report.update(select_target(inventory, report["timelineMapping"], player_target, file_target))
            seek_target = seconds(report["seekTarget"])
            expected_pts = seconds(report["expectedSeekPTS"])
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
            report["seekLifecycle"] = []
            final = await_pair(report["seekLifecycle"], before, expected_pts)
            report["seekSecondsToEnhancedPair"] = time.monotonic() - seek_start
            if displayed_time(final) != expected_pts:
                raise RuntimeError("final seek differs from exact source inventory")
            seek_settle_deadline = time.monotonic() + 5
            while command("get_property", "seeking").get("data"):
                if time.monotonic() > seek_settle_deadline:
                    raise RuntimeError("exact target pair did not complete playback restart")
                time.sleep(.02)
            report["settledSeekPlayerSeconds"] = command("get_property", "time-pos").get("data")
            if abs(report["settledSeekPlayerSeconds"] - report["expectedPlayerSeconds"]) > 1e-6:
                raise RuntimeError("settled seek player PTS differs from mapped exact decoder PTS")
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
            packet_offset = seconds(report["timelineMapping"]["packetOffset"])
            inventory_set = set(inventory)
            while time.monotonic() - started < args.seconds:
                current = state()
                offset = command("get_property", "avsync", allow_error=True).get("data")
                position = command("get_property", "time-pos", allow_error=True).get("data")
                decoded_pts = displayed_time(current)
                recovered_file_pts = decoded_pts - packet_offset if decoded_pts is not None else None
                sample = {"elapsed": time.monotonic() - started,
                    "avOffset": offset, "position": position, "state": current,
                    "paused": command("get_property", "pause").get("data"),
                    "seeking": command("get_property", "seeking").get("data"),
                    "recoveredFilePTS": rational(recovered_file_pts) if recovered_file_pts is not None else None}
                report["samples"].append(sample)
                if current.get("generation") != final["generation"]:
                    raise RuntimeError("unexpected seek or discontinuity during controlled playback")
                if recovered_file_pts not in inventory_set:
                    raise RuntimeError("displayed decoder PTS does not recover an exact file inventory frame")
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
            if process.poll() is None:
                # Ask the core to drain admitted inference during normal
                # teardown even when a diagnostic assertion failed.
                try:
                    client.sendall((json.dumps({"command": ["quit"]}) + "\n").encode())
                except OSError:
                    process.terminate()
        finally:
            if "stream" in locals():
                stream.close()
            client.close()
            reap_process(process, report)
            if args.require_visible:
                try:
                    engine = json.loads(engine_report.read_text())
                    events = window_events(args.report.with_suffix(".native.log").read_text(), "mpv")
                    visibility = capture_visibility(engine, events, report["playbackStartedHostSeconds"],
                                                    report["playbackEndedHostSeconds"])
                    report["engineSummary"] = {name: engine.get(name) for name in
                        ("completedTotal", "warmedSamples", "completedThroughputFPS", "retainedSamples")}
                except (ValueError, KeyError, OSError) as error:
                    visibility = {"eligible": False, "reasons": [str(error)]}
                report["visibility"] = visibility
                with args.report.with_suffix(".visibility.json").open("x") as visibility_file:
                    visibility_file.write(json.dumps(visibility, indent=2) + "\n")
                if not visibility["eligible"]:
                    report["passed"] = False
                    report["errors"].append("native window visibility did not cover both measured intervals")
            report["binaryHashesUnchanged"] = all(
                digest(root / name) == recorded["sha256"]
                for name, recorded in provenance["binaries"].items())
            if not report["binaryHashesUnchanged"]:
                report["passed"] = False
                report["errors"].append("a measured binary changed during the run")
            report["sourceHashUnchanged"] = digest(source_path) == source_hash
            report["modelHashUnchanged"] = not args.model or digest(args.model / "weights.safetensors") == model_id
            if not report["sourceHashUnchanged"] or not report["modelHashUnchanged"]:
                report["passed"] = False
                report["errors"].append("source or model changed during capture")
            with args.report.open("x") as report_file:
                report_file.write(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items()
                      if key not in ("samples", "initialLifecycle", "seekLifecycle", "comparison", "provenance")}, indent=2))
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
