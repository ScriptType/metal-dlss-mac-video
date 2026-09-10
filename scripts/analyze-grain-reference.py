#!/usr/bin/env python3
"""CPU same-ordinal input/output/residual observations for one grain-like arm.

All48 frames and47 adjacent pairs are retained. No inference or quality limit.
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

HERE = Path(__file__).resolve().parent
HELPER = HERE / "review-reference-sequence.py"
HELPER_SHA256 = "e5cd43fabb15a35da30ce109f93c888d64496233776f526f0189db356ab9c80e"
STATISTICS = HERE / "analyze-flash-reference.py"
STATISTICS_SHA256 = "f190e964198a872898fa68b67fa88dc15c5dc8987c0fe244e9f494afaf015098"
ARMS, SERIES, ADJACENT = ("control", "grain"), ("C", "R", "G", "Q", "D"), ("deltaG", "deltaQ", "deltaD")
SEED = "hdr-grain-reference-v1"
CANONICAL_CAPTURE_SETTINGS = {"colourStrength": 1, "maximumLuminanceRatio": 2,
    "mlxCacheBytes": 268435456, "modelInputRange": "bounded-sRGB-after-resample",
    "motionRequested": "automatic", "precision": "float16", "processingHeight": 288,
    "processingWidth": 512, "referenceWhiteNits": 203, "sceneCutThreshold": 0.3,
    "strength": 1, "temporal": True}
CANONICAL_RECIPE_SETTINGS = {key: value for key, value in CANONICAL_CAPTURE_SETTINGS.items()
                             if key not in ("mlxCacheBytes", "modelInputRange")}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical_settings_match(observed, expected):
    """Match JSON primitive kinds, allowing equivalent integer/float numbers."""
    if type(observed) is not dict or observed.keys() != expected.keys():
        return False
    for key, value in expected.items():
        actual = observed[key]
        if type(value) in (int, float):
            if type(actual) not in (int, float) or actual != value:
                return False
        elif type(actual) is not type(value) or actual != value:
            return False
    return True


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def phase(index):
    return "prefix" if index < 24 else "active" if index < 36 else "returnedInput"


def adjacent_phase(index):
    return "prefix" if index < 24 else "start" if index == 24 else "activeInterior" if index < 36 else "return" if index == 36 else "returnedInterior"


def expected_field(index, width, height):
    count, signs = width * height // 4, []
    for counter in range((count + 255) // 256):
        digest = hashlib.sha256(SEED.encode("ascii") + index.to_bytes(4, "little") + counter.to_bytes(4, "little")).digest()
        # Explicit byte/bit iteration independently checks the producer's unpackbits call.
        signs.extend(1 if byte & (1 << bit) else -1 for byte in digest for bit in range(8))
    return np.array(signs[:count], dtype=np.int8).reshape(height // 2, width // 2).repeat(2, 0).repeat(2, 1)


def analyze(grain_input, control_input, control_manifest, grain_manifest, output_dir):
    require(not sys.flags.optimize, "Python -O disables required capture assertions")
    output = Path(os.path.abspath(Path(output_dir).expanduser()))
    require(not os.path.lexists(output), "Output already exists, including dangling symlink")
    require(output.parent.is_dir(), "Output parent must exist")
    output = output.parent.resolve(strict=True) / output.name
    require(not os.path.lexists(output), "Resolved output already exists")
    output.mkdir()
    report = {"schemaVersion": 1, "complete": False, "pairedInterpretationAdmitted": False,
        "frames": [], "adjacentChanges": [], "prefixComparisons": [], "sourceProof": [],
        "scope": "Synthetic grain-like paired raw RGB component observations in nits; CPU analysis only.",
        "definitions": {"C": "E_control-O_control", "R": "E_grain-O_grain", "G": "O_grain-O_control",
            "Q": "E_grain-E_control", "D": "R-C", "deltaG": "G_i-G_(i-1)", "deltaQ": "Q_i-Q_(i-1)", "deltaD": "D_i-D_(i-1)"},
        "metricDefinition": "Same ordinal and source coordinates. Convert all Float32 RGB components to Float64 BEFORE subtraction; all components equally weighted, no luminance weighting.",
        "pooledDefinition": "RMS=sqrt(sumSquares/componentCount), not mean frame RMS. Maximum ties select earliest current ordinal then top-to-bottom row-major RGB component.",
        "limitations": ["No natural film-grain realism, exact zero-mean field, gain ratio, quality threshold or perceptual classification.",
            "Paired differences do not isolate noise, history, estimated flow or reconstruction as their sole cause.",
            "Public reset/model/motion-request fields do not reveal the actual selected flow backend or reset cause.",
            "Onset24 and removal36 have separate adjacent-change groups; no event or reset observation is excluded.",
            "Historical binary/model/source provenance is compared and retained, not re-executed by this analyzer.",
            "No playback, physical display or sustained source-rate acceptance."]}
    report_path = output / "report.json"
    pins = {}
    def publish():
        temporary = report_path.with_suffix(".tmp")
        with temporary.open("xb") as stream:
            stream.write((json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n").encode())
        temporary.replace(report_path)
    publish()
    try:
        def remember(path, expected=None):
            path = Path(os.path.abspath(path))
            require(path.is_file(), f"Missing regular input: {path}")
            with path.open("rb") as stream:
                sha = hashlib.file_digest(stream, "sha256").hexdigest()
            actual = {"path": str(path), "resolvedPath": str(path.resolve(strict=True)), "bytes": path.stat().st_size, "sha256": sha}
            require(expected is None or (type(expected.get("bytes")) is int and actual["bytes"] == expected["bytes"] and sha == expected.get("sha256")), f"Size/hash differs: {path}")
            require(str(path) not in pins or actual == pins[str(path)], f"Consumed input changed: {path}")
            pins[str(path)] = actual
            return actual
        def read(path):
            require(0 < Path(path).stat().st_size <= 1024**2, "JSON exceeds1MiB")
            value = json.loads(Path(path).read_bytes(), parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))
            require(isinstance(value, dict), "Expected JSON object")
            return value
        remember(Path(__file__).resolve())
        require(remember(HELPER)["sha256"] == HELPER_SHA256 and remember(STATISTICS)["sha256"] == STATISTICS_SHA256, "Pinned review/statistics helper changed")
        helper, stats = module("grain_capture_review", HELPER), module("grain_scalar_statistics", STATISTICS)
        def use(directory, entry):
            path = helper.contained(directory, entry["path"])
            remember(path, entry)
            return path
        def sha(value):
            return isinstance(value, str) and len(value) == 64 and all(x in "0123456789abcdef" for x in value)
        source_paths = {arm: Path(path).resolve(strict=True) for arm, path in zip(ARMS, (control_input, grain_input))}
        capture_paths = {arm: Path(path).resolve(strict=True) for arm, path in zip(ARMS, (control_manifest, grain_manifest))}
        sources, recipes, truths = {}, {}, {}
        for arm, path in source_paths.items():
            remember(path); source = sources[arm] = read(path)
            width, height = source["width"], source["height"]
            require(type(width) is int and type(height) is int and width in (160, 320, 640) and height * 16 == width * 9 and len(source["frames"]) == 48,
                    "Expected48 source frames at dyadic scale1/2/4")
            require(source["schemaVersion"] == 1 and source["layout"] == helper.LAYOUT and
                    (source["primaries"], source["transfer"], source["units"]) == ("BT.2020", "linear", "cd/m2"), "Source domain differs")
            provenance = source["provenance"]
            require(provenance["arm"] == arm, "Source arm identity differs")
            recipes[arm] = read(use(path.parent, provenance["recipe"]))
            require(canonical_settings_match(recipes[arm]["intendedCaptureSettings"], CANONICAL_RECIPE_SETTINGS),
                    "Recipe settings differ from canonical temporal capture contract")
            truths[arm] = read(use(path.parent, provenance["eventGroundTruth"]))
            environment = read(use(path.parent, provenance["environment"]))
            for entry in [provenance["generator"], provenance["sceneGenerator"], *environment["sourceFiles"].values()]:
                use(path.parent, entry)
            if arm == "grain":
                use(path.parent, provenance["arithmeticPreflight"])
        require((sources["control"]["width"], sources["control"]["height"]) == (width, height), "Source dimensions differ")
        recipe = recipes["grain"]
        require(recipe["name"] == "sha256-cell-contrast-grain-v1" and recipe["seed"] == SEED and recipe["frames"] == 48 and
                recipe["rate"] == {"numerator": 30, "denominator": 1} and recipe["scale"] == width // 160 and
                (recipe["width"], recipe["height"]) == (width, height) and recipe["grainSourceFrameIndices"] == list(range(24, 36)) and
                recipe["returnToBaseSourceFrameIndex"] == 36 and recipe["cellSizeSourcePixels"] == [2, 2] and
                recipe["amplitude"] == {"numerator": 1, "denominator": 32}, "Unsupported grain recipe")
        require(recipe["sceneGeneratorSHA256"] == sources["grain"]["provenance"]["sceneGenerator"]["sha256"] ==
                sources["control"]["provenance"]["sceneGenerator"]["sha256"], "Static scene provenance differs")
        require(truths["grain"]["eventSourceFrameIndices"] == list(range(24, 36)) and truths["grain"]["returnToBaseSourceFrameIndex"] == 36,
                "Grain event truth differs")
        base = None
        for index in range(48):
            originals = {}
            for arm in ARMS:
                item = sources[arm]["frames"][index]
                require(type(item["sourceFrameIndex"]) is int and item["sourceFrameIndex"] == index and item["pts"] == {"value": index, "timescale": 30} and
                        item["duration"] == {"value": 1, "timescale": 30}, "Exact source timing differs")
                use(source_paths[arm].parent, item)
                originals[arm] = helper.load_view(source_paths[arm].parent, item, width, height)
                require(bool((originals[arm] > 0).all()), "Source must be finite and positive")
            if base is None:
                base = originals["control"].copy()
            require(np.array_equal(originals["control"].view("<u4"), base.view("<u4")), "Control source is not static")
            item = sources["grain"]["frames"][index]
            proof = {"sourceFrameIndex": index, "controlSHA256": sources["control"]["frames"][index]["sha256"], "grainSHA256": item["sha256"]}
            if 24 <= index <= 35:
                field_meta = item["grainField"]
                require(field_meta["bytes"] == width * height and field_meta["layout"] == "int8 row-major source-sized sign field" and
                        (field_meta["width"], field_meta["height"]) == (width, height), "Grain field layout differs")
                field = np.fromfile(use(source_paths["grain"].parent, field_meta), dtype=np.int8).reshape(height, width)
                require(np.array_equal(field, expected_field(index, width, height)), f"SHA256 grain field differs at{index}")
                factor = np.float32(1) + field[:, :, None].astype(np.float32) / np.float32(32)
                expected = np.multiply(base, factor, dtype=np.float32)
                require(np.array_equal(originals["grain"].view("<u4"), expected.view("<u4")), f"Grain Float32 source product differs at{index}")
                rounding = originals["grain"].astype(np.float64) - base.astype(np.float64) * factor.astype(np.float64)
                proof.update(field=field_meta, fieldSHA256ContractExact=True, sourceFloat32ProductExact=True,
                    roundedComponents=int(np.count_nonzero(rounding)), maximumAbsoluteRoundingNits=float(np.abs(rounding).max()),
                    float64ProductExact=bool((rounding == 0).all()), actualMeanSign=float(field.astype(np.float64).mean()))
            else:
                require("grainField" not in item and np.array_equal(originals["grain"].view("<u4"), base.view("<u4")), f"Clean source differs at{index}")
                proof["cleanSourceBitExact"] = True
            report["sourceProof"].append(proof)
        require(truths["grain"]["baseRGBSHA256"] == sources["control"]["frames"][0]["sha256"], "Base source truth differs")
        captures, identities = {}, {}
        for arm, path in capture_paths.items():
            remember(path); header = read(path)
            require((header["width"], header["height"], len(header["frames"])) == (width, height, 48), "Expected48 matching capture frames")
            capture, _, _ = helper.validate_capture(path); captures[arm] = capture
            copied = helper.contained(path.parent, capture["inputManifestCopy"]); remember(copied)
            require(copied.read_bytes() == source_paths[arm].read_bytes() and capture["inputManifestSHA256"] == pins[str(source_paths[arm])]["sha256"] and
                    capture["sourceIdentity"] == "sha256:" + capture["inputManifestSHA256"], "Exact capture/source identity differs")
            require(capture["rawPayloadBytes"] == width * height * 48 * 48 and
                    canonical_settings_match(capture["settings"], CANONICAL_CAPTURE_SETTINGS),
                    "Capture settings/inventory differ from canonical temporal capture contract")
            runtime, model = capture["runtime"], capture["model"]
            require(sha(runtime["binarySHA256"]) and runtime["sourceSHA256"] and all(sha(x) for x in runtime["sourceSHA256"].values()), "Missing runtime hash identity")
            require({"manifest.json", "weights.safetensors"} <= set(model["files"]) and all(sha(x) for x in model["files"].values()), "Missing model hashes")
            identities[arm] = {"runtime": {**{key: value for key, value in runtime.items() if key not in ("arguments", "binary")}, "binary": str(Path(runtime["binary"]).resolve())},
                "model": {**model, "path": str(Path(model["path"]).resolve())}, "settings": capture["settings"], "device": capture.get("device")}
        require(identities["control"] == identities["grain"], "Matched runtime/model/settings/device identity differs")
        report.update(width=width, height=height, integerScale=width // 160, recipe=recipe,
            sourceMetadata={arm: {k: v for k, v in source.items() if k != "frames"} for arm, source in sources.items()},
            captureMetadata={arm: {k: v for k, v in capture.items() if k != "frames"} for arm, capture in captures.items()},
            inputManifests={arm: pins[str(path)] for arm, path in source_paths.items()}, captureManifests={arm: pins[str(path)] for arm, path in capture_paths.items()},
            matchedCaptureIdentity=identities["control"], environment={"python": platform.python_version(), "numpy": np.__version__})
        for index in range(24):
            for view in helper.VIEWS:
                entries = [captures[arm]["frames"][index]["views"][view] for arm in ARMS]
                actual = [pins[str(use(capture_paths[arm].parent, entry))] for arm, entry in zip(ARMS, entries)]
                report["prefixComparisons"].append({"sourceFrameIndex": index, "view": view, "controlSHA256": actual[0]["sha256"],
                    "grainSHA256": actual[1]["sha256"], "bytesEqual": all(actual[0][key] == actual[1][key] for key in ("bytes", "sha256"))})
        report["prefixAllFourViewsExact"] = all(row["bytesEqual"] for row in report["prefixComparisons"])
        require(report["prefixAllFourViewsExact"], "Pregrain prefix differs; paired interpretation is not admitted")
        rows, previous = [], None
        def append_rows(record, kind, observations):
            for name, metrics in record["metrics"].items():
                row = {"sampleKind": kind, "sourceFrameIndex": record["sourceFrameIndex"], "previousSourceFrameIndex": record.get("previousSourceFrameIndex"),
                    "ptsValue": record["sourceFrameIndex"], "ptsTimescale": 30, "durationValue": 1, "durationTimescale": 30, "phase": record["phase"], "metric": name,
                    "controlHistoryReset": observations["control"]["historyReset"], "grainHistoryReset": observations["grain"]["historyReset"],
                    **{key: value for key, value in metrics.items() if key != "maximumAbsoluteLocation"}}
                row.update({"maximum" + key[0].upper() + key[1:]: value for key, value in metrics["maximumAbsoluteLocation"].items()})
                rows.append(row)
        for index in range(48):
            arrays, observations = {}, {}
            for arm in ARMS:
                frame, item = captures[arm]["frames"][index], sources[arm]["frames"][index]
                require(frame["pts"] == item["pts"] and frame["duration"] == item["duration"] and frame["sourceFrameIndex"] == index and
                        type(frame["historyReset"]) is bool and frame["usedModel"] is True, "Capture timing/reset/model observation differs")
                observations[arm] = {key: frame[key] for key in ("generation", "historyReset", "usedModel", "knownInputDiscontinuities", "specificResetOrCutCause")}
                observations[arm].update(publicMotionRequested=captures[arm]["settings"]["motionRequested"], source=item, views=frame["views"])
                arrays[arm] = {}
                for view in helper.VIEWS:
                    use(capture_paths[arm].parent, frame["views"][view])
                    arrays[arm][view] = helper.load_view(capture_paths[arm].parent, frame["views"][view], width, height).astype(np.float64)
                require(frame["views"]["original"]["sha256"] == item["sha256"], "Original/source bytes differ")
            oc, ec, og, eg = arrays["control"]["original"], arrays["control"]["enhanced"], arrays["grain"]["original"], arrays["grain"]["enhanced"]
            values = {"C": ec - oc, "R": eg - og, "G": og - oc, "Q": eg - ec}
            values["D"] = values["R"] - values["C"]
            algebra = values["D"] - (values["Q"] - values["G"])
            record = {"sourceFrameIndex": index, "pts": {"value": index, "timescale": 30}, "duration": {"value": 1, "timescale": 30}, "phase": phase(index),
                "arms": observations, "metrics": {name: stats.statistics(values[name], index) for name in SERIES},
                "algebra": {"DExactlyEqualsQMinusG": bool((algebra == 0).all()), "maximumAbsoluteDifferenceNits": float(np.abs(algebra).max()),
                    "cleanDExactlyEqualsQ": bool(np.array_equal(values["D"], values["Q"])) if not 24 <= index <= 35 else None}}
            report["frames"].append(record)
            require(record["algebra"]["DExactlyEqualsQMinusG"] and record["algebra"]["cleanDExactlyEqualsQ"] is not False, "Float64 residual algebra identity differs; retained for review")
            append_rows(record, "frame", observations)
            if previous is not None:
                adjacent = {"sourceFrameIndex": index, "previousSourceFrameIndex": index - 1, "phase": adjacent_phase(index),
                    "metrics": {"delta" + name: stats.statistics(values[name] - previous[name], index) for name in ("G", "Q", "D")}}
                report["adjacentChanges"].append(adjacent); append_rows(adjacent, "adjacent", observations)
            previous = {name: values[name] for name in ("G", "Q", "D")}
        for key, records, scopes, names in (("pooledFramePhases", report["frames"], ("all", "prefix", "active", "returnedInput"), SERIES),
                ("pooledAdjacentPhases", report["adjacentChanges"], ("all", "prefix", "start", "activeInterior", "return", "returnedInterior"), ADJACENT)):
            report[key] = {scope: {name: stats.pooled([record["metrics"][name] for record in records if scope == "all" or record["phase"] == scope]) for name in names} for scope in scopes}
        for group in report["pooledAdjacentPhases"].values():
            for value in group.values():
                value["pairCount"] = value.pop("frameCount")
        report["historyResetOrdinals"] = {arm: [frame["sourceFrameIndex"] for frame in report["frames"] if frame["arms"][arm]["historyReset"]] for arm in ARMS}
        csv_path = output / "rows.csv"
        with csv_path.open("x", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator="\n"); writer.writeheader(); writer.writerows(rows)
        report["csv"] = {"path": csv_path.name, "bytes": csv_path.stat().st_size, "sha256": hashlib.sha256(csv_path.read_bytes()).hexdigest(),
            "rows": len(rows), "frameRows": 240, "adjacentRows": 141, "columns": list(rows[0])}
        report["pinsBefore"] = list(pins.values())
        report["pinsAfter"] = [remember(entry["path"]) for entry in list(pins.values())]
        require(report["pinsBefore"] == report["pinsAfter"], "Consumed files changed after processing")
        report.update(complete=True, pairedInterpretationAdmitted=True, allConsumedPinsUnchanged=True, verifiedCaptureViews=384, verifiedSourceFrames=96, verifiedGrainFields=12)
        publish()
        return report
    except BaseException as error:
        report.update(complete=False, pairedInterpretationAdmitted=False, failure=f"{type(error).__name__}: {error}")
        report.setdefault("pinsBefore", list(pins.values())); publish()
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("grain-input", "control-input", "control", "grain", "output"):
        parser.add_argument("--" + option, type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.grain_input, args.control_input, args.control, args.grain, args.output)
    print(json.dumps({"complete": result["complete"], "report": str(args.output / "report.json"), "frames": len(result["frames"]), "adjacentPairs": len(result["adjacentChanges"])}))
