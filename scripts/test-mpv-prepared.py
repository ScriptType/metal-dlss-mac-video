#!/usr/bin/env python3
"""Validate source-bound Prepared playback, exact hits/misses and process reuse."""
import argparse
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def source_inventory(source, output):
    command = ["ffprobe", "-v", "error", "-threads", "2", "-select_streams", "v:0",
        "-show_frames", "-show_streams", "-show_format", "-show_entries",
        "frame=pts,duration:stream=time_base,width,height:format=start_time,format_name", "-of", "json", str(source)]
    raw = subprocess.check_output(command, timeout=180)
    output.write_bytes(raw)
    probe = json.loads(raw)
    scale = Fraction(probe["streams"][0]["time_base"])
    frames = sorted((Fraction(frame["pts"]) * scale,
                     Fraction(frame["duration"]) * scale if frame.get("duration", 0) > 0 else None)
                    for frame in probe["frames"] if "pts" in frame)
    if not 12 <= len(frames) <= 100000 or any(a[0] >= b[0] for a, b in zip(frames, frames[1:])):
        raise RuntimeError("Prepared smoke requires12...100000 unique ordered source frames")
    stream = probe["streams"][0]
    # MP4 sample durations are explicit. Matroska demuxers can distinguish
    # absent BlockDuration from ffprobe's synthesized duration; in that case
    # retain native manifest durations and verify their exact bound digest.
    exact_durations = "mov" in probe["format"]["format_name"].split(",")
    if exact_durations and any(duration is None for _, duration in frames[:6]):
        raise RuntimeError("MP4 first-six sample duration is unavailable")
    return {"timings": frames, "timebase": scale, "width": stream["width"], "height": stream["height"],
            "exactDurationComparison": exact_durations, "format": probe["format"],
            "probeCommand": command, "probeSHA256": digest(output)}


def rational(value):
    return {"value": value.numerator, "timescale": value.denominator}


def displayed_time(state):
    return Fraction(state["displayed-source-pts"] * state["displayed-timebase-num"], state["displayed-timebase-den"])


def bounded_capacity(width, height):
    if type(width) is not int or type(height) is not int or not 0 < width <= 4096 or not 0 < height <= 2160:
        raise ValueError("Invalid bounded Prepared output geometry")
    required = width * height * 16 * 6 + 8 * 1024 * 1024
    capacity = 32 * 1024 * 1024
    while capacity < required:
        capacity *= 2
    if capacity > 512 * 1024 * 1024:
        raise ValueError("Six float frames exceed the512MiB smoke-cache bound")
    return capacity


def mapping_from_observation(first_file_pts, timebase, native_start, rebased, decoder_pts, player_pts):
    if type(rebased) is not bool or not all(isinstance(value, (int, float)) and math.isfinite(value) for value in (native_start, player_pts)):
        raise ValueError("Missing finite native start/rebase/player observation")
    packet_seconds = -native_start if rebased else 0
    offset_ticks = packet_seconds / float(timebase)
    if not math.isfinite(offset_ticks) or abs(offset_ticks - round(offset_ticks)) >= 1e-6 or abs(round(offset_ticks)) >= 2**63:
        raise ValueError("Native packet offset is not exactly representable in file ticks")
    packet_offset = round(offset_ticks) * timebase
    if decoder_pts - packet_offset != first_file_pts:
        raise ValueError("Native decoder PTS does not recover exact first file PTS")
    # This bounded harness uses the native adapter without timeline filters.
    # mp_hdr_frame_descriptor rejects source rational PTS != image->pts; after
    # restart_complete, handle_playback_time uses the selected video PTS.
    # Validate that contract; never estimate an offset from a startup seek target.
    if abs(player_pts - float(decoder_pts)) > 1e-6:
        raise ValueError("Settled player PTS differs from the native decoder timeline")
    decoder_to_player = 0.0
    return {"nativeDemuxerStartSeconds": native_start, "rebaseStartTime": rebased,
            "packetOffset": rational(packet_offset), "decoderToPlayerSeconds": decoder_to_player,
            "heldFirstFilePTS": rational(first_file_pts), "heldFirstDecoderPTS": rational(decoder_pts),
            "heldFirstPlayerSeconds": player_pts}


