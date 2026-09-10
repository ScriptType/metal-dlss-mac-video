#!/usr/bin/env python3
"""CPU same-ordinal residual analysis of a complete paired global-flash capture.

Use --input-pair PAIR.json --control CONTROL/manifest.json
--flash FLASH/manifest.json --output NEW_DIRECTORY. No model is executed.
"""
import argparse
import csv
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import sys

import numpy as np

HELPER = Path(__file__).with_name("review-reference-sequence.py")
HELPER_SHA256 = "e5cd43fabb15a35da30ce109f93c888d64496233776f526f0189db356ab9c80e"
ARMS = ("control", "flash")
RESIDUALS = ("controlEnhancedMinusOriginal", "flashEnhancedMinusOriginal", "pairedResidualDifference")
METRICS = ("signedMeanNits", "meanAbsoluteNits", "rmsNits", "maximumAbsoluteNits")
PHASES = ("prefix", "event", "returnedInput")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n").encode()


def publish(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("xb") as stream:
        stream.write(encoded(value))
    temporary.replace(path)


def statistics(values, index):
    require(values.dtype == np.float64 and values.size > 0 and bool(np.isfinite(values).all()),
            "Expected nonempty finite Float64 residuals")
    absolute = np.abs(values)
    y, x, channel = (int(v) for v in np.unravel_index(int(absolute.argmax()), values.shape))
    count = int(values.size)
    total, absolute_total, squared = (float(values.sum()), float(absolute.sum()), float(np.square(values).sum()))
    return {"componentCount": count, "sumNits": total, "sumAbsoluteNits": absolute_total,
        "sumSquaredNits2": squared, "signedMeanNits": total / count, "meanAbsoluteNits": absolute_total / count,
        "rmsNits": float(np.sqrt(squared / count)), "maximumAbsoluteNits": float(absolute[y, x, channel]),
        "maximumAbsoluteLocation": {"sourceFrameIndex": index, "x": x, "y": y, "channel": "RGB"[channel]},
        "signedValueAtMaximumNits": float(values[y, x, channel])}


def pooled(records):
    count = sum(x["componentCount"] for x in records)
    result = {key: sum(x[key] for x in records) for key in ("sumNits", "sumAbsoluteNits", "sumSquaredNits2")}
    maximum = max(records, key=lambda x: x["maximumAbsoluteNits"])
    result.update(componentCount=count, frameCount=len(records), signedMeanNits=result["sumNits"] / count,
        meanAbsoluteNits=result["sumAbsoluteNits"] / count, rmsNits=float(np.sqrt(result["sumSquaredNits2"] / count)))
    result.update({key: maximum[key] for key in ("maximumAbsoluteNits", "maximumAbsoluteLocation", "signedValueAtMaximumNits")})
    return result


def phase(index):
    return "prefix" if index < 24 else "event" if index == 24 else "returnedInput"


def analyze(input_pair, control_manifest, flash_manifest, output_dir):
    require(not sys.flags.optimize, "Python -O disables required capture assertions")
    output = Path(os.path.abspath(Path(output_dir).expanduser()))
    require(not os.path.lexists(output), "Output already exists, including dangling symlink")
    require(output.parent.is_dir(), "Output parent must exist")
    output = output.parent.resolve(strict=True) / output.name
    require(not os.path.lexists(output), "Resolved output already exists")
    output.mkdir()
    report = {"schemaVersion": 1, "complete": False, "pairedInterpretationAdmitted": False,
        "frames": [], "prefixComparisons": [], "scope": "Synthetic paired raw RGB component residuals in nits; CPU analysis only.",
        "metricDefinition": "Float64 conversion before subtraction: C=E_C-O_C, F=E_F-O_F, D=F-C at the SAME ordinal. All RGB components equally weighted; no luminance weighting.",
        "pooledDefinition": "RMS=sqrt(sum of per-component squared residuals / total component count); never the mean of frame RMS values. Max ties choose earliest ordinal then row-major RGB component.",
        "limitations": ["Event24 and returned-input25...47 are reported separately; no frame is excluded from metrics.",
            "Returned-input differences are observations after the earlier flash, not proof of ghosting or an ideal-target error.",
            "Public historyReset/usedModel/motionRequested fields do not identify selected flow backend or reset cause.",
            "No noise/history isolation, quality threshold, causal percentages, playback or physical HDR acceptance.",
            "Capture provenance is compared and retained; historical binary/model/source identifiers are not claims that those files were re-executed or rehashed by this analyzer."]}
    report_path = output / "report.json"
    publish(report_path, report)
    pins = {}
    try:
        def remember(path, expected=None):
            path = Path(os.path.abspath(path))
            require(path.is_file(), f"Missing regular input: {path}")
            with path.open("rb") as stream:
                sha = hashlib.file_digest(stream, "sha256").hexdigest()
            actual = {"path": str(path), "resolvedPath": str(path.resolve(strict=True)), "bytes": path.stat().st_size, "sha256": sha}
            if expected is not None:
                require(type(expected.get("bytes")) is int and actual["bytes"] == expected["bytes"] and
                        sha == expected.get("sha256"), f"Size/hash mismatch: {path}")
            require(str(path) not in pins or actual == pins[str(path)], f"Input changed during analysis: {path}")
            pins[str(path)] = actual
            return actual
        def read(path):
            require(0 < Path(path).stat().st_size <= 1024**2, "JSON exceeds 1-MiB bound")
            value = json.loads(Path(path).read_bytes(), parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))
            require(isinstance(value, dict), "Expected JSON object")
            return value
        remember(Path(__file__).resolve())
        require(remember(HELPER.resolve())["sha256"] == HELPER_SHA256, "Reviewed capture helper changed")
        spec = importlib.util.spec_from_file_location("flash_capture_review", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        def use(directory, metadata):
            path = helper.contained(directory, metadata["path"])
            remember(path, metadata)
            return path
        def valid_sha(value):
            return isinstance(value, str) and len(value) == 64 and all(x in "0123456789abcdef" for x in value)
        pair_path = Path(input_pair).resolve(strict=True)
        remember(pair_path)
        pair = read(pair_path)
        require(pair.get("schemaVersion") == 1 and pair.get("complete") is True and set(pair["arms"]) == set(ARMS) and
                pair["pairedDifferentSourceFrameIndices"] == [24], "Expected complete canonical flash pair")
        source_paths = {arm: use(pair_path.parent, pair["arms"][arm]) for arm in ARMS}
        sources = {arm: read(path) for arm, path in source_paths.items()}
        width, height = sources["control"]["width"], sources["control"]["height"]
        require(type(width) is int and type(height) is int and width in (160, 320, 640) and height * 16 == width * 9,
                "Expected dyadic scale1/2/4 dimensions")
        require(pair["frameBytes"] == width * height * 12 and pair["pairedRGBBytes"] == width * height * 12 * 96 and
                pair["expectedTwoFourViewCaptureBytes"] == width * height * 48 * 96, "Paired payload inventory differs")
        recipes, truths = {}, {}
        for arm, source in sources.items():
            require(source["schemaVersion"] == 1 and source["layout"] == helper.LAYOUT and
                    (source["width"], source["height"]) == (width, height) and len(source["frames"]) == 48 and
                    (source["primaries"], source["transfer"], source["units"]) == ("BT.2020", "linear", "cd/m2"), "Source schema differs")
            directory = source_paths[arm].parent; provenance = source["provenance"]
            require(provenance["arm"] == arm, "Source arm provenance differs")
            recipes[arm] = recipe = read(use(directory, provenance["recipe"]))
            truths[arm] = truth = read(use(directory, provenance["eventGroundTruth"]))
            environment = read(use(directory, provenance["environment"]))
            for entry in [provenance["generator"], provenance["sceneGenerator"], *environment["sourceFiles"].values()]:
                use(directory, entry)
            require(recipe["framesPerArm"] == 48 and recipe["rate"] == {"numerator": 30, "denominator": 1} and
                    recipe["scale"] == width // 160 and (recipe["width"], recipe["height"]) == (width, height) and
                    recipe["sceneGeneratorSHA256"] == provenance["sceneGenerator"]["sha256"] and
                    recipe["flashSourceFrameIndex"] == 24 and recipe["flashMultiplier"] == {"numerator": 3, "denominator": 2},
                    "Unsupported paired flash recipe")
            require(truth["arm"] == arm and truth["eventSourceFrameIndices"] == ([24] if arm == "flash" else []) and
                    truth["pairedDifferentSourceFrameIndices"] == [24], "Event ground truth differs")
        require(recipes["control"] == recipes["flash"], "Arm recipes differ")
        # Read source payloads independently of captured originals; require one static
        # control and precisely the declared multiplicative event, not metadata alone.
        base, differences = None, []
        for index in range(48):
            originals = {}
            for arm in ARMS:
                item = sources[arm]["frames"][index]
                require(type(item["sourceFrameIndex"]) is int and item["sourceFrameIndex"] == index and
                        item["pts"] == {"value": index, "timescale": 30} and item["duration"] == {"value": 1, "timescale": 30},
                        "Exact source timing/order differs")
                use(source_paths[arm].parent, item)
                originals[arm] = helper.load_view(source_paths[arm].parent, item, width, height)
                require(bool((originals[arm] > 0).all()), "Source must be finite and positive")
            if base is None:
                base = originals["control"].copy()
            require(np.array_equal(originals["control"].view("<u4"), base.view("<u4")), "Control source is not constant")
            same = np.array_equal(originals["flash"].view("<u4"), base.view("<u4"))
            if not same:
                differences.append(index)
            require(np.array_equal(originals["flash"].astype(np.float64), base.astype(np.float64) * 1.5) if index == 24 else same,
                    f"Source flash must occur only at24 with exact Float64 product; mismatch at{index}")
        require(differences == [24], "Missing declared source flash")
        base_sha = sources["control"]["frames"][0]["sha256"]
        flash_sha = sources["flash"]["frames"][24]["sha256"]
        require(all(truth["baseRGBSHA256"] == base_sha and truth["flashRGBSHA256"] == flash_sha
                    for truth in truths.values()), "Event truth source hashes differ")
        capture_paths = {arm: Path(path).resolve(strict=True) for arm, path in zip(ARMS, (control_manifest, flash_manifest))}
        captures, identities = {}, {}
        for arm, path in capture_paths.items():
            remember(path)
            header = read(path)
            require((header["width"], header["height"], len(header["frames"])) == (width, height, 48), "Expected all48 paired capture frames")
            capture, _, _ = helper.validate_capture(path)
            captures[arm] = capture
            copied = helper.contained(path.parent, capture["inputManifestCopy"])
            remember(copied)
            require(copied.read_bytes() == source_paths[arm].read_bytes() and capture["inputManifestSHA256"] == pins[str(source_paths[arm])]["sha256"] and
                    capture["sourceIdentity"] == "sha256:" + capture["inputManifestSHA256"], "Exact source copy/identity differs")
            require(capture["rawPayloadBytes"] == width * height * 48 * 48 and capture["settings"]["modelInputRange"] == "bounded-sRGB-after-resample" and
                    all(capture["settings"][key] == value for key, value in recipes[arm]["intendedCaptureSettings"].items()), "Capture settings/payload inventory differs")
            runtime, model = capture["runtime"], capture["model"]
            require(valid_sha(runtime["binarySHA256"]) and isinstance(runtime["sourceSHA256"], dict) and runtime["sourceSHA256"] and
                    all(valid_sha(x) for x in runtime["sourceSHA256"].values()), "Missing runtime binary/source hash identities")
            require(isinstance(model["files"], dict) and {"manifest.json", "weights.safetensors"} <= set(model["files"]) and
                    all(valid_sha(x) for x in model["files"].values()), "Missing model file identities")
            identities[arm] = {"runtime": {**{key: value for key, value in runtime.items() if key not in ("arguments", "binary")},
                    "binary": str(Path(runtime["binary"]).resolve())},
                "model": {**model, "path": str(Path(model["path"]).resolve())}, "settings": capture["settings"], "device": capture.get("device")}
        require(identities["control"] == identities["flash"], "Arm settings/model/runtime identities differ")
        report.update(width=width, height=height, integerScale=width // 160, inputPair=pins[str(pair_path)], pairMetadata=pair,
            sourceMetadata={arm: {key: value for key, value in source.items() if key != "frames"} for arm, source in sources.items()},
            captureMetadata={arm: {key: value for key, value in capture.items() if key != "frames"} for arm, capture in captures.items()},
            inputManifests={arm: pins[str(path)] for arm, path in source_paths.items()},
            captureManifests={arm: pins[str(path)] for arm, path in capture_paths.items()}, matchedCaptureIdentity=identities["control"],
            inputProof={"differentOrdinals": differences, "all48ControlFramesBitExact": True, "all47OtherPairedFramesBitExact": True,
                "event24ExactFloat64Multiply": True, "returnedInputOrdinals": list(range(25, 48))},
            environment={"python": platform.python_version(), "numpy": np.__version__})
        for index in range(24):
            for name in helper.VIEWS:
                entries = [captures[arm]["frames"][index]["views"][name] for arm in ARMS]
                actual = [pins[str(use(capture_paths[arm].parent, entry))] for arm, entry in zip(ARMS, entries)]
                report["prefixComparisons"].append({"sourceFrameIndex": index, "view": name,
                    "controlSHA256": actual[0]["sha256"], "flashSHA256": actual[1]["sha256"],
                    "bytesEqual": actual[0]["sha256"] == actual[1]["sha256"] and actual[0]["bytes"] == actual[1]["bytes"]})
        report["prefixAllFourViewsExact"] = all(x["bytesEqual"] for x in report["prefixComparisons"])
        require(report["prefixAllFourViewsExact"], "Preflash prefix differs; paired interpretation is not admitted")
        rows = []
        for index in range(48):
            arrays, observations = {}, {}
            for arm in ARMS:
                frame, item = captures[arm]["frames"][index], sources[arm]["frames"][index]
                require(frame["pts"] == item["pts"] and frame["duration"] == item["duration"] and frame["sourceFrameIndex"] == index and
                        type(frame["historyReset"]) is bool and frame["usedModel"] is True, "Exact capture timing/reset/model observation differs")
                observations[arm] = {key: frame[key] for key in ("generation", "historyReset", "usedModel", "knownInputDiscontinuities", "specificResetOrCutCause")}
                observations[arm].update(publicMotionRequested=captures[arm]["settings"]["motionRequested"], source=item, views=frame["views"])
                arrays[arm] = {}
                for name in helper.VIEWS:
                    use(capture_paths[arm].parent, frame["views"][name])
                    arrays[arm][name] = helper.load_view(capture_paths[arm].parent, frame["views"][name], width, height).astype(np.float64)
                require(frame["views"]["original"]["sha256"] == item["sha256"], "Original source bytes differ")
            c, f = (arrays[arm]["enhanced"] - arrays[arm]["original"] for arm in ARMS)
            delta = f - c
            returned_exact = bool(np.array_equal(delta, arrays["flash"]["enhanced"] - arrays["control"]["enhanced"])) if index > 24 else None
            require(index <= 24 or returned_exact, "Returned-input residual/direct enhanced difference identity failed")
            stats = {name: statistics(values, index) for name, values in zip(RESIDUALS, (c, f, delta))}
            frame_report = {"sourceFrameIndex": index, "pts": {"value": index, "timescale": 30}, "duration": {"value": 1, "timescale": 30},
                "phase": phase(index), "arms": observations, "metrics": stats, "returnedInputDirectDifferenceExact": returned_exact}
            report["frames"].append(frame_report)
            for name, values in stats.items():
                row = {"sourceFrameIndex": index, "ptsValue": index, "ptsTimescale": 30, "durationValue": 1, "durationTimescale": 30,
                    "phase": phase(index), "residual": name, "controlHistoryReset": observations["control"]["historyReset"],
                    "flashHistoryReset": observations["flash"]["historyReset"], "publicMotionRequested": captures["control"]["settings"]["motionRequested"]}
                row.update({key: value for key, value in values.items() if key != "maximumAbsoluteLocation"})
                row.update({"maximum" + key[0].upper() + key[1:]: value for key, value in values["maximumAbsoluteLocation"].items()})
                rows.append(row)
        report["pooledPhases"] = {scope: {name: pooled([frame["metrics"][name] for frame in report["frames"]
            if scope == "all" or frame["phase"] == scope]) for name in RESIDUALS} for scope in ("all", *PHASES)}
        report["historyResetOrdinals"] = {arm: [frame["sourceFrameIndex"] for frame in report["frames"] if frame["arms"][arm]["historyReset"]] for arm in ARMS}
        csv_path = output / "rows.csv"
        with csv_path.open("x", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator="\n")
            writer.writeheader(); writer.writerows(rows)
        report["csv"] = {"path": csv_path.name, "bytes": csv_path.stat().st_size,
            "sha256": hashlib.sha256(csv_path.read_bytes()).hexdigest(), "rows": len(rows), "columns": list(rows[0])}
        report["pinsBefore"] = list(pins.values())
        report["pinsAfter"] = [remember(entry["path"]) for entry in list(pins.values())]
        require(report["pinsAfter"] == report["pinsBefore"], "Consumed files changed after processing")
        report.update(complete=True, pairedInterpretationAdmitted=True, allConsumedPinsUnchanged=True,
                      verifiedCaptureViews=384, verifiedSourceFrames=96)
        publish(report_path, report)
        return report
    except BaseException as error:
        report.update(complete=False, pairedInterpretationAdmitted=False, failure=f"{type(error).__name__}: {error}")
        report.setdefault("pinsBefore", list(pins.values()))
        publish(report_path, report)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("input-pair", "control", "flash", "output"):
        parser.add_argument("--" + option, type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.input_pair, args.control, args.flash, args.output)
    print(json.dumps({"complete": result["complete"], "report": str(args.output / "report.json"), "frames": len(result["frames"])}))
