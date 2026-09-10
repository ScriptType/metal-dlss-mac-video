#!/usr/bin/env python3
"""Prepare a deterministic synthetic occlusion sequence; CPU/NumPy only.

Usage: uv run --frozen python scripts/prepare-occlusion-reference.py --output NEW_DIR
The canonical 48-frame, 30-fps recipe uses 960x540 pixels. --scale 1 uses
160x90 for independent CPU checks; integer scales 1...6 preserve the recipe.
No decoder, random input, model, Metal, display mapping or external media is used.
"""
import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import tomllib

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).resolve()
COUNT, RATE = 48, 30
MASK_NAMES = ("background", "foreground", "newlyRevealedBackground",
              "backgroundPreviousInBounds", "newViewportBackground")
METADATA_ALLOWANCE_BYTES = 4 * 1024**2
SCOPE = ("Analytic synthetic linear BT.2020 input and geometric visibility truth; "
         "not neural output, estimated optical flow, temporal-quality acceptance, "
         "a decoded HDR stream, physical display or playback timing evidence.")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def pin(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), f"Expected regular file: {path}")
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": digest(path)}


def verify(path, expected):
    actual = pin(path)
    require(actual["bytes"] == expected["bytes"] and actual["sha256"] == expected["sha256"],
            f"Changed or corrupt file: {path}")


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()