def seconds(value):
    return Fraction(value["value"], value["timescale"])


def verify_provider(identifier, mapping, version):
    fields = identifier.split(";")
    if len(fields) < 8 or fields[:2] != ["mpv-independent-demux-vt-v1", version]:
        raise ValueError("Cache provider does not bind actual native version/decoder policy")
    values = dict(value.split("=", 1) for value in fields[2:] if "=" in value)
    try:
        offset = float(values["offset"])
        codec = int(values["libavcodec"])
    except (ValueError, KeyError) as error:
        raise ValueError("Provider offset/codec identity unavailable") from error
    if not math.isfinite(offset) or abs(offset - float(seconds(mapping["packetOffset"]))) > 1e-9 or codec <= 0 or values.get("demux") not in ("lavf", "mkv"):
        raise ValueError("Provider decoder/offset differs from observed active core")
    if fields[-1] != "exact-decoder-pts-duration-native-fallback":
        raise ValueError("Unexpected provider timing interpretation")
    return values


def snapshot_cache(cache, archive, phase, inventory, mapped, mapping, version, source_hash, model_hash, capacity):
    paths = sorted((cache / "segments").glob("*/manifest.json"))
    if len(paths) != 2:
        raise ValueError("Expected exactly two committed six-frame cache segments")
    manifests = sorted([(path, json.loads(path.read_text())) for path in paths],
                       key=lambda item: seconds(item[1]["identity"]["range"]["start"]))
    snapshots = []
    for segment, (path, manifest) in enumerate(manifests):
        identity = manifest["identity"]
        if manifest["schemaVersion"] != 2 or manifest["storagePolicy"] != "rgba-f32le-linear-bt2020-absolute-nits-straight-alpha-v1":
            raise ValueError("Cache lacks exact-timing float reference policy")
        if identity["source"]["contentSHA256"] != source_hash or identity["settings"]["modelSHA256"] != model_hash:
            raise ValueError("Cache source/model identity mismatch")
        if (identity["settings"]["outputWidth"], identity["settings"]["outputHeight"]) != (inventory["width"], inventory["height"]):
            raise ValueError("Cache output geometry differs from source")
        provider = identity["source"]["interpretation"]["decoder"]
        verify_provider(provider, mapping, version)
        start = segment * 3
        if seconds(identity["range"]["start"]) != mapped[start] or seconds(identity["range"]["end"]) != mapped[start + 3]:
            raise ValueError("Cache range differs from exact decoder-space request")
        if seconds(identity["preroll"]["start"]) != mapped[max(0, start - 1)]:
            raise ValueError("Cache preroll differs from exact decoder inventory")
        records = manifest["frames"]
        timings = [record["timing"] for record in records]
        if len(timings) != 3 or [seconds(timing["presentationTime"]) for timing in timings] != mapped[start:start + 3]:
            raise ValueError("Published cache PTS differs from exact mapped file inventory")
        durations = [seconds(timing["duration"]) for timing in timings]
        if any(duration <= 0 for duration in durations) or (inventory["exactDurationComparison"] and durations != [frame[1] for frame in inventory["timings"][start:start + 3]]):
            raise ValueError("Published exact cache durations differ")
        timing_hash = hashlib.sha256(canonical(timings)).hexdigest()
        if timing_hash != identity["timingInventorySHA256"]:
            raise ValueError("Published timing inventory digest mismatch")
        key = hashlib.sha256(canonical(identity)).hexdigest()
        if key != manifest["key"] or key != path.parent.name:
            raise ValueError("Committed cache key does not bind full processing identity")
        for index, record in enumerate(records):
            if record["fileName"] != f"{index:08d}.rgba32f":
                raise ValueError("Unexpected cache payload path")
            payload = path.parent / record["fileName"]
            if payload.is_symlink() or payload.stat().st_size != inventory["width"] * inventory["height"] * 16 or payload.stat().st_size != record["byteCount"] or digest(payload) != record["sha256"]:
                raise ValueError("Cache pixel payload does not match committed manifest")
        archived = archive / f"phase{phase}-{key}.json"
        shutil.copyfile(path, archived)
        snapshots.append({"key": key, "providerIdentifier": provider, "timingInventorySHA256": timing_hash,
                          "manifest": str(archived), "manifestSHA256": digest(archived),
                          "payloadSHA256": [record["sha256"] for record in records],
                          "filePTS": [rational(inventory["timings"][i][0]) for i in range(start, start + 3)],
                          "decoderPTS": [timing["presentationTime"] for timing in timings], "pixelPayloadsVerified": True})
    usage = sum(path.stat().st_size for path in cache.rglob("*") if path.is_file())
    if usage > capacity or any((cache / "staging").iterdir()):
        raise ValueError("Cache exceeded capacity or retained incomplete staging")
    return {"logicalBytes": usage, "capacityBytes": capacity, "segments": snapshots}


