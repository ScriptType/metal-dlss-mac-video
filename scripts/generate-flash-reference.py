#!/usr/bin/env python3
"""Prepare paired static/control and one-frame global-flash inputs; CPU only.

Both arms contain 48 frames at exact 30 fps. Default scale4 gives640x360.
Only flash frame24 differs: every RGB Float32 component is multiplied by1.5.
No model, renderer, random input, forced reset or discontinuity is introduced.
"""
import argparse
import hashlib
import importlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import tomllib

import numpy as np

SCRIPT = Path(__file__).resolve()
ROOT = SCRIPT.parents[1]
SCENE_SCRIPT = SCRIPT.with_name("prepare-occlusion-reference.py")
SCENE_SHA256 = "65f6a63c3e722b5babcc8bf5dc2b529ee03bfe82e807087c0e6a018dc58613cf"
COUNT, RATE, FLASH_INDEX = 48, 30, 24
METADATA_ALLOWANCE = 4 * 1024**2
SCOPE = ("Paired synthetic linear BT.2020 working inputs with one declared global luminance transient. "
         "CPU preparation only; no neural output, reset decision, perceived quality, decoded HDR stream, "
         "physical presentation or source-rate qualification.")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def pin(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), f"Expected regular file: {path}")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": digest}


def verify(path, expected):
    actual = pin(path)
    require(all(actual[key] == expected[key] for key in ("bytes", "sha256")), f"Changed file: {path}")


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()


