#!/usr/bin/env python3
"""Prepare one deterministic grain-like contrast input arm; CPU only.

All48 frames use the pinned canonical static scene at exact30fps. Frames24...35
apply nominal achromatic +/-1/32 contrast in2x2 source-pixel cells; all other
frames retain the clean scene bytes. No natural-film-grain or zero-mean claim.
"""
import argparse
import hashlib
import importlib
import importlib.util
import os
from pathlib import Path
import platform
import shutil
import sys
import tomllib

import numpy as np

SCRIPT = Path(__file__).resolve()
ROOT = SCRIPT.parents[1]
HELPER = SCRIPT.with_name("generate-flash-reference.py")
HELPER_SHA256 = "a8ae1e96a668da736f2c7e79f62b628536261f89e9ab76fbcc5e0d501c2dfbef"
SCENE = SCRIPT.with_name("prepare-occlusion-reference.py")
SCENE_SHA256 = "65f6a63c3e722b5babcc8bf5dc2b529ee03bfe82e807087c0e6a018dc58613cf"
COUNT, RATE, SEED = 48, 30, "hdr-grain-reference-v1"
ACTIVE = tuple(range(24, 36))
METADATA_ALLOWANCE = 4 * 1024**2
FIELD_LAYOUT = "int8 row-major source-sized sign field"
SCOPE = ("Synthetic deterministic grain-like multiplicative contrast on linear BT.2020 RGB working inputs. "
         "CPU preparation only; no natural film-grain realism, exact zero mean, neural quality, reset cause, "
         "physical HDR presentation or source-rate qualification.")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def grain_field(index, width, height):
    """Independent SHA256 blocks concatenate into one LSB-first cell bitstream."""
    require(type(index) is int and index in ACTIVE and width % 2 == height % 2 == 0, "Invalid field index/extent")
    cell_count = (width // 2) * (height // 2)
    prefix = SEED.encode("ascii") + index.to_bytes(4, "little", signed=False)
    stream = b"".join(hashlib.sha256(prefix + block.to_bytes(4, "little", signed=False)).digest()
                      for block in range((cell_count + 255) // 256))
    bits = np.unpackbits(np.frombuffer(stream, dtype=np.uint8), bitorder="little")[:cell_count]
    cells = (bits.astype(np.int8) * 2 - 1).reshape(height // 2, width // 2)
    return cells.repeat(2, axis=0).repeat(2, axis=1)


def rounding_statistics(actual, expected):
    difference = actual.astype(np.float64) - expected
    return {"float32MatchesExactFloat64Product": bool(np.array_equal(actual.astype(np.float64), expected)),
            "roundedComponents": int(np.count_nonzero(difference)),
            "maximumAbsoluteRoundingNits": float(np.abs(difference).max())}


def generate(output, scale=4):
    require(type(scale) is int and scale in (1, 2, 4), "Scale must be one of1,2,4")
    output = Path(os.path.abspath(Path(output).expanduser()))
    require(not os.path.lexists(output), "Output already exists, including dangling symlink")
    require(output.parent.is_dir(), "Output parent must already exist")
    output = output.parent.resolve(strict=True) / output.name
    require(not os.path.lexists(output), "Resolved output already exists, including dangling symlink")
    width, height = 160 * scale, 90 * scale
    frame_bytes, field_bytes = width * height * 12, width * height
    rgb_bytes, all_field_bytes = COUNT * frame_bytes, len(ACTIVE) * field_bytes
    require(shutil.disk_usage(output.parent).free >= rgb_bytes + all_field_bytes + METADATA_ALLOWANCE,
            "Insufficient free disk for RGB, saved sign fields and bounded metadata")
    with HELPER.open("rb") as stream:
        require(hashlib.file_digest(stream, "sha256").hexdigest() == HELPER_SHA256, "Reviewed preparation helper changed")
    helper = module("grain_preparation_helpers", HELPER)
    sources = [SCRIPT, HELPER, SCENE, ROOT / "pyproject.toml", ROOT / "uv.lock"]
    numpy_binary = Path(importlib.import_module("numpy._core._multiarray_umath").__file__).resolve()
    runtimes = [Path(sys.executable).resolve(), Path(np.__file__).resolve(), numpy_binary]
    pins = [helper.pin(path) for path in sources + runtimes]
    require(pins[2]["sha256"] == SCENE_SHA256, "Pinned canonical static scene generator changed")
    output.mkdir()
    report_path = output / "preparation.json"
    report = {"complete": False, "scope": SCOPE, "completedFrames": 0, "expectedFrames": COUNT,
              "pinsBefore": pins, "files": [], "sourceRGBBytes": rgb_bytes, "grainFieldBytes": all_field_bytes,
              "requiredOutputBytesWithMetadata": rgb_bytes + all_field_bytes + METADATA_ALLOWANCE}
    helper.publish_report(report_path, report)
    try:
        lock = tomllib.loads((ROOT / "uv.lock").read_text())
        require([entry["version"] for entry in lock["package"] if entry["name"] == "numpy"] == [np.__version__] == ["2.5.3"],
                "Use the project's frozen NumPy2.5.3")
        require(sys.version_info[:2] == (3, 12) and sys.byteorder == "little", "Use frozen little-endian Python3.12")
        scene = module("grain_canonical_static_scene", SCENE)
        background, texture = scene.scene_assets(scale)
        base, _, geometry = scene.render(0, scale, background, texture, None)
        base = np.ascontiguousarray(base, dtype="<f4")
        require(base.shape == (height, width, 3), "Unexpected canonical scene extent")
        base_stats, base_bytes = helper.statistics(base), base.tobytes(order="C")
        base64 = base.astype(np.float64)
        # Check BOTH factors over this selected scale's entire canonical base.
        # Rounded products are retained unchanged, never repaired or rescaled.
        products, arithmetic = {}, {}
        for sign, numerator in ((-1, 31), (1, 33)):
            factor = np.float32(numerator / 32)
            products[sign] = np.multiply(base, factor, dtype=np.float32).astype("<f4", copy=False)
            helper.statistics(products[sign])
            arithmetic[str(sign)] = {"multiplier": {"numerator": numerator, "denominator": 32},
                **rounding_statistics(products[sign], base64 * (numerator / 32))}
        all_exact = all(value["float32MatchesExactFloat64Product"] for value in arithmetic.values())
        def save(name, data):
            value = helper.write_new(output / name, data)
            report["files"].append(value)
            return value
        archived = {}
        for path, expected in zip(sources, pins):
            archived[path.name] = save(path.name, path.read_bytes())
            require(all(archived[path.name][key] == expected[key] for key in ("bytes", "sha256")), "Source changed while archiving")
        recipe = {"name": "sha256-cell-contrast-grain-v1", "frames": COUNT, "rate": {"numerator": RATE, "denominator": 1},
            "scale": scale, "width": width, "height": height, "sceneGeneratorSHA256": SCENE_SHA256,
            "scene": "Pinned occlusion scene_assets(scale), render(index=0); clean base is never regenerated per frame.",
            "staticGeometry": geometry, "grainSourceFrameIndices": list(ACTIVE), "returnToBaseSourceFrameIndex": 36,
            "cleanSourceFrameRangesInclusive": [[0, 23], [36, 47]], "cellSizeSourcePixels": [2, 2],
            "amplitude": {"numerator": 1, "denominator": 32}, "seed": SEED,
            "hashMessage": "ASCII(seed), with no terminator or separator, followed by sourceFrameIndex uint32LE then blockCounter uint32LE.",
            "stream": "Concatenate SHA256 digests for blockCounter=0,1,...; unpack each byte LSB-first; take first cellCount bits in row-major cell order.",
            "bitMapping": {"0": -1, "1": 1}, "cellGrid": [width // 2, height // 2],
            "fieldExpansion": "Each cell becomes exactly2x2 source pixels. Stored signed int8 field is source-sized, top-left origin, +x right/+y down, row-major.",
            "sourceOperation": "Elementwise Float32(baseRGB * Float32(1 + sign/32)); the same factor is selected for R/G/B, with no clipping.",
            "arithmeticScope": "Factors31/32 and33/32 are exactly representable. Product exactness is tested and recorded for this selected scale; any Float32 rounding remains in the stored originals.",
            "meanScope": "Cell signs are not balanced after hashing. Realized sign/contrast mean is recorded, not forced to zero; nominal achromatic factors do not assert exact chromaticity after rounding.",
            "capturePolicy": "One fresh persistent processor; supply all48 frames with normal automatic motion, noise/history evolution and reset policy. Event truth is not a reset directive.",
            "intendedCaptureSettings": {"processingWidth": 512, "processingHeight": 288, "strength": 1, "colourStrength": 1,
                "maximumLuminanceRatio": 2, "referenceWhiteNits": 203, "motionRequested": "automatic", "temporal": True,
                "precision": "float16", "sceneCutThreshold": 0.3}, "scope": SCOPE}
        recipe_pin = save("recipe.json", helper.encoded(recipe))
        arithmetic_pin = save("arithmetic-preflight.json", helper.encoded({"scale": scale, "baseRGBSHA256": hashlib.sha256(base_bytes).hexdigest(),
            "factors": arithmetic, "bothFactorsExactOnFullBase": all_exact, "sourceOperation": "Float32 multiply; no rounding correction"}))
        environment_pin = save("environment.json", helper.encoded({"python": sys.version, "numpyVersion": np.__version__,
            "system": platform.system(), "release": platform.release(), "machine": platform.machine(), "byteorder": sys.byteorder,
            "runtimeFiles": pins[len(sources):], "sourceFiles": archived, "invocationOptions": {"scale": scale},
            "determinism": "No random API, process state, wall time or output path enters field bits or source pixels."}))
        frames = []
        for index in range(COUNT):
            field_pin = None
            if index in ACTIVE:
                field = grain_field(index, width, height)
                field_pin = save(f"frame-{index:04d}.grain-signs.i8", field.tobytes(order="C"))
                positive = int(np.count_nonzero(field == 1)); negative = int(np.count_nonzero(field == -1))
                require(positive + negative == field_bytes, "Unexpected field signs")
                field_pin.update(layout=FIELD_LAYOUT, width=width, height=height,
                    statistics={"positivePixels": positive, "negativePixels": negative, "positiveCells": positive // 4,
                        "negativeCells": negative // 4, "meanSign": (positive - negative) / field_bytes,
                        "meanNominalMultiplier": 1 + (positive - negative) / (32 * field_bytes)})
                rgb = np.where(field[:, :, None] > 0, products[1], products[-1]).astype("<f4", copy=False)
                rounding = rounding_statistics(rgb, base64 * (1 + field[:, :, None].astype(np.float64) / 32))
                require(not all_exact or rounding["float32MatchesExactFloat64Product"], "Selected-field product violated full-base exactness proof")
                pixels = rgb.tobytes(order="C")
                statistics = helper.statistics(rgb)
            else:
                pixels, statistics = base_bytes, base_stats
            frame = save(f"frame-{index:04d}.rgb32f", pixels)
            frame.update(sourceFrameIndex=index, pts={"value": index, "timescale": RATE}, duration={"value": 1, "timescale": RATE}, statistics=statistics)
            if field_pin is not None:
                frame.update(grainField=field_pin, arithmetic=rounding)
            frames.append(frame)
            report["completedFrames"] += 1
            helper.publish_report(report_path, report)
        truth = {"arm": "grain", "event": "deterministicGrainLikeContrast", "scope": "Source event ground truth only; never a reset directive.",
            "eventSourceFrameIndices": list(ACTIVE), "eventStartPTS": {"value": 24, "timescale": RATE},
            "eventDuration": {"value": 12, "timescale": RATE}, "returnToBaseSourceFrameIndex": 36,
            "baseRGBSHA256": hashlib.sha256(base_bytes).hexdigest(), "staticOriginalPixelsOutsideEvent": True,
            "eventSupportPixelsPerFrame": field_bytes, "grainFieldBytes": all_field_bytes,
            "actualSignMean": "Recorded separately for each saved field; not assumed zero.", "naturalFilmGrainClaim": False}
        truth_pin = save("event-groundtruth.json", helper.encoded(truth))
        # Check saved originals against the saved actual fields, rather than
        # accepting a second construction that never reads the published files.
        for frame in frames:
            actual = (output / frame["path"]).read_bytes()
            if "grainField" in frame:
                field = np.fromfile(output / frame["grainField"]["path"], dtype=np.int8).reshape(height, width)
                require(bool(np.isin(field, [-1, 1]).all()), "Persisted field has invalid signs")
                expected = np.where(field[:, :, None] > 0, products[1], products[-1]).astype("<f4", copy=False).tobytes(order="C")
            else:
                expected = base_bytes
            require(actual == expected, f"Persisted source/field mismatch at{frame['sourceFrameIndex']}")
        for entry in report["files"]:
            helper.verify(output / entry["path"], entry)
        pins_after = [helper.pin(path) for path in sources + runtimes]
        require(pins_after == pins, "Source/runtime pins changed before final publication")
        manifest = {"schemaVersion": 1, "width": width, "height": height, "layout": "RGB float32 little-endian top-to-bottom",
            "primaries": "BT.2020", "transfer": "linear", "units": "cd/m2", "frames": frames,
            "provenance": {"scope": SCOPE, "arm": "grain", "recipe": recipe_pin, "eventGroundTruth": truth_pin,
                "environment": environment_pin, "arithmeticPreflight": arithmetic_pin, "generator": archived[SCRIPT.name],
                "sceneGenerator": archived[SCENE.name], "preparationHelper": archived[HELPER.name],
                "sourceRGBBytes": rgb_bytes, "grainFieldBytes": all_field_bytes,
                "expectedFourViewCaptureBytes": COUNT * width * height * 48, "capturePolicy": recipe["capturePolicy"]}}
        manifest_pin = helper.publish_manifest(output / "manifest.json", manifest)
        report.update(complete=True, allPinsUnchanged=True, persistedFramesChecked=True, manifest=manifest_pin,
                      pinsAfter=pins_after, activeGrainFrames=len(ACTIVE), bothFactorsExactOnFullBase=all_exact)
        helper.publish_report(report_path, report)
        print(output / "manifest.json")
    except BaseException as error:
        report.update(complete=False, failure=f"{type(error).__name__}: {error}")
        try:
            helper.publish_report(report_path, report)
        except OSError as reporting_error:
            print(f"Could not publish incomplete report: {reporting_error}", file=sys.stderr)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New single-arm directory under an existing parent")
    parser.add_argument("--scale", type=int, choices=(1, 2, 4), default=4, help="Scale1/2/4 of160x90; default4=640x360")
    args = parser.parse_args()
    generate(args.output, args.scale)