def check_source_guards(source, directory):
    config = directory / "guard-configuration.json"
    request = {"sourcePath": str(directory / "wrong-source.mp4"),
               "cacheDirectory": str(directory / "guard-cache"), "capacityBytes": 33554432}
    config.write_text(json.dumps(request))
    command = [str(ROOT / "artifacts/mpv-build/mpv"), "--no-config", "--vo=null", "--ao=null",
        "--frames=1", "--hwdec=no", "--msg-level=all=error",
        f"--vf=metal-hdr=prepared-config={config}:processing-width=32:processing-height=24:strength=0"]
    result = subprocess.run([*command, str(source)], capture_output=True, text=True, timeout=10)
    mismatch = result.stdout + result.stderr
    if "Prepared source differs" not in mismatch:
        raise RuntimeError(f"different opened source was not rejected: {mismatch}")
    multiple = directory / "two-video.mp4"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(source),
        "-map", "0:v:0", "-map", "0:v:0", "-c", "copy", str(multiple)], check=True)
    request["sourcePath"] = str(multiple)
    config.write_text(json.dumps(request))
    result = subprocess.run([*command, "--vid=2", str(multiple)], capture_output=True, text=True, timeout=10)
    second = result.stdout + result.stderr
    if "first video stream" not in second:
        raise RuntimeError(f"second video stream was not rejected: {second}")
    return {"wrongSourceRejected": True, "nonFirstVideoRejected": True,
            "wrongSourceDiagnostic": mismatch.strip(), "nonFirstVideoDiagnostic": second.strip()}