def write_new(path, data):
    with path.open("xb") as stream:
        stream.write(data)
    return {"path": path.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def publish_report(path, value):
    partial = path.with_suffix(".partial.json")
    partial.write_bytes(encoded(value))
    partial.replace(path)


def publish_manifest(path, value):
    partial = path.with_suffix(".partial.json")
    result = write_new(partial, encoded(value))
    os.link(partial, path)  # Exclusive final publication; never replace existing evidence.
    partial.unlink()
    return {**result, "path": path.name}


def statistics(rgb):
    require(rgb.dtype == np.dtype("<f4") and rgb.ndim == 3 and rgb.shape[2] == 3,
            "Expected tightly packed RGB Float32")
    require(np.isfinite(rgb).all() and bool((rgb > 0).all()), "Source RGB must be positive and finite")
    return {"minimumNitsRGB": rgb.min(axis=(0, 1)).astype(float).tolist(),
            "maximumNitsRGB": rgb.max(axis=(0, 1)).astype(float).tolist()}


def generate(output, scale=4):
    require(type(scale) is int and scale in (1, 2, 4), "Scale must be one of1,2,4 for exact dyadic arithmetic")
    output = Path(os.path.abspath(Path(output).expanduser()))
    require(not os.path.lexists(output), "Output already exists, including dangling symlink")
    require(output.parent.is_dir(), "Output parent must already exist")
    output = output.parent.resolve(strict=True) / output.name
    require(not os.path.lexists(output), "Resolved output already exists, including dangling symlink")
    width, height = 160 * scale, 90 * scale
    frame_bytes = width * height * 12
    pair_bytes = 2 * COUNT * frame_bytes
    require(shutil.disk_usage(output.parent).free >= pair_bytes + METADATA_ALLOWANCE,
            "Insufficient free disk for both inputs and metadata")
    sources = [SCRIPT, SCENE_SCRIPT, ROOT / "pyproject.toml", ROOT / "uv.lock"]
    numpy_binary = Path(importlib.import_module("numpy._core._multiarray_umath").__file__).resolve()
    runtimes = [Path(sys.executable).resolve(), Path(np.__file__).resolve(), numpy_binary]
    pins = [pin(path) for path in sources + runtimes]
    require(pins[1]["sha256"] == SCENE_SHA256, "The canonical static scene generator changed")
    output.mkdir()
    report_path = output / "preparation.json"
    report = {"complete": False, "scope": SCOPE, "completedFrames": 0, "expectedFrames": 96,
              "pinsBefore": pins, "files": [], "pairedRGBBytes": pair_bytes}
    publish_report(report_path, report)
    try:
        lock = tomllib.loads((ROOT / "uv.lock").read_text())
        require([p["version"] for p in lock["package"] if p["name"] == "numpy"] == [np.__version__],
                "Use the project's frozen NumPy version")
        require(sys.version_info[:2] == (3, 12) and sys.byteorder == "little", "Use frozen little-endian Python3.12")
        spec = importlib.util.spec_from_file_location("flash_static_scene", SCENE_SCRIPT)
        scene = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scene)
        background, texture = scene.scene_assets(scale)
        base, _, geometry = scene.render(0, scale, background, texture, None)
        base = np.ascontiguousarray(base, dtype="<f4")
        flash = np.multiply(base, np.float32(1.5), dtype=np.float32).astype("<f4", copy=False)
        require(base.shape == flash.shape == (height, width, 3), "Unexpected static image extent")
        base_stats, flash_stats = statistics(base), statistics(flash)
        require(np.array_equal(flash.astype(np.float64), base.astype(np.float64) * 1.5),
                "This fixture requires exactly representable Float32 multiplication by1.5")
        base_bytes, flash_bytes = base.tobytes(order="C"), flash.tobytes(order="C")
        require(len(base_bytes) == len(flash_bytes) == frame_bytes and base_bytes != flash_bytes,
                "Incorrect payload extent or missing flash")
        recipe = {"framesPerArm": COUNT, "rate": {"numerator": RATE, "denominator": 1},
            "scale": scale, "width": width, "height": height,
            "scene": "Pinned occlusion generator scene_assets(scale), render(index=0); held static for every frame.",
            "sceneGeneratorSHA256": SCENE_SHA256, "staticGeometry": geometry,
            "flashSourceFrameIndex": FLASH_INDEX, "flashMultiplier": {"numerator": 3, "denominator": 2},
            "operation": "Elementwise Float32 multiply by exactly1.5 after the static scene's Float32 construction; no clipping.",
            "pairing": "Control and flash share exact ordinals, PTS=index/30, duration=1/30 and all original bytes except flash frame24.",
            "capturePolicy": "Separate fresh persistent processor per arm; supply all48frames. Keep normal automatic motion, noise/history evolution and reset policy. Event metadata is observation truth, not a reset directive.",
            "intendedCaptureSettings": {"processingWidth": 512, "processingHeight": 288,
                "strength": 1, "colourStrength": 1, "maximumLuminanceRatio": 2,
                "referenceWhiteNits": 203, "motionRequested": "automatic", "temporal": True,
                "precision": "float16", "sceneCutThreshold": 0.3},
            "scope": SCOPE}
        manifests = {}
        for arm in ("control", "flash"):
            directory = output / arm
            directory.mkdir()
            def save(name, data):
                value = write_new(directory / name, data)
                report["files"].append({**value, "path": f"{arm}/{name}"})
                return value
            archived = {}
            for path, expected in zip(sources, pins):
                archived[path.name] = save(path.name, path.read_bytes())
                require(all(archived[path.name][key] == expected[key] for key in ("bytes", "sha256")),
                        "Source changed while archiving")
            recipe_pin = save("recipe.json", encoded(recipe))
            truth = {"arm": arm, "scope": "Source event ground truth only; never fed to motion/reset decisions.",
                "event": "globalFlash" if arm == "flash" else "none",
                "eventSourceFrameIndices": [FLASH_INDEX] if arm == "flash" else [],
                "eventPTS": {"value": FLASH_INDEX, "timescale": RATE} if arm == "flash" else None,
                "eventDuration": {"value": 1, "timescale": RATE} if arm == "flash" else None,
                "returnToBaseSourceFrameIndex": FLASH_INDEX + 1 if arm == "flash" else None,
                "eventSupportPixels": width * height if arm == "flash" else 0,
                "baseRGBSHA256": hashlib.sha256(base_bytes).hexdigest(),
                "flashRGBSHA256": hashlib.sha256(flash_bytes).hexdigest(),
                "staticOriginalPixelsOutsideEvent": True, "pairedDifferentSourceFrameIndices": [FLASH_INDEX]}
            truth_pin = save("event-groundtruth.json", encoded(truth))
            environment = {"python": sys.version, "numpyVersion": np.__version__,
                "system": platform.system(), "release": platform.release(), "machine": platform.machine(),
                "byteorder": sys.byteorder, "runtimeFiles": pins[len(sources):], "sourceFiles": archived,
                "invocationOptions": {"scale": scale},
                "determinism": "No random values, wall times or output paths enter source pixels or manifest recipe."}
            environment_pin = save("environment.json", encoded(environment))
            frames = []
            for index in range(COUNT):
                is_flash = arm == "flash" and index == FLASH_INDEX
                frame = save(f"frame-{index:04d}.rgb32f", flash_bytes if is_flash else base_bytes)
                frame.update(sourceFrameIndex=index, pts={"value": index, "timescale": RATE},
                    duration={"value": 1, "timescale": RATE}, statistics=flash_stats if is_flash else base_stats)
                frames.append(frame)
                report["completedFrames"] += 1
                publish_report(report_path, report)
            manifests[arm] = {"schemaVersion": 1, "width": width, "height": height,
                "layout": "RGB float32 little-endian top-to-bottom", "primaries": "BT.2020",
                "transfer": "linear", "units": "cd/m2", "frames": frames,
                "provenance": {"scope": SCOPE, "arm": arm, "recipe": recipe_pin,
                    "eventGroundTruth": truth_pin, "environment": environment_pin,
                    "generator": archived[SCRIPT.name], "sceneGenerator": archived[SCENE_SCRIPT.name],
                    "sourceRGBBytes": COUNT * frame_bytes, "expectedFourViewCaptureBytes": COUNT * width * height * 48,
                    "pairing": recipe["pairing"], "capturePolicy": recipe["capturePolicy"]}}
        # Validate persisted paired bytes, not a rerender of the same formulas.
        for index in range(COUNT):
            control = (output / "control" / f"frame-{index:04d}.rgb32f").read_bytes()
            changed = (output / "flash" / f"frame-{index:04d}.rgb32f").read_bytes()
            require(control == base_bytes and changed == (flash_bytes if index == FLASH_INDEX else control),
                    f"Persisted static/paired identity differs at{index}")
        for entry in report["files"]:
            verify(output / entry["path"], entry)
        for entry in pins:
            verify(entry["path"], entry)
        pins_after = [pin(path) for path in sources + runtimes]
        require(pins_after == pins, "Source/runtime pins changed before final publication")
        pair = {"schemaVersion": 1, "complete": True, "scope": SCOPE, "arms": {},
            "pairedDifferentSourceFrameIndices": [FLASH_INDEX], "frameBytes": frame_bytes,
            "pairedRGBBytes": pair_bytes, "expectedTwoFourViewCaptureBytes": 2 * COUNT * width * height * 48}
        for arm, manifest in manifests.items():
            value = publish_manifest(output / arm / "manifest.json", manifest)
            pair["arms"][arm] = {**value, "path": f"{arm}/manifest.json"}
        pair_pin = publish_manifest(output / "pair.json", pair)
        report.update(complete=True, allPinsUnchanged=True, persistedPairChecked=True,
                      pair=pair_pin, pinsAfter=pins_after)
        publish_report(report_path, report)
        print(output / "pair.json")
    except BaseException as error:
        report.update(complete=False, failure=f"{type(error).__name__}: {error}")
        try:
            publish_report(report_path, report)
        except OSError as reporting_error:
            print(f"Could not publish incomplete report: {reporting_error}", file=sys.stderr)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New paired directory under an existing parent")
    parser.add_argument("--scale", type=int, choices=(1, 2, 4), default=4,
                        help="Dyadic scale1/2/4 of160x90; default4=640x360, scale1 for CPU controls")
    args = parser.parse_args()
    generate(args.output, args.scale)


if __name__ == "__main__":
    main()
