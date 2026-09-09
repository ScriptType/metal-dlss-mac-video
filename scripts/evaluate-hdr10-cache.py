#!/usr/bin/env python3
"""Measure the explicit HDR10 cache candidate against absolute-nit float reference pixels.

Only Python's standard library and ffmpeg/ffprobe with libx265 are required. This is a
format qualification tool, not the player encoder. Float cache files remain authoritative.
"""

import argparse
import array
import hashlib
import json
import math
from fractions import Fraction
from pathlib import Path
import shutil
import subprocess
import sys


def pq_encode(nits):
    if not math.isfinite(nits) or not 0 <= nits <= 10000:
        raise ValueError("HDR10 requires explicitly mapped RGB within 0...10000 nits")
    p = (nits / 10000) ** (2610 / 16384)
    return ((3424 / 4096 + (2413 / 128) * p) / (1 + (2392 / 128) * p)) ** (2523 / 32)


def pq_decode(value):
    p = max(0, value) ** (32 / 2523)
    denominator = 2413 / 128 - (2392 / 128) * p
    return 10000 * (max(0, p - 3424 / 4096) / denominator) ** (16384 / 2610)


def word_bytes(values):
    words = array.array("H", values)
    if sys.byteorder != "little":
        words.byteswap()
    return words.tobytes()


def encode_planes(pixels, width, height):
    encoded = [tuple(pq_encode(channel) for channel in rgb) for rgb in pixels]
    luminance = [0.2627 * r + 0.6780 * g + 0.0593 * b for r, g, b in encoded]
    cb = [(rgb[2] - y) / 1.8814 for rgb, y in zip(encoded, luminance)]
    cr = [(rgb[0] - y) / 1.4746 for rgb, y in zip(encoded, luminance)]
    y_words = [round(64 + 876 * value) for value in luminance]
    # Explicit 2x2 box chroma filter, center-sited chroma. This policy is lossy at colour edges.
    chroma = []
    for values in (cb, cr):
        for y in range(0, height, 2):
            for x in range(0, width, 2):
                mean = sum(values[(y + dy) * width + x + dx] for dy in range(2) for dx in range(2)) / 4
                chroma.append(round(512 + 896 * mean))
    return word_bytes(y_words + chroma)