class Playback:
    def __init__(self, source, configuration, log, model):
        self.directory = tempfile.TemporaryDirectory(prefix="mpv-prepared-ipc-")
        path = Path(self.directory.name) / "ipc"
        self.sequence = 0
        self.process = self.socket = self.stream = None
        effect = 1 if model else 0
        options = f"@enhance:metal-hdr=processing-width=32:processing-height=24:strength={effect}:policy=adaptive"
        if configuration is None:
            options += ":bypass=yes"
        else:
            value = str(configuration)
            options += f":prepared-config=%{len(value.encode())}%{value}"
        if model:
            value = str(model)
            options += f":model=%{len(value.encode())}%{value}"
        self.arguments = [str(ROOT / "artifacts/mpv-build/mpv"), "--no-config",
            "--vo=gpu-next", "--gpu-api=vulkan", "--gpu-context=macvk", "--target-colorspace-hint=yes",
            "--hwdec=videotoolbox", "--pause", "--keep-open=yes", "--ao=null",
            "--input-default-bindings=no", "--input-builtin-bindings=no", "--input-vo-keyboard=no",
            "--input-terminal=no", f"--input-ipc-server={path}", f"--log-file={log}",
            f"--vf={options}", str(source)]
        self.stderr_log = Path(log).with_suffix(".stderr.log")
        try:
            with self.stderr_log.open("xb") as diagnostic:
                self.process = subprocess.Popen(self.arguments, stdout=diagnostic,
                    stderr=subprocess.STDOUT, cwd=ROOT)
            deadline = time.monotonic() + 20
            while not path.exists():
                if self.process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Prepared player did not open IPC")
                time.sleep(.02)
            self.socket = socket.socket(socket.AF_UNIX)
            self.socket.settimeout(30)
            self.socket.connect(str(path))
            self.stream = self.socket.makefile("rwb", buffering=0)
        except BaseException:
            if self.stream:
                self.stream.close()
            if self.socket:
                self.socket.close()
            try:
                if self.process and self.process.poll() is None:
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                        self.process.wait(timeout=10)
            finally:
                self.directory.cleanup()
            raise

    def command(self, *values):
        self.sequence += 1
        self.stream.write((json.dumps({"command": values, "request_id": self.sequence}) + "\n").encode())
        while line := self.stream.readline():
            response = json.loads(line)
            if response.get("request_id") == self.sequence:
                if response["error"] != "success":
                    raise RuntimeError(str(response))
                return response.get("data")
        raise RuntimeError("Prepared player closed IPC")

    def wait(self, predicate, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = self.command("get_property", "enhancement-state")
            if state.get("prepared", {}).get("error"):
                raise RuntimeError(state["prepared"]["error"])
            if predicate(state):
                return state
            time.sleep(.05)
        raise RuntimeError(f"Prepared state timed out: {state}")

    def close(self):
        try:
            if self.process.poll() is None:
                self.command("quit")
        finally:
            self.stream.close(); self.socket.close()
            try:
                status = self.process.wait(timeout=35)
            except subprocess.TimeoutExpired:
                self.process.terminate(); self.process.wait(timeout=10)
                self.directory.cleanup()
                raise RuntimeError("Prepared core required forced termination")
            self.directory.cleanup()
        if status:
            raise RuntimeError(f"Prepared player exit code {status}")


def observe_mapping(player, inventory):
    player.wait(lambda state: "displayed-source-pts" in state)
    native_start = player.command("get_property", "demuxer-start-time")
    rebased = player.command("get_property", "rebase-start-time")
    # Seeking is !restart_complete. The core sets playback_pts from video_pts
    # before completion, so false brackets exclude the initial last_seek_pts=0.
    observations, stable = [], []
    started = time.monotonic()
    while time.monotonic() - started < 20:
        seeking_before = player.command("get_property", "seeking")
        state = player.command("get_property", "enhancement-state")
        position = player.command("get_property", "time-pos")
        after = player.command("get_property", "enhancement-state")
        paused = player.command("get_property", "pause")
        seeking_after = player.command("get_property", "seeking")
        stamp = time.monotonic() - started
        unchanged = "displayed-source-pts" in state and "displayed-source-pts" in after and displayed_time(state) == displayed_time(after)
        held = seeking_before is False and seeking_after is False and paused is True and unchanged
        sample = {"elapsedSeconds": stamp, "seekingBefore": seeking_before, "seekingAfter": seeking_after,
                  "paused": paused, "unchangedSelectedPTS": unchanged, "playerSeconds": position,
                  "decoderPTS": rational(displayed_time(after)) if "displayed-source-pts" in after else None}
        observations.append(sample)
        if held:
            mapping = mapping_from_observation(inventory["timings"][0][0], inventory["timebase"],
                native_start, rebased, displayed_time(after), position)
            stable.append(sample)
            if len(stable) >= 3 and stamp - stable[0]["elapsedSeconds"] >= .1:
                mapping["nativeVersion"] = player.command("get_property", "mpv-version")
                mapping["state"] = after
                mapping["observations"] = observations
                mapping["clockValidation"] = "restart_complete bracket; three held paused decoder/time-pos pairs over at least100ms; zero decoder-to-player offset validated within1us, not estimated"
                return mapping
        else:
            stable.clear()
        time.sleep(.05)
    raise RuntimeError(f"Native mapping did not settle on a held paused frame: {observations}")


def evidence_paths(report):
    paths = [report, report.with_suffix(".cache-manifests"), report.with_suffix(".source-timing.json")]
    for phase in ("origin", "phase0", "phase1"):
        log = report.with_suffix(f".{phase}.log")
        paths.extend([log, log.with_suffix(".stderr.log")])
    return paths


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=ROOT / "assets/test-clips/hdr10-30.mp4")
    parser.add_argument("--model", type=Path)
    parser.add_argument("--cancel-first", action="store_true", help="Cancel after actual work, then resume the same provider context")
    parser.add_argument("--report", type=Path, default=ROOT / "artifacts/mpv-prepared-smoke.json")
    args = parser.parse_args()
    source = args.source.resolve()
    model = args.model.resolve() if args.model else None
    args.report.parent.mkdir(parents=True, exist_ok=True)
    archive = args.report.with_suffix(".cache-manifests")
    source_probe = args.report.with_suffix(".source-timing.json")
    if any(path.exists() for path in evidence_paths(args.report)):
        raise RuntimeError("Use a new report and associated evidence paths")
    archive.mkdir()
    inventory = source_inventory(source, source_probe)
    capacity = bounded_capacity(inventory["width"], inventory["height"])
    source_hash = digest(source)
    model_hash = digest(model / "weights.safetensors") if model else hashlib.sha256(b"original-hdr-v1").hexdigest()
    binaries = [ROOT / "artifacts/mpv-build/mpv", ROOT / "artifacts/mpv-build/libmpv.2.dylib",
                ROOT / ".build/debug/libFrameEngineShared.dylib", ROOT / "artifacts/local/lib/libplacebo.dylib",
                ROOT / ".build/debug/mlx.metallib"]
    revision_paths = {"root": ROOT, "mpv": ROOT / "vendor/mpv", "libplacebo": ROOT / "vendor/libplacebo"}
    report = {"source": str(source), "model": str(model), "phases": [], "errors": [],
        "sourceSHA256": source_hash, "modelSHA256": model_hash,
        "fileInventory": {"firstTwelve": [{"pts": rational(pts), "duration": rational(duration) if duration else None} for pts, duration in inventory["timings"][:12]],
                          "frameCount": len(inventory["timings"]), "width": inventory["width"], "height": inventory["height"],
                          "ffprobeFormat": inventory["format"], "probe": str(source_probe), "sha256": inventory["probeSHA256"],
                          "exactDurationComparison": inventory["exactDurationComparison"]},
        "capacityBytes": capacity, "cacheManifests": [],
        "binaries": {str(path.resolve()): {"beforeSHA256": digest(path)} for path in binaries},
        "revisions": {name: subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip() for name, path in revision_paths.items()},
        "workingState": {name: subprocess.check_output(["git", "-C", str(path), "status", "--short"], text=True) for name, path in revision_paths.items()},
        "sourceHashes": {str(path.relative_to(ROOT)): digest(path) for path in [Path(__file__), ROOT / "vendor/mpv/demux/lavf_timing.h", ROOT / "vendor/mpv/demux/demux_lavf.c", ROOT / "vendor/mpv/video/filter/metal_hdr_decoder.m", ROOT / "vendor/mpv/video/filter/vf_metal_hdr.m", ROOT / "vendor/mpv/player/playloop.c"]},
        "timingSelection": "First six exact file frames mapped into observed decoder/cache coordinates; independent native decoder/player mapping"}
    with tempfile.TemporaryDirectory(prefix="mpv-prepared-cache-") as directory:
        cache = Path(directory) / "cache"
        configuration = Path(directory) / "configuration.json"
        try:
            origin = Playback(source, None, args.report.with_suffix(".origin.log"), None)
            try:
                mapping = observe_mapping(origin, inventory)
                if mapping["state"].get("submitted-frames") != 0:
                    raise RuntimeError("Origin-only bypass admitted engine work")
                report["originProbe"] = {"arguments": origin.arguments, "mapping": mapping}
            finally:
                origin.close()
            report["originProbe"]["processExitedCleanly"] = True
            offset = seconds(mapping["packetOffset"])
            mapped = [pts + offset for pts, _ in inventory["timings"]]
            range_start, range_end, hit_pts, miss_pts = mapped[0], mapped[6], mapped[3], mapped[11]
            request = {"sourcePath": str(source), "cacheDirectory": str(cache), "capacityBytes": capacity,
                "rangeStart": rational(range_start), "rangeEnd": rational(range_end),
                "segmentFrames": 3, "prerollFrames": 1}
            configuration.write_text(json.dumps(request))
            report["preparedRequest"] = request
            report["rangeStart"] = rational(range_start); report["rangeEnd"] = rational(range_end)
            report["expectedHitPTS"] = rational(hit_pts); report["expectedMissPTS"] = rational(miss_pts)
            for phase in range(2):
                player = Playback(source, configuration, args.report.with_suffix(f".phase{phase}.log"), model)
                try:
                    initial = player.wait(lambda s: s.get("compare-ready") and s.get("prepared", {}).get("configurationState") == "ready")
                    observed = observe_mapping(player, inventory)
                    for key in ("packetOffset", "nativeVersion"):
                        if observed[key] != mapping[key]:
                            raise RuntimeError(f"Prepared core changed observed {key}")
                    if abs(observed["decoderToPlayerSeconds"] - mapping["decoderToPlayerSeconds"]) > 1e-6:
                        raise RuntimeError("Prepared core changed decoder-to-player mapping")
                    player.command("vf-command", "enhance", "prepare", "start")
                    if phase == 0 and args.cancel_first:
                        working = player.wait(lambda s: s.get("prepared", {}).get("processedFrames", 0) >= 1)
                        if working["prepared"]["jobState"] == "complete":
                            raise RuntimeError("preparation completed before cancellation could be exercised")
                        player.command("vf-command", "enhance", "prepare", "cancel")
                        report["cancelled"] = player.wait(lambda s: s.get("prepared", {}).get("jobState") == "cancelled")
                        player.command("vf-command", "enhance", "prepare", "start")
                    complete = player.wait(lambda s: s.get("prepared", {}).get("jobState") == "complete")
                    generation, hits = complete["generation"], complete["prepared"]["cacheHits"]
                    player.command("seek", float(hit_pts) + observed["decoderToPlayerSeconds"], "absolute+exact")
                    hit = player.wait(lambda s: s.get("compare-ready") and s.get("generation", 0) > generation and
                                      s.get("prepared", {}).get("cacheHits", 0) > hits)
                    if displayed_time(hit) != hit_pts or displayed_time(hit) - offset != inventory["timings"][3][0]:
                        raise RuntimeError("cached frame has wrong source timestamp")
                    expected = "prepared-enhanced" if model else "prepared-original"
                    if hit.get("displayed-content-kind") != expected:
                        raise RuntimeError("cached frame lost immutable content provenance")
                    generation, misses = hit["generation"], hit["prepared"]["cacheMisses"]
                    player.command("seek", float(miss_pts) + observed["decoderToPlayerSeconds"], "absolute+exact")
                    miss = player.wait(lambda s: s.get("compare-ready") and s.get("generation", 0) > generation and
                                       s.get("prepared", {}).get("cacheMisses", 0) > misses)
                    if miss.get("displayed-content-kind") != "original":
                        raise RuntimeError("cache miss incorrectly labeled enhanced")
                    if displayed_time(miss) != miss_pts or displayed_time(miss) - offset != inventory["timings"][11][0]:
                        raise RuntimeError("original miss has wrong source timestamp")
                    report["phases"].append({"initial": initial, "mapping": observed, "prepared": complete, "hit": hit, "miss": miss,
                        "hitFilePTS": rational(inventory["timings"][3][0]), "missFilePTS": rational(inventory["timings"][11][0])})
                finally:
                    player.close()
                report["cacheManifests"].append(snapshot_cache(cache, archive, phase, inventory, mapped,
                    mapping, mapping["nativeVersion"], source_hash, model_hash, capacity))
            first, second = (phase["prepared"]["prepared"] for phase in report["phases"])
            if first["processedFrames"] + first["reusedSegments"] * 3 != 6 or second["reusedSegments"] != 2 or second["processedFrames"] != 0:
                raise RuntimeError("reopening did not reuse the published completed segments")
            before, after = report["cacheManifests"]
            if [(segment["key"], segment["manifestSHA256"], segment["payloadSHA256"]) for segment in before["segments"]] != [(segment["key"], segment["manifestSHA256"], segment["payloadSHA256"]) for segment in after["segments"]]:
                raise RuntimeError("Reopen changed completed cache identity or payloads")
            report["sourceGuards"] = check_source_guards(source, Path(directory))
            report["passed"] = True
        except Exception as error:
            report["passed"] = False
            report["errors"].append(str(error))
        finally:
            for path, value in report["binaries"].items():
                value["afterSHA256"] = digest(path)
            report["binariesUnchanged"] = all(value["beforeSHA256"] == value["afterSHA256"] for value in report["binaries"].values())
            report["sourceUnchanged"] = digest(source) == source_hash
            report["passed"] &= report["binariesUnchanged"] and report["sourceUnchanged"]
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "errors": report["errors"],
                      "completedProcesses": len(report["phases"])}, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
