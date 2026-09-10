#!/usr/bin/env python3
"""Prepare pinned Apple HDR10+ frames as a bounded CPU Float32 reference.

Software decode and explicit zscale produce BT.2020 absolute nits. The default
uses linear 2x2 BOX reduction; --full-resolution retains decoded geometry.
This numerical derivative does not qualify native import, dynamic display
tone mapping, physical display accuracy or neural image quality.
"""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import threading
import time

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
AUDIT = ROOT / "docs/evidence/apple-natural-hdr-source.json"
PROBE_NAME = "artifacts/public-hdr-source-audit/video-all-frames-probe.json"
WIDTH, HEIGHT = 1920, 1080
FIRST, COUNT, PRELUDE = 1488, 56, 8
FRAME_BYTES = WIDTH * HEIGHT * 12


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_pin(path, pin):
    if path.stat().st_size != pin["bytes"] or digest(path) != pin["sha256"]:
        raise ValueError(f"Pinned input changed: {path}")


def select_frames(frames):
    if len(frames) != 2360:
        raise ValueError("Pinned decoded inventory must contain 2360 frames")
    selected = frames[FIRST:FIRST + COUNT]
    required = {"width": WIDTH, "height": HEIGHT, "pix_fmt": "yuv420p10le", "color_range": "tv",
        "color_space": "bt2020nc", "color_primaries": "bt2020", "color_transfer": "smpte2084",
        "chroma_location": "topleft", "duration": 1001}
    for index, frame in enumerate(selected, FIRST):
        if any(frame.get(key) != value for key, value in required.items()):
            raise ValueError(f"Unsupported or changed decoded metadata at frame {index}")
        if frame.get("pts") != 241001 + index * 1001:
            raise ValueError(f"Exact original source timestamp changed at frame {index}")
        types = {item.get("side_data_type") for item in frame.get("side_data_list", [])}
        if not {"Mastering display metadata", "Content light level metadata",
                "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"} <= types:
            raise ValueError(f"Source HDR metadata is missing at frame {index}")
    return selected


def zscale(npl=1):
    return ("zscale=filter=bilinear:chromalin=topleft:rin=limited:pin=bt2020:"
            "tin=smpte2084:min=bt2020nc:p=bt2020:t=linear:m=gbr:r=full:"
            f"npl={npl}:agamma=false:dither=none,format=gbrpf32le")


def unpack_gbr(data, width, height):
    if len(data) != width * height * 12:
        raise ValueError("Truncated or excessive planar Float32 frame")
    planes = np.frombuffer(data, dtype="<f4").reshape(3, height, width)
    rgb = np.stack((planes[2], planes[0], planes[1]), axis=2)
    if not np.isfinite(rgb).all():
        raise ValueError("Nonfinite linear Float32 frame")
    return rgb


