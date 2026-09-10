#!/usr/bin/env python3
"""Make a bounded raw-float temporal reference from pinned publisher EXR frames.

Run with uv run --frozen --group reference. The selected P3-D65/PQ
interpretation is explicit because these EXR headers omit chromaticities.
"""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path

import numpy as np
import OpenEXR
from PIL import Image, __version__ as PIL_VERSION

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "config/open-content.json"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def rgb_to_xyz(primaries):
    xy = np.array(primaries, dtype=np.float64)
    columns = np.stack((xy[:, 0] / xy[:, 1], np.ones(3),
                        (1 - xy.sum(axis=1)) / xy[:, 1]))
    white = np.array([.3127 / .3290, 1, (1 - .3127 - .3290) / .3290])
    return columns @ np.diag(np.linalg.solve(columns, white))


def decode_pq(encoded, extend_domain=False):
    if not np.isfinite(encoded).all():
        raise ValueError("Nonfinite PQ input")
    if not extend_domain and (np.any(encoded < 0) or np.any(encoded > 1)):
        raise ValueError("PQ input outside0…1 requires the explicit diagnostic domain extension")
    power = np.abs(encoded.astype(np.float64)) ** (32 / 2523)
    denominator = 2413 / 128 - (2392 / 128) * power
    if np.any(denominator <= 0):
        raise ValueError("PQ extrapolation has a nonpositive denominator")
    # The numerator's black floor is part of the PQ inverse. The optional
    # diagnostic extension is analytic above1 and odd-symmetric below0.
    return np.sign(encoded) * 10000 * (np.maximum(power - 3424 / 4096, 0) / denominator) ** (16384 / 2610)


def time_value(value):
    return {"value": value.numerator, "timescale": value.denominator}