def decode_planes(data, width, height):
    words = array.array("H")
    words.frombytes(data)
    if sys.byteorder != "little":
        words.byteswap()
    count = width * height
    result = []
    for y in range(height):
        for x in range(width):
            luminance = (words[y * width + x] - 64) / 876
            index = (y // 2) * (width // 2) + x // 2
            cb = (words[count + index] - 512) / 896
            cr = (words[count + count // 4 + index] - 512) / 896
            r = luminance + 1.4746 * cr
            b = luminance + 1.8814 * cb
            g = (luminance - 0.2627 * r - 0.0593 * b) / 0.6780
            result.append(tuple(pq_decode(channel) for channel in (r, g, b)))
    return result


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {arguments!r}\n{result.stderr.decode(errors='replace')}")
    return result.stdout


def evaluate(output, ffmpeg, ffprobe):
    output.mkdir(parents=True, exist_ok=True)
    width = height = 64
    count = 12
    grey = [0, 0.0001, 0.01, 0.1, 1, 10, 100, 203, 400, 1000, 4000, 10000]
    patches = [(v, v, v) for v in grey] + [(1000, 0, 0), (0, 1000, 0), (0, 0, 1000), (1000, 1000, 0)]
    reference = [patches[(y // 16) * 4 + x // 16] for y in range(height) for x in range(width)]
    planar = encode_planes(reference, width, height)
    raw_path = output / "bt2020-pq-limited-yuv420p10le.raw"
    raw_path.write_bytes(planar * count)
    floats = array.array("f", [channel for rgb in reference for channel in (*rgb, 1)])
    if sys.byteorder != "little":
        floats.byteswap()
    float_path = output / "reference-linear-bt2020-nits.rgba32f"
    float_path.write_bytes(floats.tobytes() * count)
    frame_average = sum(0.2627 * r + 0.6780 * g + 0.0593 * b for r, g, b in reference) / len(reference)
    cll = f"10000,{math.ceil(frame_average)}"
    report = {
        "policy": "HEVC Main10; BT.2020 nonconstant YCbCr; ST2084 PQ; limited range; center chroma; 2x2 box subsampling",
        "reference_policy": "Float32 little-endian RGBA, linear BT.2020 absolute nits, straight alpha",
        "fixture": {"width": width, "height": height, "frames": count, "fps": "24/1", "patches_nits": patches,
                    "float_sha256": hashlib.sha256(float_path.read_bytes()).hexdigest()},
        "tools": {"ffmpeg": run([ffmpeg, "-version"]).decode().splitlines()[0]},
        "default_cache": "float32; HDR10 remains an evaluated lossy candidate",
        "cases": [],
    }
    for name, encode_options in (("lossless", ["-x265-params", "lossless=1"]), ("crf12", ["-crf", "12"])):
        movie = output / f"hdr10-{name}.mp4"
        decoded = output / f"decoded-{name}.yuv420p10le"
        parameters = ("pools=1:frame-threads=1:hdr10=1:repeat-headers=1:colorprim=9:transfer=16:colormatrix=9:range=limited:"
                      "chromaloc=1:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(100000000,0):"
                      f"max-cll={cll}")
        if name == "lossless":
            parameters += ":lossless=1"
            encode_options = []
        run([ffmpeg, "-v", "error", "-y", "-f", "rawvideo", "-pixel_format", "yuv420p10le", "-video_size", "64x64",
             "-framerate", "24", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
             "-color_range", "tv", "-chroma_sample_location", "center", "-i", str(raw_path),
             "-frames:v", str(count), "-an", "-c:v", "libx265", "-preset", "medium",
             "-pix_fmt", "yuv420p10le", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
             "-color_range", "tv", "-chroma_sample_location", "center", "-x265-params", parameters, *encode_options,
             "-tag:v", "hvc1", "-movflags", "+write_colr", "-video_track_timescale", "24000", str(movie)])
        metadata = json.loads(run([ffprobe, "-v", "error", "-select_streams", "v:0", "-show_streams", "-show_frames",
                                   "-of", "json", str(movie)]))
        stream = metadata["streams"][0]
        expected = {"pix_fmt": "yuv420p10le", "color_range": "tv", "color_space": "bt2020nc",
                    "color_transfer": "smpte2084", "color_primaries": "bt2020", "chroma_location": "center"}
        for key, value in expected.items():
            if stream.get(key) != value:
                raise AssertionError(f"HDR10 metadata mismatch for {key}: {stream.get(key)!r} != {value!r}")
        if len(metadata["frames"]) != count or stream.get("profile") != "Main 10":
            raise AssertionError("Incomplete HDR10 stream or incorrect profile")
        for index, frame in enumerate(metadata["frames"]):
            if frame["pts"] * Fraction(stream["time_base"]) != Fraction(index, 24):
                raise AssertionError("Encoded frame timestamp changed")
            if any(frame.get(key) != value for key, value in expected.items()):
                raise AssertionError("Frame metadata differs from the declared stream policy")
        side_data = metadata["frames"][0].get("side_data_list", [])
        mastering = next((side for side in side_data if side.get("side_data_type") == "Mastering display metadata"), None)
        light = next((side for side in side_data if side.get("side_data_type") == "Content light level metadata"), None)
        if not mastering or not light or light.get("max_content") != 10000:
            raise AssertionError(f"Required static HDR metadata missing or mismatched: {side_data!r}")
        run([ffmpeg, "-v", "error", "-y", "-i", str(movie), "-map", "0:v:0", "-frames:v", str(count), "-pix_fmt", "yuv420p10le",
             "-f", "rawvideo", str(decoded)])
        decoded_bytes = decoded.read_bytes()
        if len(decoded_bytes) != len(planar) * count:
            raise AssertionError("Incomplete decoded segment")
        errors = []
        maximum = 0
        minimum = math.inf
        for index in range(count):
            actual = decode_planes(decoded_bytes[index * len(planar):(index + 1) * len(planar)], width, height)
            errors.extend(abs(a - b) for source, result in zip(reference, actual) for a, b in zip(source, result))
            maximum = max(maximum, max(max(pixel) for pixel in actual))
            minimum = min(minimum, min(min(pixel) for pixel in actual))
        if name == "lossless" and decoded_bytes != planar * count:
            raise AssertionError("Lossless HEVC changed the explicitly quantized YUV reference")
        if maximum < 9000:
            raise AssertionError("Decoded HDR highlights were unexpectedly clipped")
        if max(errors) > (25 if name == "lossless" else 100):
            raise AssertionError("HDR10 round-trip error exceeds the fixture regression limit")
        errors.sort()
        report["cases"].append({"name": name, "encoded_bytes": movie.stat().st_size,
                                 "reference_bytes": float_path.stat().st_size, "metadata": {key: stream.get(key) for key in expected},
                                 "mastering_metadata": mastering, "content_light_metadata": light,
                                 "mean_absolute_channel_error_nits": sum(errors) / len(errors),
                                 "p99_absolute_channel_error_nits": errors[int(len(errors) * 0.99)],
                                 "maximum_absolute_channel_error_nits": max(errors),
                                 "decoded_minimum_nits": minimum, "decoded_peak_nits": maximum,
                                 "quantized_yuv_bit_exact": decoded_bytes == planar * count})
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("artifacts/hdr-cache-evaluation"))
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    parser.add_argument("--ffprobe", default=shutil.which("ffprobe"))
    args = parser.parse_args()
    if not args.ffmpeg or not args.ffprobe:
        parser.error("ffmpeg and ffprobe are required")
    evaluate(args.output, args.ffmpeg, args.ffprobe)


if __name__ == "__main__":
    main()
