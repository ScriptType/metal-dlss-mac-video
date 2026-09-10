#!/usr/bin/env python3
"""CPU residual analysis for a complete canonical synthetic occlusion capture.

Use --input SOURCE/manifest.json --capture CAPTURE/manifest.json --output NEW_DIR.
No images, model execution, optical-flow estimation or quality threshold is used.
"""
import argparse
import csv
import importlib.util
import json
import os
from pathlib import Path
import platform
import sys

import numpy as np

HELPER = Path(__file__).with_name("review-reference-sequence.py")
REGIONS = ("background", "foreground", "newlyRevealedBackground", "newViewportBackground")
MASKS = REGIONS + ("backgroundPreviousInBounds",)
RESIDUALS = ("enhancedMinusOriginal", "identityMinusOriginal")
METRICS = ("signedMeanNits", "meanAbsoluteNits", "rmsNits", "maximumAbsoluteNits")
AGES = (0, 1, 2, 4, 8)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n").encode()


def publish(path, report):
    temporary = path.with_suffix(".tmp")
    with temporary.open("xb") as stream:
        stream.write(encoded(report))
    temporary.replace(path)


def metrics(values):
    if values.size == 0:
        return None
    values = values.astype(np.float64, copy=False)
    absolute = np.abs(values)
    return dict(zip(METRICS, (float(values.mean()), float(absolute.mean()),
                             float(np.sqrt(np.mean(values * values))), float(absolute.max()))))


def expected_geometry(index, scale):
    step = min(28, max(index - 7, 0))
    camera, left = step * scale, (48 + 4 * step) * scale
    moving = 8 <= index <= 35
    return {"cameraWorldOffsetPixels": [camera, 0],
        "foregroundWorldRectangleXYXY": [left + camera, 16 * scale, left + camera + 40 * scale, 74 * scale],
        "foregroundScreenRectangleXYXY": [left, 16 * scale, left + 40 * scale, 74 * scale],
        "foregroundVisibleRectangleXYXY": [min(left, 160 * scale), 16 * scale, min(left + 40 * scale, 160 * scale), 74 * scale],
        "previousSourceFrameIndex": index - 1 if index else None,
        "backgroundCurrentToPreviousPixelOffset": [scale if moving else 0, 0] if index else None,
        "foregroundCurrentToPreviousPixelOffset": [-4 * scale if moving else 0, 0] if index else None}


def slices(width, dx):
    return slice(max(0, -dx), min(width, width - dx)), slice(max(0, dx), min(width, width + dx))


