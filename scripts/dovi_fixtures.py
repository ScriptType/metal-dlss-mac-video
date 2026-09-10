"""Pinned public inputs and exact source timing for Dolby Vision diagnostics."""
import hashlib
import json
import math
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = {
    "fate-profile84": {
        "id": "fate-profile84",
        "filename": "dv84.mov", "url": "https://fate-suite.ffmpeg.org/hevc/dv84.mov",
        "sha256": "aaa9289a9755eaebd9962204f24a6acf8a19ff104657a3a79b6b1fa672993721",
        "bytes": 3621742, "profile": 8, "compatibility": 4, "seekSeconds": .7,
        "blankTestVideo": False,
        "provenance": "https://ffmpeg.org/pipermail/ffmpeg-devel/2021-November/287700.html",
    },
    "fate-profile5": {
        "id": "fate-profile5",
        "filename": "dovi-p5.mp4", "url": "https://fate-suite.ffmpeg.org/mov/dovi-p5.mp4",
        "sha256": "11fe599fd77e31e26fbf855bae1cd9931df9f261a0a7b1dce9fad9b236677c4b",
        "bytes": 4182, "profile": 5, "compatibility": 0, "seekSeconds": .125,
        "blankTestVideo": True,
        "provenance": "https://ffmpeg.org/pipermail/ffmpeg-devel/2021-December/289651.html",
    },
    "apple-profile5": {
        "id": "apple-profile5", "filename": "apple-advanced-dolby-profile5-aac.mp4",
        "sha256": "69bbb93355cb91d69eefe7f24f6525e61670aa3ae25bbfb4a546a19a0358e110",
        "bytes": 42855591, "profile": 5, "compatibility": 0, "seekSeconds": 12,
        "blankTestVideo": False, "catalogAsset": "dolby-profile5",
        "provenance": "https://developer.apple.com/streaming/examples/advanced-stream-dv-atmos.html",
    },
}


FATE_BY_PROFILE = {"8.4": FIXTURES["fate-profile84"], "5": FIXTURES["fate-profile5"]}


def select_fixture(identifier=None, profile=None):
    fixture = FIXTURES[identifier] if identifier else FATE_BY_PROFILE[profile or "8.4"]
    if profile and fixture["profile"] != FATE_BY_PROFILE[profile]["profile"]:
        raise ValueError("Fixture and requested Dolby profile disagree")
    return fixture


def source_path(fixture):
    folder = "apple-hdr" if fixture.get("catalogAsset") else "dolbyvision"
    return ROOT / "assets/test-clips" / folder / fixture["filename"]


def source_catalog(fixture):
    if not fixture.get("catalogAsset"):
        return None
    path = ROOT / "config/apple-hdr-samples.json"
    catalog = json.loads(path.read_text())
    asset = catalog["assets"][fixture["catalogAsset"]]
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "publisher": catalog["publisher"], "usage": catalog["usage"],
            "playlist": asset["playlist"], "concatenatedSHA256": asset["concatenatedSHA256"]}


def exact_inventory(probe, fixture):
    """Use presentation order, independent of packet decode order and float FPS."""
    video = next(stream for stream in probe["streams"] if stream["codec_type"] == "video")
    timebase = Fraction(video["time_base"])
    frames = sorted((int(packet["pts"]), int(packet["duration"])) for packet in probe["packets"]
                    if packet["stream_index"] == video["index"])
    if not frames or len({pts for pts, _ in frames}) != len(frames) or any(duration <= 0 for _, duration in frames):
        raise ValueError("Expected unique presentation timestamps and positive packet durations")
    if fixture["id"] == "apple-profile5" and (len(frames), frames[0][0], timebase) != (2360, 240000, Fraction(1, 24000)):
        raise ValueError("Apple video presentation inventory differs from the pinned source")
    targets = []
    for seconds in (12, 42, 72):
        threshold = frames[0][0] * timebase + seconds
        target = next((frame for frame in frames if frame[0] * timebase >= threshold), None)
        if target is None:
            raise ValueError("Representative seek target exceeds the source inventory")
        targets.append({"pts": target[0], "duration": target[1]})
    return {"fixtureID": fixture["id"], "sourceSHA256": fixture["sha256"],
            "timebaseNumerator": timebase.numerator, "timebaseDenominator": timebase.denominator,
            "formatStartSeconds": probe["format"]["start_time"],
            "frames": [{"pts": pts, "duration": duration} for pts, duration in frames], "targets": targets}


def native_timeline_offset(demuxer_start, rebased, decoder_seconds, player_seconds):
    """Validate the native decoder/player pair and return file-to-decoder offset.

    mpv rebases demux packets before decoding. Its exact displayed-source-pts
    field therefore belongs to that decoder timeline. Recover original file
    PTS by subtracting this offset, then verify against the packet inventory.
    """
    if type(demuxer_start) not in (int, float) or not math.isfinite(demuxer_start):
        raise ValueError("Native demuxer start is unavailable or nonfinite")
    if type(rebased) is not bool:
        raise ValueError("Native rebase-start-time is unavailable")
    offset = -Fraction(str(demuxer_start)) if rebased else Fraction(0)
    if (decoder_seconds is None or type(player_seconds) not in (int, float) or not math.isfinite(player_seconds)
            or abs(float(decoder_seconds) - player_seconds) > 1e-6):
        raise ValueError("Held exact decoder PTS does not match the native player timeline")
    return offset


def verify_source(path, fixture):
    if path.stat().st_size != fixture["bytes"]:
        raise ValueError("Pinned Dolby fixture byte count differs")
    checksum = hashlib.sha256(path.read_bytes()).hexdigest()
    if checksum != fixture["sha256"]:
        raise ValueError("Pinned Dolby fixture SHA-256 differs")
    return checksum


def verify_metadata(probe, fixture):
    videos = [stream for stream in probe["streams"] if stream["codec_type"] == "video"]
    if len(videos) != 1:
        raise ValueError("Expected one pinned Dolby video stream")
    stream = videos[0]
    config = next((value for value in stream.get("side_data_list", [])
                   if value["side_data_type"] == "DOVI configuration record"), {})
    if (config.get("dv_profile"), config.get("dv_bl_signal_compatibility_id")) != (fixture["profile"], fixture["compatibility"]):
        raise ValueError("Actual Dolby profile/compatibility does not match the selected fixture")
    if not 0 < fixture["seekSeconds"] < float(stream["duration"]):
        raise ValueError("Fixture seek must be strictly inside the actual stream duration")
    frames = probe.get("frames", [])
    if not frames:
        raise ValueError("Software probe decoded no frame")
    for frame in frames:
        side = frame.get("side_data_list", [])
        if not any(value["side_data_type"] == "Dolby Vision RPU Data" for value in side):
            raise ValueError("Decoded frame lacks RPU data")
        parsed = next((value for value in side if value["side_data_type"] == "Dolby Vision Metadata"), None)
        if parsed is None:
            raise ValueError("Decoded frame lacks parsed Dolby Vision metadata")
        if fixture["profile"] == 5 and (parsed.get("vdr_rpu_profile"), parsed.get("bl_video_full_range_flag"), parsed.get("disable_residual_flag")) != (0, 1, 1):
            raise ValueError("Decoded RPU is not the pinned full-range single-layer Profile 5 interpretation")
    return {"configuration": config, "decodedFramesWithParsedRPU": len(frames), "duration": stream["duration"],
            "timeBase": stream["time_base"], "seekSeconds": fixture["seekSeconds"]}