def box_half(rgb):
    h, w, channels = rgb.shape
    if h % 2 or w % 2 or channels != 3:
        raise ValueError("BOX reduction requires even RGB geometry")
    # Accumulate in Float64, then store once as Float32. No range clamp,
    # reference-white division, transfer function or encoded-space resize.
    return rgb.astype(np.float64).reshape(h // 2, 2, w // 2, 2, 3).mean(axis=(1, 3)).astype("<f4")


def reference_pixels(rgb, full_resolution=False):
    return rgb if full_resolution else box_half(rgb)


def statistics(rgb):
    return {"minimumNits": [float(value) for value in rgb.min(axis=(0, 1))],
        "maximumNits": [float(value) for value in rgb.max(axis=(0, 1))],
        "negativeComponents": int(np.count_nonzero(rgb < 0)),
        "above10000Components": int(np.count_nonzero(rgb > 10000))}


def independent_reference(y, cb, cr):
    """Analytic BT.2020 NCL/PQ reference with scalar bilinear chroma taps."""
    height, width = y.shape
    def sample(plane, x, row):
        x0, y0 = x // 2, row // 2
        x1, y1 = min(x0 + 1, plane.shape[1] - 1), min(y0 + 1, plane.shape[0] - 1)
        fx, fy = (x % 2) / 2, (row % 2) / 2
        return ((1-fy) * ((1-fx)*plane[y0, x0]+fx*plane[y0, x1])
                + fy * ((1-fx)*plane[y1, x0]+fx*plane[y1, x1]))
    result = np.empty((height, width, 3), dtype=np.float64)
    for row in range(height):
        for x in range(width):
            luma = (float(y[row, x]) - 64) / 876
            u, v = (sample(cb, x, row)-512)/896, (sample(cr, x, row)-512)/896
            red, blue = luma + 1.4746*v, luma + 1.8814*u
            green = (luma-.2627*red-.0593*blue)/.6780
            encoded = np.maximum([red, green, blue], 0)
            power = np.power(encoded, 32/2523)
            result[row, x] = 10000*np.power(np.maximum(power-3424/4096, 0)/(2413/128-2392/128*power), 16384/2610)
    return result


def conversion_controls(ffmpeg):
    y = np.tile(np.array([64, 128, 509, 574, 723, 940, 1000, 1023], dtype="<u2"), (8, 1))
    neutral = np.full((4, 4), 512, dtype="<u2")
    gradient = np.arange(16, dtype="<u2").reshape(4, 4)*2 + 497
    patterns = [("quantized-gray-and-superwhite", y, neutral, neutral),
                ("top-left-chroma-gradient", np.full((8, 8), 630, dtype="<u2"), gradient, gradient[::-1].copy())]
    records = []
    for name, luma, cb, cr in patterns:
        payload = b"".join(plane.astype("<u2").tobytes() for plane in (luma, cb, cr))
        base = [str(ffmpeg), "-v", "error", "-nostdin", "-threads", "1", "-f", "rawvideo",
            "-pixel_format", "yuv420p10le", "-video_size", "8x8", "-framerate", "1", "-i", "pipe:0",
            "-frames:v", "1", "-an", "-vf"]
        def convert(npl):
            command = base + [zscale(npl), "-pix_fmt", "gbrpf32le", "-f", "rawvideo", "pipe:1"]
            result = subprocess.run(command, input=payload, capture_output=True, check=True, timeout=20)
            return unpack_gbr(result.stdout, 8, 8)
        converted, expected = convert(1), independent_reference(luma, cb, cr)
        # Same precise-conversion arithmetic bound as the independent audit.
        # Values outside nominal PQ are retained, with their larger Float32
        # inverse-transfer error reported separately; no physical claim.
        np.testing.assert_allclose(converted, expected, rtol=5e-5, atol=.0001)
        scaled = convert(203).astype(np.float64)*203
        np.testing.assert_allclose(converted, scaled, rtol=1e-5, atol=.004)
        nominal = expected <= 10000
        records.append({"pattern": name, "maximumAbsoluteErrorNits": float(np.abs(converted-expected).max()),
            "nominalDomainMaximumAbsoluteErrorNits": float(np.abs(converted-expected)[nominal].max()),
            "above10000Components": int(np.count_nonzero(converted > 10000)),
            "maximumNPLScalingErrorNits": float(np.abs(converted-scaled).max()),
            "minimumNits": float(converted.min()), "maximumNits": float(converted.max())})
    return {"passed": True, "scope": "Synthetic CPU transfer normalization, channel ordering and top-left bilinear checks; no media/display qualification",
            "relativeTolerance": 5e-5, "absoluteToleranceNits": .0001,
            "boundSource": "Independent precise-conversion audit artifacts/apple-temporal-conversion-audit/report.json",
            "earlierStrictExtendedDomainControl": "artifacts/apple-temporal-preparation-controls-1/strict-superwhite-failure.log; rtol=1e-5/atol=.004 was not met by code 1000, outside nominal PQ. Numerical difference retained, not a clipping or scale failure.",
            "patterns": records}


def verify_showinfo(text, selected):
    configurations = re.findall(r"config in time_base:\s*(\d+)/(\d+)(?=,|\s|$)", text)
    if not configurations or any(int(denominator) == 0 or
            Fraction(int(numerator), int(denominator)) != Fraction(1, 24000)
            for numerator, denominator in configurations):
        raise ValueError("Decoder did not retain original 1/24000 timebase in every configuration")
    matches = re.findall(r"n:\s*\d+\s+pts:\s*(-?\d+)\s+pts_time:\s*[^\s]+\s+duration:\s*(-?\d+)", text)
    actual = [(int(pts), int(duration)) for pts, duration in matches]
    expected = [(frame["pts"], frame["duration"]) for frame in selected]
    if actual != expected:
        raise ValueError("Actual decoder showinfo PTS/duration differs from the pinned original inventory")
    return [{"pts": {"value": pts, "timescale": 24000}, "duration": {"value": duration, "timescale": 24000}}
            for pts, duration in actual]


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        block = stream.read(count-len(result))
        if not block:
            raise ValueError("Decoder output ended before the complete reference frame")
        result.extend(block)
    return bytes(result)


def decoder_watchdog(process, report, timeout=300):
    def expire():
        report["decoderDeadlineExpired"] = True
        if process.poll() is None: process.kill()
    timer = threading.Timer(timeout, expire)
    timer.daemon = True
    timer.start()
    return timer


def require_new_output(path):
    if path.exists() or path.is_symlink():
        raise FileExistsError("Use a new output directory; retained references are never overwritten")


def frozen_files(ffmpeg):
    files = [ffmpeg, Path("/opt/homebrew/opt/zimg/lib/libzimg.2.dylib")]
    for library in ("libavcodec", "libavformat", "libavfilter", "libavutil", "libswscale"):
        files.extend(sorted((ffmpeg.parent.parent / "lib").glob(library+".[0-9]*.dylib")))
    files += [ROOT/name for name in (".build/debug/hdr-benchmark", ".build/debug/libFrameEngineShared.dylib",
        ".build/debug/mlx.metallib", "artifacts/mpv-build/mpv", "artifacts/mpv-build/libmpv.2.dylib",
        "models/neural-rendering/NeuralRendering.dlssmodel/manifest.json",
        "models/neural-rendering/NeuralRendering.dlssmodel/weights.safetensors",
        "scripts/prepare-apple-hdr-reference.py", "scripts/review-reference-sequence.py")]
    # Existing runtime/model artifacts are pinned for the coordinated local
    # capture, but CPU preparation also works before an app has been built.
    return {str(path.resolve(strict=True)): digest(path) for path in files if path.is_file()}


def audit_pin(path, ffmpeg_hash):
    if path is None: return None
    data = json.loads(path.read_text())
    if data.get("passed") is not True or data.get("ffmpeg", {}).get("sha256") != ffmpeg_hash:
        raise ValueError("Independent conversion audit failed or used a different converter binary")
    return {"path": str(path.resolve()), "sha256": digest(path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, default=Path("/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"))
    parser.add_argument("--conversion-audit", type=Path, help="Optional independent report; must pass and match the converter binary")
    parser.add_argument("--full-resolution", action="store_true",
                        help="Retain 1920x1080 decoded RGB instead of the default 960x540 linear BOX reduction")
    args = parser.parse_args()
    reference_width, reference_height = (WIDTH, HEIGHT) if args.full_resolution else (WIDTH//2, HEIGHT//2)
    output = args.output.absolute()
    try: require_new_output(output)
    except FileExistsError as error: parser.error(str(error))
    output = output.resolve()
    audit = json.loads(AUDIT.read_text())
    source_pin = audit["hdr10plus"]["file"]
    probe_pin = next(item for item in audit["artifacts"] if item["path"] == PROBE_NAME)
    source, probe = ROOT / source_pin["path"], ROOT / PROBE_NAME
    verify_pin(source, source_pin); verify_pin(probe, probe_pin)
    selected = select_frames(json.loads(probe.read_text())["frames"])
    ffmpeg = args.ffmpeg.resolve(strict=True)
    ffmpeg_hash = digest(ffmpeg)
    frozen = frozen_files(ffmpeg)
    filter_chain = f"select=between(n\\,{FIRST}\\,{FIRST+COUNT-1}),showinfo,{zscale()}"
    command = [str(ffmpeg), "-v", "info", "-nostdin", "-hwaccel", "none", "-threads", "2", "-filter_threads", "1", "-copyts",
        "-noautorotate", "-i", str(source), "-map", "0:v:0", "-an", "-sn", "-dn", "-vf", filter_chain,
        "-frames:v", str(COUNT), "-fps_mode", "passthrough", "-pix_fmt", "gbrpf32le", "-f", "rawvideo", "pipe:1"]
    output.mkdir(parents=True)
    report = {"complete": False, "command": command, "source": source_pin, "ffmpegSHA256": ffmpeg_hash,
              "frozenFileSHA256": frozen, "converterSHA256": digest(Path(__file__))}
    started = time.monotonic(); process = None; timer = None
    try:
        independent = audit_pin(args.conversion_audit, ffmpeg_hash)
        controls = conversion_controls(ffmpeg)
        report["conversionControls"] = controls
        # Preserve raw bytes, including repeated ffprobe JSON keys. Parsed
        # per-frame fields are a projection; the compressed source is authoritative.
        (output / "source-frame-probe.raw.json").write_bytes(probe.read_bytes())
        frames = []
        with (output / "ffmpeg.log").open("x") as log:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=log)
            timer = decoder_watchdog(process, report)
            for index, metadata in enumerate(selected, FIRST):
                raw = read_exact(process.stdout, FRAME_BYTES)
                rgb = unpack_gbr(raw, WIDTH, HEIGHT)
                reference = reference_pixels(rgb, args.full_resolution)
                data = reference.tobytes()
                filename = f"frame-{index:05d}.rgb32f"
                with (output / filename).open("xb") as frame_file: frame_file.write(data)
                frames.append({"sourceFrameIndex": index, "path": filename,
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "pts": {"value": metadata["pts"], "timescale": 24000},
                    "duration": {"value": metadata["duration"], "timescale": 24000},
                    "ffprobeMetadataProjection": metadata,
                    "fullResolutionPlanarGBRFloatSHA256": hashlib.sha256(raw).hexdigest(),
                    "beforeResize": statistics(rgb), "afterResize": statistics(reference),
                    "inspectionPrelude": index < FIRST+PRELUDE})
            if process.stdout.read(1): raise ValueError("Decoder emitted extra reference frames")
            process.stdout.close()
            if process.wait(timeout=30) != 0: raise ValueError("Reference decoder failed; see retained ffmpeg.log")
        actual = verify_showinfo((output / "ffmpeg.log").read_text(), selected)
        verify_pin(source, source_pin); verify_pin(probe, probe_pin)
        if digest(ffmpeg) != ffmpeg_hash: raise ValueError("Converter binary changed during preparation")
        if any(digest(path) != sha for path, sha in frozen.items()):
            raise ValueError("A pinned converter, source, model or runtime binary changed during preparation")
        if independent is not None and digest(independent["path"]) != independent["sha256"]:
            raise ValueError("Independent audit changed during preparation")
        provenance = {"asset": "apple-hdr10plus-aac", "source": source_pin, "publisher": audit["publisher"],
            "sourceAudit": str(AUDIT), "sourceAuditSHA256": digest(AUDIT), "sourceCatalog": audit["sourceCatalog"],
            "converterSHA256": digest(Path(__file__)), "ffmpeg": str(ffmpeg), "ffmpegSHA256": ffmpeg_hash,
            "frozenFileSHA256": frozen, "independentConversionAudit": independent,
            "ffmpegVersion": subprocess.check_output([str(ffmpeg), "-version"], text=True),
            "pythonVersion": platform.python_version(), "numpyVersion": np.__version__,
            "sourceGeometry": [WIDTH, HEIGHT], "referenceGeometry": [reference_width, reference_height],
            "spatialReduction": "none" if args.full_resolution else "Float64 2x2 linear BOX mean then Float32 storage",
            "sourceMetadata": "Per-frame parsed ffprobe fields are a projection; repeated JSON keys remain in the hashed raw sidecar. Pinned compressed source is authoritative.",
            "rawMetadataSidecar": "source-frame-probe.raw.json", "rawMetadataSHA256": probe_pin["sha256"],
            "dynamicHDR": "Source contains SMPTE2094-40. Dynamic display tone mapping is not applied or attached to this linear numerical reference.",
            "pqNegativeDomain": "Negative encoded components floor to 0 during PQ inverse, matching native import. The zscale output does not expose pre-EOTF negative-code counts; linear pre/post-resize counts are explicit.",
            "conversion": ("Software HEVC decode; explicit limited 10-bit BT2020 NCL/top-left bilinear chroma; PQ to absolute nits with zscale npl=1/agamma=false; planar G,B,R reordered to RGB; "
                + ("full decoded Float32 RGB retained without spatial reduction" if args.full_resolution else "Float64 2x2 linear BOX mean then Float32 storage")
                + ". No /203, gamut conversion or post-conversion clamp."),
            "filter": filter_chain, "conversionControls": controls,
            "timing": "Original file PTS/duration verified against actual pre-conversion showinfo; no player rebasing, input seek, start_at_zero or CFR duplication",
            "firstSourceFrameIndex": FIRST, "lastSourceFrameIndex": FIRST+COUNT-1,
            "inspectionPreludeFrames": PRELUDE, "reviewSourceFrameRange": [FIRST+PRELUDE, FIRST+COUNT-1],
            "preroll": "All 56 frames retained and processed, including 8 explicit inspection-prelude frames; first supplied frame has cold history",
            "scope": ("Full-resolution" if args.full_resolution else "Downsampled")
                + " natural HDR temporal input; CPU conversion is independently tolerance-checked, not native-import bit identity, neural quality or calibrated display evidence"}
        manifest = {"schemaVersion": 1, "width": reference_width, "height": reference_height,
            "layout": "RGB float32 little-endian top-to-bottom", "primaries": "BT.2020", "transfer": "linear",
            "units": "cd/m2", "provenance": provenance, "frames": frames}
        encoded = json.dumps(manifest, indent=2, allow_nan=False)+"\n"
        if len(encoded.encode()) > 1024**2: raise ValueError("Reference manifest exceeds existing 1MiB bound")
        with (output / "manifest.json").open("x") as result: result.write(encoded)
        report.update(complete=True, frames=COUNT, actualDecoderTimings=actual,
            elapsedSeconds=time.monotonic()-started, inputFloatBytes=COUNT*reference_width*reference_height*12,
            futureFourViewBytes=COUNT*reference_width*reference_height*48, manifestSHA256=digest(output/"manifest.json"))
    except BaseException as error:
        report["failure"] = str(error)
        raise
    finally:
        if timer is not None: timer.cancel()
        if process is not None and process.poll() is None:
            process.terminate()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=10)
        if process is not None and process.stdout is not None: process.stdout.close()
        report["elapsedSeconds"] = time.monotonic()-started
        with (output / "preparation.json").open("x") as result: json.dump(report,result,indent=2);result.write("\n")
    print(output / "manifest.json")


if __name__ == "__main__":
    main()
