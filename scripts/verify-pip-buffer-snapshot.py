#!/usr/bin/env python3
"""Verify retained/exported buffer identity without qualifying system PiP presentation."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct


def require(value, message):
    if not value:
        raise RuntimeError(message)


def verify(session):
    base = session / "buffer-snapshot"
    capture = json.loads((base / "report.json").read_text())
    run = json.loads((session / "session.json").read_text())
    checks = []
    require(run["setupAndTeardownPassed"] and run["exitCode"] == 0 and run["binariesUnchanged"],
            "Capture session failed or binaries changed")
    checks.append("Session exited cleanly with unchanged measured binaries")
    require(capture["captured"] and capture["leaseCurrentAfter"], "No current retained-frame snapshot")
    before, after = capture["stateBefore"], capture["stateAfter"]
    require(all(before[key] == after[key] for key in ("sourcePTS", "generation", "revision")) and
            before["clockRate"] == after["clockRate"] == 0, "Paused exact frame identity changed during readback")
    checks.append("Exact source PTS/generation/revision stayed current with a held clock")
    payloads = []
    for key in ("exported", "displayed"):
        value = capture[key]
        require(value["available"] and value["pixelsCopied"] and value["pixelFormat"] == 1380411457 and
                not value["planar"], "Missing packed RGBA16F buffer")
        width, height, stride = value["width"], value["height"], value["bytesPerRow"]
        require(0 < width <= 4096 and 0 < height <= 2160 and width * 8 <= stride <= 131072 and
                stride * height <= 64 * 1024 * 1024, "Invalid diagnostic buffer size")
        description = value["formatDescription"]
        require(description["dimensions"] == description["presentationDimensions"] == [width, height] and
                description["cleanApertureTopLeft"] == [0, 0, width, height], "Non-full-frame presentation geometry")
        path = base / value["file"]
        require(path.parent.resolve() == base.resolve() and path.stat().st_size == stride * height,
                "Unexpected pixel payload path/length")
        raw = path.read_bytes()
        require(hashlib.sha256(raw).hexdigest() == value["sha256"], "Pixel checksum mismatch")
        payloads.append(b"".join(raw[y * stride:y * stride + width * 8] for y in range(height)))
    require(capture["submittedFormatDescription"] == capture["exported"]["formatDescription"],
            "Actual enqueued description differs from retained pixel description")
    checks.append("CV and actual sample descriptions preserve full-frame dimensions and aperture")
    require(payloads[0] == payloads[1], "Exported and public displayed component bytes differ")
    require(capture["exported"]["attachmentsPropagating"] == capture["displayed"]["attachmentsPropagating"],
            "Exported and displayed propagated attachments differ")
    checks.append("Exported and public displayed component bytes and colour attachments are identical")
    minima, maxima = [math.inf] * 4, [-math.inf] * 4
    above_one, nonfinite, nonopaque = 0, 0, 0
    for pixel in struct.iter_unpack("<eeee", payloads[0]):
        for channel, value in enumerate(pixel):
            nonfinite += not math.isfinite(value)
            minima[channel] = min(minima[channel], value)
            maxima[channel] = max(maxima[channel], value)
        above_one += sum(value > 1 for value in pixel[:3])
        nonopaque += pixel[3] != 1
    require(nonfinite == 0 and nonopaque == 0, "Fixture contains nonfinite or nonopaque pixels")
    checks.append("Captured fixture components are finite with opaque alpha")
    return {"session": str(session), "bufferIdentityPassed": True, "checks": checks,
            "sourcePTS": before["sourcePTS"], "generation": before["generation"], "revision": before["revision"],
            "componentSHA256": hashlib.sha256(payloads[0]).hexdigest(), "layer": capture["layer"],
            "numeric": {"minimumRGBA": minima, "maximumRGBA": maxima, "rgbComponentsAboveOne": above_one,
                        "nonfiniteComponents": nonfinite, "nonopaquePixels": nonopaque},
            "systemPictureInPictureQualified": False,
            "scope": "Retained/exported versus public renderer pixel identity; system compositor geometry, colour and physical HDR are separate"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    args = parser.parse_args()
    result = verify(args.session.resolve())
    (args.session / "buffer-snapshot" / "verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"bufferIdentityPassed": result["bufferIdentityPassed"], "checks": len(result["checks"]),
                      "systemPictureInPictureQualified": False}))


if __name__ == "__main__":
    main()
