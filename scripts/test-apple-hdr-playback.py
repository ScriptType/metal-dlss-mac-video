#!/usr/bin/env python3
"""One pinned Apple HDR10+ frame through native PQ/float/retained comparison.

--prepare-only performs software metadata/timing preflight without a player,
GPU inference, window, capture permission request, or binary rebuild.
--metadata-only still renders and processes actual native GPU frames, but skips
SCK capture and makes no compositor visibility/geometry acceptance claim.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE_SHA = "65365b9c91bede25c294a34e87106e80f8794ba15a690b2cb9f608d18385c5b5"
SOURCE_BYTES = 41784502
COLOR = {"pix_fmt": "yuv420p10le", "color_range": "tv", "color_space": "bt2020nc",
         "color_primaries": "bt2020", "color_transfer": "smpte2084", "chroma_location": "topleft"}
DYNAMIC_FIELDS = ("scene-max-r", "scene-max-g", "scene-max-b", "scene-avg")


class Pairs(dict):
    """ffprobe emits repeated maxscl keys: normal JSON decoding loses R and G."""
    def __init__(self, pairs):
        super().__init__(pairs)
        self.pairs = pairs

    def all(self, name):
        return [value for key, value in self.pairs if key == name]


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def parse_inventory(packet_probe, frame_probe, ordinal):
    streams = packet_probe["streams"]
    video = [stream for stream in streams if stream["codec_type"] == "video"]
    audio = [stream for stream in streams if stream["codec_type"] == "audio"]
    if len(video) != 1 or len(audio) != 1:
        raise ValueError("Expected exactly the pinned video and AAC stream")
    video, audio = video[0], audio[0]
    if Fraction(video["time_base"]) != Fraction(1, 24000) or (video["width"], video["height"]) != (1920, 1080):
        raise ValueError("Video timing or geometry differs")
    if (audio["codec_name"], audio["sample_rate"], audio["channels"], audio["time_base"]) != ("aac", "48000", 2, "1/48000"):
        raise ValueError("Audio description differs")
    packets = sorted((int(p["pts"]), int(p["duration"])) for p in packet_probe["packets"] if p["stream_index"] == video["index"])
    expected = [(241001 + index * 1001, 1001) for index in range(2360)]
    if packets != expected:
        raise ValueError("Exact pinned video presentation inventory differs")
    audio_packets = [p for p in packet_probe["packets"] if p["stream_index"] == audio["index"]]
    if len(audio_packets) != 4617 or int(audio_packets[0]["pts"]) != 477888:
        raise ValueError("Exact pinned audio origin/count differs")
    if Fraction(packet_probe["format"]["start_time"]) != Fraction(2489, 250):
        raise ValueError("Container start differs from 9.956 seconds")
    frames = frame_probe["frames"]
    if [(int(f["pts"]), int(f["duration"])) for f in frames] != expected:
        raise ValueError("Decoded presentation inventory differs from the packets")
    if not 0 <= ordinal < len(frames):
        raise ValueError("Selected ordinal is outside the exact inventory")
    metadata = []
    for frame in frames:
        if any(frame.get(key) != value for key, value in COLOR.items()):
            raise ValueError("Decoded colour/format differs from the explicit PQ base")
        entries = [entry for entry in frame.get("side_data_list", [])
                   if entry["side_data_type"] == "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"]
        if len(entries) != 1 or entries[0].get("num_windows") != 1:
            raise ValueError("Expected exactly one HDR10+ metadata window per decoded frame")
        dynamic = entries[0]
        maximums = dynamic.all("maxscl")
        averages = dynamic.all("average_maxrgb")
        if len(maximums) != 3 or len(averages) != 1:
            raise ValueError("Incomplete or ambiguous HDR10+ maxSCL/average metadata")
        values = [float(Fraction(value) * 10000) for value in maximums + averages]
        if not all(math.isfinite(value) and value >= 0 for value in values) or values[-1] == 0 or not any(values[:3]):
            raise ValueError("Unusable HDR10+ scene metadata")
        metadata.append(dict(zip(DYNAMIC_FIELDS, values)))
    return {"frameCount": len(frames), "allFramesHaveHDR10Plus": True,
            "sourceFrameOrdinal": ordinal, "sourcePTS": packets[ordinal][0],
            "sourceDuration": packets[ordinal][1], "timescale": 24000,
            "sourcePTSSemantics": "Original file packet inventory; native decoder timestamps may include mpv demux offset",
            "formatStartSeconds": float(Fraction(packet_probe["format"]["start_time"])),
            "firstVideoPTS": {"value": 241001, "timescale": 24000},
            "lastVideoPTS": {"value": packets[-1][0], "timescale": 24000},
            "lastVideoEnd": {"value": sum(packets[-1]), "timescale": 24000},
            "firstAudioPTS": {"value": 477888, "timescale": 48000},
            "expectedMetadata": metadata[ordinal], "lastFrameMetadata": metadata[-1], "colour": COLOR,
            "dynamicMetadataInterpretation": "Original PQ base is decoded; original HDR10+ scene descriptors are checked, not a dynamic-display accuracy claim"}


def float_statistics(path, description, scale=203, units="cd/m2"):
    width, height, stride = (description[key] for key in ("width", "height", "bytesPerRow"))
    if not (0 < width <= 4096 and 0 < height <= 2160 and width * 8 <= stride <= 131072 and stride * height <= 64 * 1024 * 1024):
        raise ValueError("Float reference exceeds bounded layout")
    if path.stat().st_size != stride * height or sha(path) != description["sha256"]:
        raise ValueError("Float reference hash or byte count changed")
    minimum, maximum, total, negative, above10k = math.inf, -math.inf, 0., 0, 0
    with path.open("rb") as stream:
        for _ in range(height):
            row = stream.read(stride)
            for red, green, blue, alpha in struct.iter_unpack("<eeee", row[:width * 8]):
                if not all(math.isfinite(value) for value in (red, green, blue, alpha)):
                    raise ValueError("Nonfinite completed float component")
                for value in (red * scale, green * scale, blue * scale):
                    minimum, maximum = min(minimum, value), max(maximum, value)
                    total += value; negative += value < 0; above10k += value > 10000
    return {"units": units, "conversion": f"RGB components ×{scale}; alpha excluded",
            "minimum": minimum, "maximum": maximum, "meanComponent": total / (width * height * 3),
            "negativeComponents": negative, "above10000Components": above10k, "nonfiniteComponents": 0}


def validate_target_range(phase):
    target = phase["video-target-params"]
    source = phase["video-out-params"]
    if (target.get("primaries"), target.get("gamma")) != ("bt.2020", "linear"):
        raise ValueError("Native target is not linear BT.2020")
    source_peak, target_peak = source.get("max-luma"), target.get("max-luma")
    if not all(isinstance(value, (int, float)) and math.isfinite(value) and value > 0
               for value in (source_peak, target_peak)):
        raise ValueError("Missing finite source/target peak")
    if abs(source_peak - target_peak) > max(0.001, source_peak * 1e-5):
        raise ValueError("Native target peak differs from the reconstructed source range")
    return {"sourcePeakNits": source_peak, "targetPeakNits": target_peak,
            "absoluteDifferenceNits": abs(source_peak - target_peak)}


def validate_capture_coverage(visibility, metadata_only):
    visible = bool(visibility) and all(row.get("visible") and row.get("occlusionVisible") and not row.get("miniaturized") for row in visibility)
    geometry = [(row["windowFrame"], row["hostBounds"], row.get("metalLayer", {}).get("drawableSize")) for row in visibility]
    stable = bool(geometry) and all(row == geometry[0] for row in geometry)
    if not metadata_only:
        if not visible:
            raise ValueError("Actual native window visibility was not maintained during capture")
        if not stable:
            raise ValueError("Native geometry moved during the single display capture")
    return {"visibilitySamples": len(visibility), "geometryStable": stable,
            "visibilityMaintained": visible,
            "sckAcceptance": "not-requested" if metadata_only else "visibility-and-geometry-gates-passed"}


def validate_timeline_mapping(mapping, identities):
    native_start = mapping["nativeDemuxerStartSeconds"]
    rebased = mapping["nativeRebaseStartTime"]
    observed = mapping["observedDecoderToPlayerSeconds"]
    if type(rebased) is not bool or not all(isinstance(value, (int, float)) and math.isfinite(value)
                                           for value in (native_start, observed)):
        raise ValueError("Missing finite native origin/rebase observation")
    packet_time = mapping["demuxPacketOffset"]
    packet_offset = Fraction(packet_time["value"], packet_time["timescale"])
    expected_packet_offset = -native_start if rebased else 0
    if abs(float(packet_offset) - expected_packet_offset) * packet_time["timescale"] >= 1e-6:
        raise ValueError("Exact demux packet offset disagrees with native rebase option")
    for row in [mapping["heldInitialIdentity"]] + identities:
        decoder = Fraction(row["decoderPTS"]["value"], row["decoderPTS"]["timescale"])
        original = Fraction(row["originalFilePTS"]["value"], row["originalFilePTS"]["timescale"])
        if decoder - packet_offset != original:
            raise ValueError("Undoing demux packet offset does not recover exact file PTS")
        player, offset = row["playerPTSSeconds"], row["decoderToPlayerSeconds"]
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in (player, offset)) or abs(offset - observed) > 1e-8 or abs(player - float(decoder) - observed) > 1e-8:
            raise ValueError("Held decoder/player pair disagrees with separate exporter mapping")
    return {"nativeDemuxerStartSeconds": native_start, "demuxPacketOffset": packet_time,
            "decoderToPlayerSeconds": observed,
            "ffprobeFormatStartSeconds": mapping["ffprobeFormatStartSeconds"],
            "verifiedHeldPairs": len(identities) + 1,
            "scope": "Exact file-to-decoder recovery and separate decoder-to-player mapping; no physical synchronization inference"}


def validate_native_end(check):
    end = check["declaredPlayerEndSeconds"]
    frame_end = check["lastFramePlayerEndSeconds"]
    if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in (end, frame_end)) or end + 1e-6 < frame_end:
        raise ValueError("Declared native range excludes part of the last source frame")
    before, after = check["inferenceBefore"], check["inferenceAfter"]
    if any(type(before.get(key)) is not int or before[key] != after.get(key)
           for key in ("submitted-frames", "completed-frames")):
        raise ValueError("Original-only end-range check changed neural work counts")
    return {"declaredPlayerEndSeconds": end, "lastFramePlayerEndSeconds": frame_end,
            "remainingRangeSeconds": end - frame_end, "newNeuralSubmissions": 0,
            "scope": "Exact held last frame plus duration is contained in the declared native range"}


def validate_float_attachments(attachments):
    # CVBufferCopyAttachments exposes the raw public CFString keys, not the
    # shorter names used in some CMFormatDescription dictionaries.
    if attachments.get("CVImageBufferColorPrimaries") != "ITU_R_2020" or attachments.get("CVImageBufferTransferFunction") != "Linear" or attachments.get("CGColorSpace", {}).get("name") != "kCGColorSpaceExtendedLinearITUR_2020":
        raise ValueError("Completed CVPixelBuffer attachment contract differs")


def validate_session(session, output, metadata_only=False):
    if not session.get("passed") or not session.get("coreDestroyed"):
        raise ValueError(f"Host failed: {session.get('error')}")
    if session.get("metadataOnly") is not metadata_only:
        raise ValueError("Host/wrapper capture modes disagree")
    phases = session["phases"]
    if [phase["name"] for phase in phases] != ["original-pq", "enhanced", "retained-original", "retained-enhanced", "last-original-pq"]:
        raise ValueError("Incomplete phase sequence")
    snapshots = [phase["identity"] for phase in phases]
    for key in ("originalFilePTS", "decoderPTS"):
        timestamps = [Fraction(s[key]["value"], s[key]["timescale"]) for s in snapshots[:4]]
        if len(set(timestamps)) != 1:
            raise ValueError(f"Phases refer to different {key} timestamps")
    timeline = validate_timeline_mapping(session["timelineMapping"], snapshots)
    native_end = validate_native_end(session["lastFrameRangeCheck"])
    target_checks = []
    for phase in (phases[1], phases[3]):
        target_checks.append(validate_target_range(phase))
        params, pixels = phase["video-out-params"], phase["exported"]
        if (params.get("primaries"), params.get("gamma"), params.get("colormatrix"), params.get("colorlevels")) != ("bt.2020", "linear", "rgb", "full"):
            raise ValueError("Enhanced output is not explicit linear full-range BT.2020 RGB")
        attachments = pixels["attachmentsPropagating"]
        validate_float_attachments(attachments)
        phase["componentStatisticsNits"] = float_statistics(output / phase["name"] / pixels["file"], pixels)
    if session["maximumLeases"] > 2 or session["leaseDrainSnapshot"]["outstandingLeases"] != 0 or session["leaseDrainSnapshot"]["unexpectedLeaseReturned"]:
        raise ValueError("Consumer lease bound or teardown failed")
    coverage = validate_capture_coverage(session["captureVisibility"], metadata_only)
    layer = phases[3]["surface"]["metalLayer"]
    if layer["pixelFormat"] != 115 or layer["colorspace"].get("name") != "kCGColorSpaceExtendedLinearITUR_2020" or not layer["wantsExtendedDynamicRangeContent"]:
        raise ValueError("Actual native layer is not RGBA16Float extended-linear BT.2020 EDR")
    if layer["edrMetadata"] == "none":
        raise ValueError("Native linear layer has no output-mapping metadata")
    return {"observedChecks": len(session["checks"]), "floatStatistics": phases[3]["componentStatisticsNits"],
            "timelineMapping": timeline,
            "lastFrameRangeCheck": native_end,
            "captureCoverage": coverage,
            "displayMapping": {"videoTargetParams": phases[3]["video-target-params"], "actualLayer": layer,
                               "sourceTargetPeakChecks": target_checks,
                               "opticalScale": {"configuredNitsPerFloatUnit": 203,
                                                "basis": "Reviewed macvk source assignment; no public optical-scale getter or reliable value in CAEDRMetadata description"}},
            "limitations": ["One held source frame; no sustained playback acceptance", "SCK compositor output is not physical panel luminance", "HDR10+ metadata retention/removal does not prove original dynamic tone-mapping accuracy"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source", type=Path, default=ROOT / "artifacts/public-hdr-source-audit/apple-advanced-hdr10plus-aac.mp4")
    parser.add_argument("--ordinal", type=int, default=1500)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--metadata-only", action="store_true", help="Run actual native metadata/float/comparison checks without SCK capture or compositor acceptance")
    parser.add_argument("--width", type=int, default=160)
    parser.add_argument("--height", type=int, default=96)
    args = parser.parse_args()
    if args.width <= 0 or args.height <= 0 or args.width * args.height > 512 * 288:
        parser.error("Diagnostic processing dimensions must be positive and at most512×288 pixels")
    output, source = args.output.resolve(), args.source.resolve()
    wrapper = output.with_name(output.name + "-wrapper.json")
    inputs = output.with_name(output.name + "-inputs")
    if output.exists() or wrapper.exists() or inputs.exists():
        raise RuntimeError("Use a new output and adjacent inputs/report path")
    if source.stat().st_size != SOURCE_BYTES or sha(source) != SOURCE_SHA:
        raise RuntimeError("Input is not the pinned original-packet Apple HDR10+ remux")
    inputs.mkdir(parents=True)
    probes = {}
    commands = {
        "packets": ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-show_packets", "-show_data_hash", "sha256", "-of", "json", str(source)],
        "frames": ["ffprobe", "-v", "error", "-threads", "2", "-select_streams", "v:0", "-show_frames", "-show_entries", "frame=pts,duration,pix_fmt,color_range,color_space,color_primaries,color_transfer,chroma_location,width,height:frame_side_data", "-of", "json", str(source)],
    }
    for name, command in commands.items():
        probe = subprocess.run(command, capture_output=True, check=True, timeout=180)
        path = inputs / f"{name}.json"; path.write_bytes(probe.stdout)
        (inputs / f"{name}.stderr").write_bytes(probe.stderr)
        probes[name] = json.loads(probe.stdout, object_pairs_hook=Pairs)
    inventory = parse_inventory(probes["packets"], probes["frames"], args.ordinal)
    model = ROOT / "models/neural-rendering/NeuralRendering.dlssmodel"
    configuration = dict(inventory, sourcePath=str(source), modelPath=str(model), outputPath=str(output),
                         processingWidth=args.width, processingHeight=args.height, metadataOnly=args.metadata_only)
    config_path = inputs / "configuration.json"
    config_path.write_text(json.dumps(configuration, indent=2) + "\n")
    report = {"schemaVersion": 1, "passed": False, "prepareOnly": args.prepare_only,
              "metadataOnly": args.metadata_only, "sckCaptureAttempted": False,
              "source": {"path": str(source), "sha256": SOURCE_SHA, "bytes": SOURCE_BYTES},
              "inventory": inventory, "probeCommands": commands,
              "inputArtifacts": {str(path): sha(path) for path in inputs.iterdir()},
              "catalog": {"path": "config/apple-hdr-samples.json", "sha256": sha(ROOT / "config/apple-hdr-samples.json")}}
    if args.prepare_only:
        report["passed"] = True; wrapper.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"passed": True, "prepareOnly": True, "inventory": inventory})); return 0
    host = ROOT / "artifacts/hdr-source-transition-probe/HDRSourceTransitionProbe"
    capture = ROOT / "artifacts/hdr-capture-probe/hdr-capture-probe"
    paths = [host, ROOT / "artifacts/mpv-build/libmpv.2.dylib", ROOT / ".build/debug/libFrameEngineShared.dylib",
             ROOT / "artifacts/local/lib/libplacebo.dylib", Path("/opt/homebrew/Cellar/molten-vk/1.4.2/lib/libMoltenVK.dylib"),
             model / "weights.safetensors", ROOT / ".build/debug/mlx.metallib"]
    if not args.metadata_only:
        paths.append(capture)
    report["binaries"] = {str(path.resolve()): {"beforeSHA256": sha(path)} for path in paths}
    report["revisions"] = {name: subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
                           for name, path in {"root": ROOT, "mpv": ROOT / "vendor/mpv", "libplacebo": ROOT / "vendor/libplacebo"}.items()}
    report["workingState"] = {name: subprocess.check_output(["git", "-C", str(path), "status", "--short"], text=True)
                              for name, path in {"root": ROOT, "mpv": ROOT / "vendor/mpv"}.items()}
    report["sourceHashes"] = {str(path.relative_to(ROOT)): sha(path) for path in [Path(__file__), ROOT / "tools/HDRSourceTransitionProbe/main.swift", ROOT / "apps/macos/Sources/PiPBufferSnapshot.swift", ROOT / "vendor/mpv/video/out/vulkan/context_mac.m", ROOT / "vendor/mpv/video/out/mac_common.swift", ROOT / "vendor/mpv/demux/lavf_timing.h", ROOT / "vendor/mpv/demux/demux_lavf.c", ROOT / "vendor/mpv/video/filter/metal_hdr_decoder.m"]}
    process = None
    try:
        if not args.metadata_only:
            preflight = subprocess.run([str(capture), "--preflight"], capture_output=True, text=True, timeout=10)
            report["capturePreflight"] = json.loads(preflight.stdout)
            if preflight.returncode:
                raise RuntimeError("Existing screen capture access unavailable; no permission request")
        with output.with_name(output.name + "-host.log").open("x") as log:
            process = subprocess.Popen([str(host), str(config_path)], stdout=log, stderr=subprocess.STDOUT)
            report["hostCommand"] = [str(host), str(config_path)]; report["pid"] = process.pid
            ready_path = output / "retained-enhanced/ready.json"
            deadline = time.monotonic() + 120
            while not ready_path.exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Host did not reach retained enhanced phase")
                time.sleep(.02)
            ready = json.loads(ready_path.read_text()); surface = ready["surface"]
            if surface["pid"] != process.pid:
                raise RuntimeError("Native target process identity differs")
            if not args.metadata_only and (not surface["visible"] or not surface["occlusionVisible"] or surface["miniaturized"]):
                raise RuntimeError("Native capture target is not actually visible")
            capture_code = 0
            if not args.metadata_only:
                capture_path = output / "retained-enhanced/sck-hdr"
                command = [str(capture), "--owner-pid", str(process.pid), "--owner-bundle", "unbundled", "--window-id", str(surface["windowID"]), "--output", str(capture_path), "--frame-reference", str(ready_path)]
                report["sckCaptureAttempted"] = True
                captured = subprocess.run(command, capture_output=True, text=True, timeout=24)
                capture_code = captured.returncode
                report["capture"] = {"command": command, "exitCode": capture_code, "stdout": captured.stdout, "stderr": captured.stderr}
            (output / "capture-complete").touch()
            report["hostExitCode"] = process.wait(timeout=35)
            if capture_code or report["hostExitCode"]:
                raise RuntimeError("Native capture or host failed")
            if not args.metadata_only:
                report["captureReport"] = json.loads((capture_path / "report.json").read_text())
                storage = report["captureReport"]["pixelStorage"]
                report["rawSCKComponents"] = float_statistics(capture_path / storage["file"], storage,
                    scale=1, units="raw captured RGB components; see actual SCK colour/transfer attachments")
                report["rawSCKComponents"]["scope"] = "Whole captured window, including decorations; no optical nits or physical panel inference"
            report["validation"] = validate_session(json.loads((output / "session.json").read_text()), output, args.metadata_only)
            report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
    finally:
        if process is not None and process.poll() is None:
            if output.exists(): (output / "capture-complete").touch()
            try: report["hostExitCode"] = process.wait(timeout=35)
            except subprocess.TimeoutExpired:
                process.terminate(); report["hostExitCode"] = process.wait(timeout=10); report["forcedTermination"] = True
        for path, info in report["binaries"].items(): info["afterSHA256"] = sha(path)
        report["binariesUnchanged"] = all(info["beforeSHA256"] == info["afterSHA256"] for info in report["binaries"].values())
        report["passed"] &= report["binariesUnchanged"]
        if output.exists():
            report["outputArtifacts"] = {str(path.relative_to(output)): {"bytes": path.stat().st_size, "sha256": sha(path)} for path in output.rglob("*") if path.is_file()}
        wrapper.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report.get(key) for key in ("passed", "error", "binariesUnchanged", "hostExitCode")}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