def analyze(input_manifest, capture_manifest, output_dir):
    require(not sys.flags.optimize, "Python optimization disables required capture assertions; do not use -O")
    output = Path(os.path.abspath(Path(output_dir).expanduser()))
    require(not output.exists() and not output.is_symlink(), "Output already exists, including dangling symlink")
    require(output.parent.is_dir(), "Output parent must exist")
    output = output.parent.resolve(strict=True) / output.name
    require(not output.exists() and not output.is_symlink(), "Resolved output already exists")
    output.mkdir()
    report = {"schemaVersion": 1, "complete": False, "frames": [], "cohorts": [],
        "scope": "Synthetic raw RGB residual observations in nits; no neural execution, quality threshold, ghost-free or physical display claim."}
    report_path = output / "report.json"
    publish(report_path, report)
    pins = {}
    try:
        import hashlib
        def remember(path, expected=None):
            path = Path(os.path.abspath(path))
            require(path.is_file(), f"Missing regular input: {path}")
            with path.open("rb") as stream:
                sha = hashlib.file_digest(stream, "sha256").hexdigest()
            actual = {"path": str(path), "resolvedPath": str(path.resolve(strict=True)),
                      "bytes": path.stat().st_size, "sha256": sha}
            if expected is not None:
                require(type(expected.get("bytes")) is int and actual["bytes"] == expected["bytes"] and
                        actual["sha256"] == expected.get("sha256"), f"Size/hash mismatch: {path}")
            if str(path) in pins:
                require(actual == pins[str(path)], f"Input changed during analysis: {path}")
            pins[str(path)] = actual
            return actual
        def read(path):
            require(0 < Path(path).stat().st_size <= 1024**2, "JSON exceeds 1-MiB bound")
            value = json.loads(Path(path).read_bytes())
            require(isinstance(value, dict), "Expected a JSON object")
            return value
        remember(Path(__file__).resolve()); remember(HELPER.resolve())
        spec = importlib.util.spec_from_file_location("occlusion_capture_review", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        def use(directory, metadata):
            resolved = helper.contained(directory, metadata["path"])
            remember(directory / metadata["path"], metadata)
            return resolved
        source_path, capture_path = Path(input_manifest).resolve(strict=True), Path(capture_manifest).resolve(strict=True)
        remember(source_path); remember(capture_path)
        source, capture_header = read(source_path), read(capture_path)
        width, height = source.get("width"), source.get("height")
        require(type(width) is int and type(height) is int and width % 160 == 0 and
                1 <= width // 160 <= 6 and height == 90 * (width // 160), "Expected canonical scale1...6 dimensions")
        scale = width // 160
        require(len(source.get("frames", [])) == 48 and len(capture_header.get("frames", [])) == 48,
                "Exactly all48 source and capture frames are required")
        capture, frames, _ = helper.validate_capture(capture_path)
        copied = helper.contained(capture_path.parent, capture["inputManifestCopy"])
        remember(copied)
        require(source_path.read_bytes() == copied.read_bytes() and
                pins[str(source_path)]["sha256"] == capture["inputManifestSHA256"], "Capture input copy differs from original manifest bytes/hash")
        provenance = source["provenance"]
        recipe = read(use(source_path.parent, provenance["recipe"]))
        environment = read(use(source_path.parent, provenance["environment"]))
        use(source_path.parent, provenance["generator"])
        for metadata in environment["sourceFiles"].values():
            use(source_path.parent, metadata)
        require(recipe.get("name") == "integer-pan-opaque-occluder-v1" and recipe.get("frames") == 48 and
                recipe.get("integerScale") == scale and recipe.get("width") == width and recipe.get("height") == height and
                recipe.get("fps") == {"value": 30, "timescale": 1} and recipe.get("phasesInclusive") ==
                {"staticPreroll": [0, 7], "panAndOcclusion": [8, 35], "revealedSettle": [36, 47]}, "Unsupported canonical recipe")
        requested_motion = capture["settings"].get("motionRequested")
        require(requested_motion in ("automatic", "videotoolbox", "vision", "zero"), "Missing public motion request")
        report.update(inputManifest=pins[str(source_path)], captureManifest=pins[str(capture_path)],
            width=width, height=height, integerScale=scale, recipe=recipe, sourceProvenance=provenance,
            captureMetadata={key: value for key, value in capture.items() if key != "frames"},
            tools={"python": platform.python_version(), "numpy": np.__version__},
            metricDefinition="All three RGB components, equal weight, Float64 subtraction/accumulation. Temporal=(E-O)current-(E-O)previous at exact same-material coordinates; I-O analogous.",
            cohortDefinition="Newly revealed background world coordinates at ages0/1/2/4/8 and frame47. E-O and change from reveal are empirical later-context observations, not an ideal target or isolated history/noise effect.",
            limitations=["Empty regions and missing visible predecessors are null, never zero error.",
                "Only source geometry establishes correspondence; no estimated flow or interpolation is used.",
                "historyReset/usedModel/motionRequested are declared capture fields, not an independently established backend or reset cause.",
                "All48 frames including preroll are reported. No phase/reset samples are excluded from metrics.",
                "One previous full frame plus compact reveal coordinates/original bits/residuals is retained; no full sequence arrays."])
        previous, cohorts, rows = None, [], []
        for index, (item, frame) in enumerate(zip(source["frames"], frames)):
            phase = "staticPreroll" if index < 8 else "panAndOcclusion" if index < 36 else "revealedSettle"
            require(type(item["sourceFrameIndex"]) is int and item["sourceFrameIndex"] == index and
                    item["pts"] == frame["pts"] == {"value": index, "timescale": 30} and
                    item["duration"] == frame["duration"] == {"value": 1, "timescale": 30} and item["phase"] == phase,
                    f"Canonical frame timing/order/phase changed at{index}")
            geometry = expected_geometry(index, scale)
            require(encoded(item["geometry"]) == encoded(geometry), f"Canonical geometry changed at{index}")
            require(type(frame.get("historyReset")) is bool and type(frame.get("usedModel")) is bool, "Missing reset/model flags")
            source_rgb = helper.load_view(source_path.parent, item, width, height)
            use(source_path.parent, item)
            require(bool((source_rgb > 0).all()), "Canonical source RGB must be positive")
            arrays = {}
            for name in helper.VIEWS:
                arrays[name] = helper.load_view(capture_path.parent, frame["views"][name], width, height)
                use(capture_path.parent, frame["views"][name])
            original = arrays["original"]
            require(np.array_equal(source_rgb.view("<u4"), original.view("<u4")), f"Original differs from source bits at{index}")
            del source_rgb
            masks = {}
            require(set(item["masks"]) == set(MASKS), "Expected exactly five visibility masks")
            for name in MASKS:
                metadata = item["masks"][name]
                require(metadata.get("bytes") == width * height, "Mask size mismatch")
                mask = np.fromfile(use(source_path.parent, metadata), dtype=np.uint8).reshape(height, width)
                require(bool((mask <= 1).all()) and type(metadata.get("truePixels")) is int and
                        int(mask.sum()) == metadata["truePixels"], f"Invalid Boolean mask/count:{name}")
                masks[name] = mask.astype(bool)
            fg = np.zeros((height, width), dtype=bool)
            left, top, right, bottom = geometry["foregroundVisibleRectangleXYXY"]
            fg[top:bottom, left:right] = True
            valid, old_fg = np.zeros_like(fg), np.zeros_like(fg)
            dx = scale if 8 <= index <= 35 else 0
            if previous is not None:
                valid[:, :width-dx] = True
                old_fg[:, :width-dx] = previous["masks"]["foreground"][:, dx:]
            expected = {"foreground": fg, "background": ~fg, "backgroundPreviousInBounds": valid,
                "newlyRevealedBackground": (~fg) & valid & old_fg,
                "newViewportBackground": (~fg) & (~valid) if index else np.zeros_like(fg)}
            require(all(np.array_equal(masks[name], expected[name]) for name in MASKS), f"Geometric mask/partition mismatch at{index}")
            residuals = {key: arrays[name].astype(np.float64) - original for key, name in
                         zip(RESIDUALS, ("enhanced", "identity"))}
            regions = {}
            for name in REGIONS:
                mask, count = masks[name], int(masks[name].sum())
                temporal = {"supportPixels": 0, "reason": "empty region" if not count else
                    "no previous frame" if previous is None else "no visible same-material predecessor",
                    "originalCorrespondenceBitExact": None, **dict.fromkeys(RESIDUALS)}
                if previous is not None and count and name in ("background", "foreground"):
                    offset = geometry[name + "CurrentToPreviousPixelOffset"][0]
                    current_cols, prior_cols = slices(width, offset)
                    support = mask[:, current_cols] & previous["masks"][name][:, prior_cols]
                    support_count = int(support.sum())
                    temporal["supportPixels"] = support_count
                    if support_count:
                        require(np.array_equal(original[:, current_cols][support].view("<u4"),
                            previous["original"][:, prior_cols][support].view("<u4")), f"Original material correspondence failed:{index}:{name}")
                        temporal.update(reason=None, originalCorrespondenceBitExact=True)
                        temporal.update({key: metrics(residuals[key][:, current_cols][support] -
                            previous["residuals"][key][:, prior_cols][support]) for key in RESIDUALS})
                spatial = {key: metrics(residuals[key][mask]) for key in RESIDUALS}
                regions[name] = {"pixels": count, "spatial": spatial, "temporal": temporal}
                for key in RESIDUALS:
                    row = {"sourceFrameIndex": index, "ptsValue": index, "ptsTimescale": 30,
                        "durationValue": 1, "durationTimescale": 30, "phase": phase, "generation": frame["generation"],
                        "historyReset": frame["historyReset"], "usedModel": frame["usedModel"], "publicMotionRequested": requested_motion,
                        "region": name, "residual": key, "regionPixels": count, "temporalSupportPixels": temporal["supportPixels"],
                        "temporalUnavailableReason": temporal["reason"]}
                    row.update({metric: (spatial[key] or {}).get(metric) for metric in METRICS})
                    row.update({"temporal" + metric[0].upper() + metric[1:]: (temporal[key] or {}).get(metric) for metric in METRICS})
                    rows.append(row)
            ys, xs = np.nonzero(masks["newlyRevealedBackground"])
            camera = geometry["cameraWorldOffsetPixels"][0]
            if xs.size:
                cohorts.append({"index": index, "x": (xs + camera).astype(np.int32), "y": ys.astype(np.int32),
                    "original": original[ys, xs].view("<u4").copy(), "residual": residuals[RESIDUALS[0]][ys, xs].copy()})
            for cohort in cohorts:
                age = index - cohort["index"]
                if age not in AGES and index != 47:
                    continue
                x, y = cohort["x"] - camera, cohort["y"]
                visible = (x >= 0) & (x < width) & (y >= 0) & (y < height)
                eligible = np.flatnonzero(visible)
                visible[eligible] &= masks["background"][y[eligible], x[eligible]]
                count = int(visible.sum())
                current = residuals[RESIDUALS[0]][y[visible], x[visible]]
                if count:
                    require(np.array_equal(original[y[visible], x[visible]].view("<u4"), cohort["original"][visible]),
                            f"Original reveal-cohort correspondence failed:{cohort['index']}->{index}")
                report["cohorts"].append({"revealSourceFrameIndex": cohort["index"], "observedSourceFrameIndex": index,
                    "ageFrames": age, "finalObservation": index == 47, "cohortPixels": int(x.size), "supportPixels": count,
                    "originalCorrespondenceBitExact": True if count else None, "reason": None if count else "no visible same-material samples",
                    "enhancedMinusOriginal": metrics(current), "changeFromReveal": metrics(current - cohort["residual"][visible])})
            report["frames"].append({"sourceFrameIndex": index, "pts": frame["pts"], "duration": frame["duration"],
                "phase": phase, "historyReset": frame["historyReset"], "usedModel": frame["usedModel"],
                "publicMotionRequested": requested_motion, "source": item, "capture": frame, "regions": regions})
            previous = {"original": original, "residuals": residuals, "masks": masks}
            del arrays
            publish(report_path, report)
        with (output / "rows.csv").open("x", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader(); writer.writerows(rows)
        csv_pin = remember(output / "rows.csv")
        for path, expected_pin in list(pins.items()):
            remember(path, expected_pin)
        report.update(complete=True, allPinsUnchanged=True, pins=list(pins.values()), rowsCSV=csv_pin,
                      rowCount=len(rows), completedFrames=len(report["frames"]))
        publish(report_path, report)
        return report
    except BaseException as error:
        report.update(complete=False, failure=f"{type(error).__name__}: {error}", pins=list(pins.values()))
        try:
            publish(report_path, report)
        except OSError:
            pass
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise ValueError(report["failure"]) from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    analyze(args.input, args.capture, args.output)
    print(args.output / "report.json")


if __name__ == "__main__":
    main()