def stats(array):
    return {"minimum": float(array.min()), "maximum": float(array.max()),
            "negativeComponents": int(np.count_nonzero(array < 0)),
            "above10000Components": int(np.count_nonzero(array > 10000))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-directory", type=Path, default=ROOT / "assets/test-clips/open-content/cosmos-exr-dial")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--width", type=int, default=320)
    parser.add_argument("--height", type=int, default=134)
    parser.add_argument("--assume-p3-d65", action="store_true",
                        help="Explicitly select D65 for the publisher's untagged P3/PQ RGB grade")
    parser.add_argument("--extend-pq-domain", action="store_true",
                        help="Use a diagnostic odd-symmetric/analytic PQ extension outside0…1 without clipping")
    args = parser.parse_args()
    if not args.assume_p3_d65:
        parser.error("The EXR omits its white point; --assume-p3-d65 records the selected interpretation")
    if not 16 <= args.width <= 512 or not 16 <= args.height <= 288:
        parser.error("Use bounded dimensions16…512 by16…288")
    output = args.output.resolve()
    if output.exists():
        parser.error("Use a new output directory; prior references are never overwritten")
    catalog = json.loads(CATALOG.read_text())
    asset = catalog["assets"]["cosmos-exr-dial"]
    members = asset["members"]
    if not 1 <= len(members) <= 120:
        raise ValueError("Reference inventory must contain1…120 frames")
    source = args.source_directory.resolve()
    # Verify the complete source inventory before creating a partial derivative.
    for member in members:
        path = source / member["filename"]
        if path.stat().st_size != member["bytes"] or digest(path) != member["sha256"]:
            raise ValueError("Unverified publisher source: " + member["filename"])
    matrix = np.linalg.solve(rgb_to_xyz([[.708, .292], [.170, .797], [.131, .046]]),
                             rgb_to_xyz([[.680, .320], [.265, .690], [.150, .060]]))
    rate = Fraction(asset["embeddedFramesPerSecond"]["value"], asset["embeddedFramesPerSecond"]["timescale"])
    first_index = members[0]["sourceFrameIndex"]
    output.mkdir(parents=True)
    frames = []
    for member in members:
        index = member["sourceFrameIndex"]
        with OpenEXR.File(str(source / member["filename"])) as image:
            header = image.header()
            if len(image.parts) != 1 or set(image.channels()) != {"RGB"}:
                raise ValueError("Expected one RGB EXR part")
            rgb = image.channels()["RGB"].pixels
            if rgb.dtype != np.float16 or rgb.shape != (858, 2048, 3):
                raise ValueError("Publisher RGB HALF geometry changed")
            if header.get("framesPerSecond") != rate or header.get("pixelAspectRatio") != 1:
                raise ValueError("Publisher timing/aspect metadata changed")
            if "chromaticities" in header:
                raise ValueError("New colour metadata requires inspection before applying the selected assumption")
            if not np.array_equal(header["dataWindow"][0], [0, 0]) or not np.array_equal(header["dataWindow"][1], [2047, 857]):
                raise ValueError("Unexpected source data window")
            encoded_above_one = int(np.count_nonzero(rgb > 1))
            encoded_negative = int(np.count_nonzero(rgb < 0))
            linear = decode_pq(rgb, args.extend_pq_domain) @ matrix.T
            original_stats = stats(linear)
            resized = np.stack([np.asarray(Image.fromarray(linear[:, :, c].astype(np.float32)).resize(
                (args.width, args.height), resample=Image.Resampling.BOX), dtype=np.float32)
                for c in range(3)], axis=2).astype("<f4")
            if not np.isfinite(resized).all():
                raise ValueError("Nonfinite derived reference")
            filename = f"frame-{index:05d}.rgb32f"
            payload = resized.tobytes(order="C")
            (output / filename).write_bytes(payload)
            frames.append({"sourceFrameIndex": index, "path": filename,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "pts": time_value(Fraction(index - first_index, 1) / rate),
                "duration": time_value(1 / rate),
                "sourcePTSFromFrameIndex": time_value(Fraction(index, 1) / rate),
                "sourceSHA256": member["sha256"], "encodedComponentsAboveOne": encoded_above_one,
                "encodedNegativeComponents": encoded_negative,
                "beforeResize": original_stats, "afterResize": stats(resized)})
    manifest = {"schemaVersion": 1, "width": args.width, "height": args.height,
        "layout": "RGB float32 little-endian top-to-bottom", "primaries": "BT.2020",
        "transfer": "linear", "units": "cd/m2", "frames": frames,
        "provenance": {"asset": "cosmos-exr-dial", "title": asset["title"], "attribution": asset["attribution"],
            "catalogSource": catalog["catalogSource"], "license": catalog["license"],
            "sourceCatalogSHA256": digest(CATALOG), "converterSHA256": digest(Path(__file__)),
            "openEXRVersion": OpenEXR.__version__, "numpyVersion": np.__version__, "pillowVersion": PIL_VERSION,
            "sourceGeometry": [2048, 858], "sourceStorage": "RGB HALF EXR, read without colour conversion",
            "selectedInterpretation": "Publisher-declared P3/PQ RGB with explicitly assumed D65 white; no embedded chromaticities or transfer",
            "p3D65ToBT2020LinearMatrix": matrix.tolist(),
            "conversion": "PQ inverse to nits, linear P3-D65 to BT.2020-D65, channel-wise floating-point box-average resize; no component clipping",
            "extendedCodePolicy": "Explicit diagnostic odd symmetry below0 and analytic inverse above1; counted, not a standard-range mastering or physical luminance claim" if args.extend_pq_domain else "Reject outside0…1",
            "timing": "Assigned relative derivative PTS from source frame index and exact EXR framesPerSecond2997/125; no audio or preview-MP4 timing borrowed",
            "preroll": "None; first frame is a cold temporal start",
            "scope": "Explicitly interpreted and resized natural-scene temporal input; not a calibrated colour reference or native decoder test"}}
    temporary = output / "manifest.partial.json"
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.rename(output / "manifest.json")
    print(output / "manifest.json")


if __name__ == "__main__":
    main()
