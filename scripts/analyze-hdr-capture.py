#!/usr/bin/env python3
"""Offline inspection of bounded SCK captures. Requires the project NumPy environment.

No screenshot API, resampling, alpha reconstruction, display calibration or
extended-range transfer assumption is made. Optional comparison uses explicit,
equally sized caller-selected ROIs in the same capture intent and ICC domain.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct

import numpy as np


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_capture(directory):
    directory = Path(directory)
    if (directory / "report.json").stat().st_size > 4 * 1024 * 1024:
        raise ValueError("Capture report exceeds 4 MiB")
    report = json.loads((directory / "report.json").read_text())
    storage = report["pixelStorage"]
    width, height, stride = (int(storage[key]) for key in ("width", "height", "bytesPerRow"))
    name = storage["file"]
    if name not in ("pixels.rgba16f", "pixels.bgra8"):
        raise ValueError("Unsupported pixel encoding/file")
    element, bpp = (np.dtype("<f2"), 8) if name.endswith("rgba16f") else (np.dtype("u1"), 4)
    if not (0 < width <= 16384 and 0 < height <= 16384 and width * height <= 8_388_608 and
            width * bpp <= stride <= width * bpp + 65536 and stride % bpp == 0 and stride * height <= 96 * 1024 * 1024):
        raise ValueError("Invalid or oversized captured layout")
    if (directory / name).stat().st_size != stride * height:
        raise ValueError("Pixel payload length/hash mismatch")
    with (directory / name).open("rb") as stream:
        data = stream.read(stride * height + 1)
    if len(data) != stride * height or sha(data) != storage["sha256"]:
        raise ValueError("Pixel payload length/hash mismatch")
    pixels = np.frombuffer(data, dtype=element).reshape(height, stride // element.itemsize)
    pixels = pixels[:, :width * 4].reshape(height, width, 4).astype(np.float64)
    if bpp == 4:
        pixels = pixels[:, :, [2, 1, 0, 3]] / 255.0
    attached = report.get("pixelAttachmentsPropagating", {}).get("CVImageBufferICCProfile")
    if not attached:
        # SDR control returns an actual CVImageBuffer CGColorSpace attachment
        # instead of a separate ICC blob. This is still observed metadata.
        space = report.get("actualColorSpace", {})
        if "iccBase64" in space and "iccSHA256" in space:
            attached = {"base64": space["iccBase64"], "sha256": space["iccSHA256"]}
    if not attached:
        raise ValueError("No actual ICC attachment; refusing to infer from requested color space")
    icc = base64.b64decode(attached["base64"], validate=True)
    if len(icc) > 1024 * 1024 or sha(icc) != attached["sha256"]:
        raise ValueError("ICC payload length/hash mismatch")
    return report, pixels, icc


def matrix_profile(icc):
    """Only the observed ICC RGB matrix + parametric type3 profile is supported.

    ICC.1 type3: Y=(aX+b)^g for X>=d, otherwise cX, input domain [0,1].
    XYZ matrix columns already include chromatic adaptation to profile PCS D50.
    Do not apply the chad matrix a second time or extrapolate extended values.
    """
    if (len(icc) < 132 or icc[12:24] != b"mntrRGB XYZ " or icc[36:40] != b"acsp" or
            icc[8] not in (2, 4) or struct.unpack_from(">I", icc)[0] != len(icc)):
        raise ValueError("Unsupported ICC header")
    count = struct.unpack_from(">I", icc, 128)[0]
    if count > 128 or 132 + count * 12 > len(icc):
        raise ValueError("Invalid ICC tag table")
    tags = {}
    for index in range(count):
        tag, offset, length = struct.unpack_from(">4sII", icc, 132 + index * 12)
        if tag in tags or offset < 132 + count * 12 or length < 8 or offset + length > len(icc):
            raise ValueError("Invalid ICC tag range")
        tags[tag] = icc[offset:offset + length]
    if any(tag.startswith((b"A2B", b"B2A", b"D2B", b"B2D")) for tag in tags):
        raise ValueError("LUT profiles are outside the supported ICC subset")
    def xyz(key):
        data = tags[key]
        if len(data) != 20 or data[:4] != b"XYZ ":
            raise ValueError("Unsupported ICC matrix tag")
        return np.array(struct.unpack_from(">iii", data, 8)) / 65536.0
    curves = []
    for key in (b"rTRC", b"gTRC", b"bTRC"):
        data = tags[key]
        if len(data) != 32 or data[:4] != b"para" or struct.unpack_from(">H", data, 8)[0] != 3:
            raise ValueError("Only ICC parametric curve type3 is supported")
        parameters = np.array(struct.unpack_from(">iiiii", data, 12)) / 65536.0
        gamma, a, b, c, threshold = parameters
        if not (0 < gamma <= 5 and a > 0 and b >= 0 and c >= 0 and 0 <= threshold <= 1):
            raise ValueError("Unsupported ICC curve parameters")
        curves.append(parameters)
    return np.column_stack([xyz(key) for key in (b"rXYZ", b"gXYZ", b"bXYZ")]), np.array(curves)


def to_xyz(rgb, matrix, curves):
    if not np.all(np.isfinite(rgb)) or np.any(rgb < 0) or np.any(rgb > 1):
        raise ValueError("ICC comparison accepts only finite encoded RGB in [0,1]")
    linear = np.empty_like(rgb)
    for channel, (gamma, a, b, c, threshold) in enumerate(curves):
        x = rgb[..., channel]
        linear[..., channel] = np.where(x >= threshold, (a * x + b) ** gamma, c * x)
    return linear @ matrix.T


def statistics(pixels):
    finite = np.isfinite(pixels)
    rgb = pixels[..., :3]
    return {"width": pixels.shape[1], "height": pixels.shape[0],
        "nonfiniteComponents": int(np.sum(~finite)),
        "finiteComponentMinRGBA": [float(x[np.isfinite(x)].min()) if np.isfinite(x).any() else None for x in np.moveaxis(pixels, 2, 0)],
        "finiteComponentMaxRGBA": [float(x[np.isfinite(x)].max()) if np.isfinite(x).any() else None for x in np.moveaxis(pixels, 2, 0)],
        "rgbComponentsBelowZero": int(np.sum(rgb < 0)), "rgbComponentsAboveOne": int(np.sum(rgb > 1)),
        "opaquePixels": int(np.sum(pixels[..., 3] == 1)),
        "nonopaquePixels": int(np.sum(pixels[..., 3] != 1)),
        "scope": "Encoded captured components, not linear light or nits; nonfinite values retained in counts"}


def crop(pixels, value):
    x, y, width, height = map(int, value.split(","))
    if not (x >= 0 and y >= 0 and width > 0 and height > 0 and x + width <= pixels.shape[1] and y + height <= pixels.shape[0]):
        raise ValueError("ROI outside captured pixels")
    return pixels[y:y + height, x:x + width]


def compare(first, second, roi_first, roi_second):
    r1, p1, icc1 = first; r2, p2, icc2 = second
    if icc1 != icc2 or r1["configuration"]["dynamicRange"] != r2["configuration"]["dynamicRange"]:
        raise ValueError("Comparison requires matching actual ICC and capture intent")
    p1, p2 = crop(p1, roi_first), crop(p2, roi_second)
    if p1.shape != p2.shape:
        raise ValueError("Comparison ROIs must have equal dimensions; no resampling is inferred")
    matrix, curves = matrix_profile(icc1)
    def valid(pixels):
        return np.isfinite(pixels).all(axis=2) & (pixels[..., 3] == 1) & (pixels[..., :3] >= 0).all(axis=2) & (pixels[..., :3] <= 1).all(axis=2)
    mask = valid(p1) & valid(p2)
    if not np.any(mask):
        raise ValueError("No paired opaque in-range pixels")
    xyz1, xyz2 = (to_xyz(p[mask, :3], matrix, curves) for p in (p1, p2))
    delta = xyz2 - xyz1
    return {"comparedPixels": int(mask.sum()), "excludedPixels": int(mask.size - mask.sum()),
        "roiFirst": roi_first, "roiSecond": roi_second,
        "meanAbsoluteEncodedRGBDifference": np.mean(np.abs(p2[mask, :3] - p1[mask, :3]), axis=0).tolist(),
        "meanAbsoluteRelativeXYZD50Difference": np.mean(np.abs(delta), axis=0).tolist(),
        "maximumAbsoluteRelativeXYZD50Difference": np.max(np.abs(delta), axis=0).tolist(),
        "scope": "Caller-aligned ROI comparison in actual ICC PCS D50, relative units; no inferred frame/geometry equivalence, HDR extrapolation or physical qualification"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--compare", type=Path)
    parser.add_argument("--roi-first")
    parser.add_argument("--roi-second")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    first = read_capture(args.capture)
    report = {"schemaVersion": 1, "capture": str(args.capture), "iccSHA256": sha(first[2]), "statistics": statistics(first[1])}
    try:
        matrix, curves = matrix_profile(first[2])
        report["supportedICCSubset"] = {"matrixToRelativeXYZD50": matrix.tolist(), "type3CurvesGammaABCThreshold": curves.tolist(),
            "inputDomain": "Opaque finite encoded RGB in [0,1] only; extended values are not extrapolated"}
    except (ValueError, KeyError) as error:
        report["iccComparisonUnavailable"] = str(error)
    if args.compare:
        if not args.roi_first or not args.roi_second:
            parser.error("--compare requires both explicit ROIs x,y,width,height")
        report["comparison"] = compare(first, read_capture(args.compare), args.roi_first, args.roi_second)
    text = json.dumps(report, indent=2, allow_nan=False) + "\n"
    if args.output:
        with args.output.open("x") as stream: stream.write(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