def write_new(path, data):
    with Path(path).open("xb") as stream:
        stream.write(data)
    return {"path": Path(path).name, "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}


def progress_report(path, value):
    # Only this generator-owned incomplete report is replaced. Payloads and the
    # final input manifest are always created exclusively in a fresh directory.
    temporary = path.with_suffix(".tmp")
    write_new(temporary, json_bytes(value))
    temporary.replace(path)


def recipe(scale):
    return {"name": "integer-pan-opaque-occluder-v1", "frames": COUNT,
        "fps": {"value": RATE, "timescale": 1}, "integerScale": scale,
        "width": 160 * scale, "height": 90 * scale,
        "phasesInclusive": {"staticPreroll": [0, 7], "panAndOcclusion": [8, 35], "revealedSettle": [36, 47]},
        "step": "t = clamp(sourceFrameIndex - 7, 0, 28)",
        "cameraWorldOffsetPixels": "(t*scale, 0)",
        "foregroundWorldRectangleXYXY": "[(48+5*t)*scale, 16*scale, (88+5*t)*scale, 74*scale]",
        "foregroundScreenRectangleXYXY": "[(48+4*t)*scale, 16*scale, (88+4*t)*scale, 74*scale]",
        "coordinateConvention": "Top-left integer sample indices, +x right/+y down; half-open rectangles; world=(screen.x+cameraX,screen.y).",
        "pixelConstruction": "Evaluate one static analytic background and one object-local analytic foreground texture in Float64, round each once to little-endian Float32; compose with integer crops and opaque replacement. No resampling or antialiasing.",
        "background": {"darkBaseNits": "v=1/8+(worldX+2*worldY)/(64*scale); RGB=(v,3*v/4+1/4,v/2+1/2)",
            "gridPredicate": "(worldX//(4*scale))%9==0 and (worldY//(3*scale))%5<2",
            "detailPredicate": "Even parity of(worldX//(2*scale)+worldY//(2*scale)), inside logical rectangle[24,22,136,70]",
            "gridAdditionNits": [12, 24, 8], "detailAdditionNits": [8, 5, 13],
            "coloredPanelRectanglesLogicalXYXY": [[24, 18, 38, 78], [95, 18, 102, 78]],
            "coloredPanelsNits": [[180, 32, 12], [10, 140, 45]],
            "highlightDiscs": [{"centerLogical": [60, 32], "radiusLogical": 6, "rgbNits": [1200, 1050, 900]},
                               {"centerLogical": [116, 54], "radiusLogical": 5, "rgbNits": [400, 1500, 2500]}]},
        "foreground": {"coordinates": "u,v measured from its own top-left, not screen/world origin",
            "baseNits": "RGB=(48+u/(8*scale),12+v/(8*scale),6+(u+v)/(16*scale))",
            "checkerPredicate": "Even parity of(u//(4*scale)+v//(4*scale)); border is one logical pixel wide",
            "checkerAdditionNits": [32, 16, 4], "borderNits": [3, 4, 6],
            "highlightDisc": {"centerLogical": [20, 18], "radiusLogical": 5, "rgbNits": [320, 180, 45]}},
        "timing": "Assigned synthetic original timeline: PTS=index/30 and duration=1/30; no audio or rebasing.",
        "preroll": "All eight initial static frames are supplied; frame zero starts cold. No reset is forced at phase boundaries.",
        "finalReveal": "Frame35 already has the foreground fully outside the viewport; frames35...47 have identical RGB/background/foreground masks. Transition masks need not match frame35.",
        "scope": SCOPE}


def scene_assets(scale):
    # Extra world columns are real analytic scene content; camera pan never wraps.
    y, x = np.indices((90 * scale, 188 * scale), dtype=np.int64)
    value = 0.125 + (x + 2 * y).astype(np.float64) / (64 * scale)
    background = np.stack((value, value * .75 + .25, value * .5 + .5), axis=-1)
    grid = ((x // (4 * scale)) % 9 == 0) & ((y // (3 * scale)) % 5 < 2)
    background[grid] += [12, 24, 8]
    detail = ((x // (2 * scale) + y // (2 * scale)) % 2 == 0)
    detail &= (x >= 24 * scale) & (x < 136 * scale) & (y >= 22 * scale) & (y < 70 * scale)
    background[detail] += [8, 5, 13]
    for left, right, color in [(24, 38, [180, 32, 12]), (95, 102, [10, 140, 45])]:
        background[(x >= left * scale) & (x < right * scale) & (y >= 18 * scale) & (y < 78 * scale)] = color
    for cx, cy, radius, color in [(60, 32, 6, [1200, 1050, 900]), (116, 54, 5, [400, 1500, 2500])]:
        background[(x - cx * scale)**2 + (y - cy * scale)**2 <= (radius * scale)**2] = color
    v, u = np.indices((58 * scale, 40 * scale), dtype=np.int64)
    foreground = np.stack((48 + u / (8 * scale), 12 + v / (8 * scale),
                           6 + (u + v) / (16 * scale)), axis=-1)
    foreground[(u // (4 * scale) + v // (4 * scale)) % 2 == 0] += [32, 16, 4]
    foreground[(u - 20 * scale)**2 + (v - 18 * scale)**2 <= (5 * scale)**2] = [320, 180, 45]
    foreground[(u < scale) | (u >= 39 * scale) | (v < scale) | (v >= 57 * scale)] = [3, 4, 6]
    return background.astype("<f4"), foreground.astype("<f4")


def geometry(index, scale):
    step = min(28, max(0, index - 7))
    camera, left = step * scale, (48 + 4 * step) * scale
    return {"cameraWorldOffsetPixels": [camera, 0],
        "foregroundWorldRectangleXYXY": [left + camera, 16 * scale, left + camera + 40 * scale, 74 * scale],
        "foregroundScreenRectangleXYXY": [left, 16 * scale, left + 40 * scale, 74 * scale],
        "foregroundVisibleRectangleXYXY": [min(left, 160 * scale), 16 * scale, min(left + 40 * scale, 160 * scale), 74 * scale]}


def render(index, scale, background, texture, previous_foreground):
    width, height = 160 * scale, 90 * scale
    current = geometry(index, scale)
    previous = geometry(max(0, index - 1), scale)
    camera = current["cameraWorldOffsetPixels"][0]
    delta_camera = camera - previous["cameraWorldOffsetPixels"][0]
    left, top, right, bottom = current["foregroundVisibleRectangleXYXY"]
    rgb = background[:, camera:camera + width].copy()
    fg = np.zeros((height, width), dtype=bool)
    fg[top:bottom, left:right] = True
    rgb[top:bottom, left:right] = texture[:, :right-left]
    valid, prior_fg = np.zeros_like(fg), np.zeros_like(fg)
    if index > 0:
        valid[:, :width-delta_camera] = True
        prior_fg[:, :width-delta_camera] = previous_foreground[:, delta_camera:]
    revealed = (~fg) & valid & prior_fg
    entering = (~fg) & (~valid) if index > 0 else np.zeros_like(fg)
    masks = dict(zip(MASK_NAMES, (~fg, fg, revealed, valid, entering)))
    current["previousSourceFrameIndex"] = index - 1 if index > 0 else None
    current["backgroundCurrentToPreviousPixelOffset"] = [delta_camera, 0] if index > 0 else None
    screen_delta = current["foregroundScreenRectangleXYXY"][0] - previous["foregroundScreenRectangleXYXY"][0]
    current["foregroundCurrentToPreviousPixelOffset"] = [-screen_delta, 0] if index > 0 else None
    return rgb, masks, current


def statistics(rgb):
    require(np.isfinite(rgb).all() and bool((rgb > 0).all()), "RGB must be finite and strictly positive")
    return {"minimumNitsRGB": rgb.min(axis=(0, 1)).astype(float).tolist(),
            "maximumNitsRGB": rgb.max(axis=(0, 1)).astype(float).tolist()}


def generate(output, scale):
    require(not output.exists() and not output.is_symlink(), "Output already exists, including dangling symlink")
    require(output.parent.is_dir(), "Output parent must already exist")
    output = output.parent.resolve(strict=True) / output.name
    require(not output.exists() and not output.is_symlink(), "Resolved output already exists, including dangling symlink")
    width, height = 160 * scale, 90 * scale
    payload_bytes = COUNT * width * height * (12 + len(MASK_NAMES))
    require(shutil.disk_usage(output.parent).free >= payload_bytes + METADATA_ALLOWANCE_BYTES,
            "Insufficient free disk for payloads and the bounded metadata allowance")
    sources = [SCRIPT, ROOT / "pyproject.toml", ROOT / "uv.lock"]
    numpy_binary = Path(importlib.import_module("numpy._core._multiarray_umath").__file__).resolve()
    runtime = [Path(sys.executable).resolve(), Path(np.__file__).resolve(), numpy_binary]
    pins = [pin(path) for path in sources + runtime]
    output.mkdir()
    report = {"complete": False, "scope": SCOPE, "completedFrames": 0, "files": [], "pinsBefore": pins}
    report_path = output / "preparation.json"
    progress_report(report_path, report)
    try:
        locked = tomllib.loads((ROOT / "uv.lock").read_text())
        numpy_versions = [item["version"] for item in locked["package"] if item["name"] == "numpy"]
        require(numpy_versions == [np.__version__], f"Use the frozen NumPy lock: installed {np.__version__}, locked {numpy_versions}")
        require(sys.version_info[:2] == (3, 12), "Use Python 3.12 from the project's frozen environment")
        archived = {}
        for source, expected in zip(sources, pins):
            archived[source.name] = write_new(output / source.name, source.read_bytes())
            require(archived[source.name]["sha256"] == expected["sha256"] and
                    archived[source.name]["bytes"] == expected["bytes"], "Source changed while archiving")
            report["files"].append(archived[source.name])
        recipe_pin = write_new(output / "recipe.json", json_bytes(recipe(scale)))
        environment = {"python": sys.version, "implementation": platform.python_implementation(),
            "system": platform.system(), "release": platform.release(), "machine": platform.machine(),
            "byteorder": sys.byteorder, "numpyVersion": np.__version__, "runtimeFiles": pins[len(sources):],
            "sourceFiles": archived, "invocationOptions": {"scale": scale},
            "determinism": "No random numbers, timestamps or output-directory paths enter the manifest/payload recipe; exact runtime and sources are pinned."}
        environment_pin = write_new(output / "environment.json", json_bytes(environment))
        report["files"] += [recipe_pin, environment_pin]
        background, texture = scene_assets(scale)
        previous_fg = np.zeros((height, width), dtype=bool)
        frames = []
        for index in range(COUNT):
            rgb, masks, motion = render(index, scale, background, texture, previous_fg)
            values = statistics(rgb)
            stem = f"frame-{index:04d}"
            frame = write_new(output / (stem + ".rgb32f"), rgb.tobytes(order="C"))
            report["files"].append(frame.copy())
            mask_pins = {}
            for name, mask in masks.items():
                require(mask.dtype == np.bool_ and mask.shape == (height, width), "Unexpected mask layout")
                saved = write_new(output / (stem + "." + name + ".u8"), mask.astype(np.uint8).tobytes(order="C"))
                saved["truePixels"] = int(np.count_nonzero(mask))
                mask_pins[name] = saved
                report["files"].append(saved.copy())
            frame.update(sourceFrameIndex=index, pts={"value": index, "timescale": RATE},
                duration={"value": 1, "timescale": RATE}, statistics=values, geometry=motion, masks=mask_pins,
                phase="staticPreroll" if index < 8 else "panAndOcclusion" if index < 36 else "revealedSettle")
            frames.append(frame)
            previous_fg = masks["foreground"]
            report["completedFrames"] = len(frames)
            progress_report(report_path, report)
        # Re-read every persisted payload before publishing the accepted input.
        for item in report["files"]:
            verify(output / item["path"], item)
        for frame in frames:
            rgb = np.fromfile(output / frame["path"], dtype="<f4").reshape(height, width, 3)
            require(statistics(rgb) == frame["statistics"], "Persisted RGB statistics differ")
            loaded = {}
            for name, item in frame["masks"].items():
                mask = np.fromfile(output / item["path"], dtype=np.uint8).reshape(height, width)
                require(bool((mask <= 1).all()) and int(mask.sum()) == item["truePixels"], "Invalid persisted Boolean mask")
                loaded[name] = mask.astype(bool)
            require(np.array_equal(loaded["background"], ~loaded["foreground"]), "Ownership masks do not partition the image")
            require(not np.any(loaded["newlyRevealedBackground"] & (~loaded["background"] | ~loaded["backgroundPreviousInBounds"])), "Reveal outside valid background correspondence")
        for item in pins:
            verify(item["path"], item)
        manifest = {"schemaVersion": 1, "width": width, "height": height,
            "layout": "RGB float32 little-endian top-to-bottom", "primaries": "BT.2020", "transfer": "linear", "units": "cd/m2",
            "frames": frames, "provenance": {"scope": SCOPE, "recipe": recipe_pin, "environment": environment_pin,
                "generator": archived[SCRIPT.name], "payloadBytesIncludingMasks": payload_bytes,
                "expectedFourViewCaptureBytes": COUNT * width * height * 48,
                "maskLayout": "One UInt8 byte per pixel, exactly 0 or 1; tightly packed top-to-bottom HxW at the RGB source dimensions.",
                "maskMeaning": {"background": "Current visible background; complement of foreground.",
                    "foreground": "Current opaque foreground ownership, clipped to viewport.",
                    "backgroundPreviousInBounds": "Current background-world point maps inside prior viewport; may also be true on foreground. False at frame0.",
                    "newlyRevealedBackground": "Current background AND previous coordinate in bounds AND previous foreground at (x+cameraDelta,y). Not same-screen occupancy subtraction.",
                    "newViewportBackground": "Current background with no previous in-bounds background-world coordinate. False at frame0; excluded from newly revealed mask."},
                "motionMeaning": "Current-to-previous pixel offsets are geometric correspondences, not estimated flow. Apply only to the relevant surface and require previous coordinate inside the image and same-surface visibility before comparing pixels.",
                "capturePolicy": "Supply all48 frames, including static preroll; no automatic/reset/noise-index policy is changed. No grain or flash is mixed in."}}
        encoded = json_bytes(manifest)
        # Exclusive, complete bytes first; atomic link publishes without replacing
        # an existing final path. A failed publication leaves the partial intact.
        temporary = output / "manifest.partial.json"
        write_new(temporary, encoded)
        require(json.loads(temporary.read_bytes()) == manifest, "Manifest serialization changed")
        os.link(temporary, output / "manifest.json")
        temporary.unlink()
        report.update(complete=True, manifest=pin(output / "manifest.json"), allPinsUnchanged=True)
        progress_report(report_path, report)
        print(output / "manifest.json")
    except BaseException as error:
        report.update(complete=False, failure=f"{type(error).__name__}: {error}")
        try:
            progress_report(report_path, report)
        except OSError as report_error:
            print(f"Could not update incomplete report: {report_error}", file=sys.stderr)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New directory under an existing parent")
    parser.add_argument("--scale", type=int, choices=range(1, 7), default=6, help="Integer scale of160x90; default6=960x540")
    args = parser.parse_args()
    generate(Path(os.path.abspath(args.output.expanduser())), args.scale)


if __name__ == "__main__":
    main()
