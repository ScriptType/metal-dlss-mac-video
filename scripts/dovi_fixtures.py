"""Pinned public FATE inputs for profile-specific Dolby Vision diagnostics."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = {
    "8.4": {
        "filename": "dv84.mov", "url": "https://fate-suite.ffmpeg.org/hevc/dv84.mov",
        "sha256": "aaa9289a9755eaebd9962204f24a6acf8a19ff104657a3a79b6b1fa672993721",
        "bytes": 3621742, "profile": 8, "compatibility": 4, "seekSeconds": .7,
        "blankTestVideo": False,
        "provenance": "https://ffmpeg.org/pipermail/ffmpeg-devel/2021-November/287700.html",
    },
    "5": {
        "filename": "dovi-p5.mp4", "url": "https://fate-suite.ffmpeg.org/mov/dovi-p5.mp4",
        "sha256": "11fe599fd77e31e26fbf855bae1cd9931df9f261a0a7b1dce9fad9b236677c4b",
        "bytes": 4182, "profile": 5, "compatibility": 0, "seekSeconds": .125,
        "blankTestVideo": True,
        "provenance": "https://ffmpeg.org/pipermail/ffmpeg-devel/2021-December/289651.html",
    },
}


def source_path(fixture):
    return ROOT / "assets/test-clips/dolbyvision" / fixture["filename"]


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
