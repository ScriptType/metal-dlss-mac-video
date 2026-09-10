"""Four synthetic CPU controls; all capture outputs/model flags are fabricated."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import math
from pathlib import Path
import shutil
import sys
import tempfile
import time
import unittest

import numpy as np

HERE = Path(__file__).resolve().parent
OBSERVATIONS = []


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


analysis = module("grain_analysis_subject", "analyze-grain-reference.py")
grain_generator = module("grain_analysis_generator", "generate-grain-reference.py")
flash_generator = module("grain_control_generator", "generate-flash-reference.py")
helper = module("grain_test_capture_helper", "review-reference-sequence.py")


def read(path):
    return json.loads(path.read_bytes())


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def pin(path):
    data = path.read_bytes()
    return {"path": path.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def drift(index):
    return 0 if index < 24 else (index - 30) / 64 if index < 36 else (index - 42) / 64


def fabricate(source_path, output, arm):
    output.mkdir()
    source = read(source_path)
    shutil.copyfile(source_path, output / "input-manifest.json")
    frames, weights = [], np.array([1, -2, 3], dtype=np.float64)
    for index, item in enumerate(source["frames"]):
        original = np.fromfile(source_path.parent / item["path"], dtype="<f4").reshape(90, 160, 3)
        residual = weights * (index**2 / 1024 + (drift(index) if arm == "grain" else 0))
        enhanced = (original.astype(np.float64) + residual).astype("<f4")
        np.testing.assert_array_equal(enhanced.astype(np.float64) - original, np.broadcast_to(residual, original.shape))
        folder = output / f"frame-{index:04d}"; folder.mkdir()
        views = {}
        for name, pixels in (("original", original), ("proxy", np.full_like(original, .5)), ("identity", original), ("enhanced", enhanced)):
            path = folder / (name + ".rgb32f"); path.write_bytes(pixels.astype("<f4").tobytes())
            views[name] = {**pin(path), "path": str(path.relative_to(output))}
        frames.append({"ordinal": index, "sourceFrameIndex": index, "pts": item["pts"], "duration": item["duration"],
            "inputPath": item["path"], "inputSHA256": item["sha256"], "generation": 1, "usedModel": True,
            "historyReset": index == 0 or (arm == "grain" and index == 36),
            "knownInputDiscontinuities": ["cold-start"] if index == 0 else [], "specificResetOrCutCause": "unavailable", "views": views})
    fake_sha = hashlib.sha256(b"fabricated CPU fixture, no model or native execution").hexdigest()
    settings = {**read(source_path.parent / "recipe.json")["intendedCaptureSettings"],
                "modelInputRange": "bounded-sRGB-after-resample", "mlxCacheBytes": 268435456}
    capture = {"schemaVersion": 1, "complete": True, "completedFrames": 48, "requestedFrames": 48,
        "width": 160, "height": 90, "layout": helper.LAYOUT, "views": list(helper.VIEWS),
        "referenceDomain": {"primaries": "BT.2020", "transfer": "linear", "units": "cd/m2"},
        "proxyDomain": {"primaries": "BT.709", "transfer": "sRGB", "units": "normalized0...1"},
        "rawPayloadBytes": 160 * 90 * 48 * 48, "generation": 1, "inputManifestCopy": "input-manifest.json",
        "inputManifestPath": str(source_path), "inputManifestSHA256": pin(source_path)["sha256"],
        "sourceIdentity": "sha256:" + pin(source_path)["sha256"], "provenance": source["provenance"], "settings": settings,
        "model": {"path": "/fabricated-grain-fixture/no-model", "files": {"manifest.json": fake_sha, "weights.safetensors": fake_sha}},
        "runtime": {"scope": "FABRICATED CPU outputs, including usedModel flags; no inference", "binary": "/fabricated-grain-fixture/no-binary",
            "binarySHA256": fake_sha, "sourceSHA256": {"fabricated-source-not-executed": fake_sha}, "arguments": [arm]}, "frames": frames}
    write(output / "manifest.json", capture)
    return output / "manifest.json"


class GrainReferenceAnalysisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="grain-analysis-cpu-"); cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.grain = cls.directory / "grain-input"; cls.control = cls.directory / "control-pair/control"
        with contextlib.redirect_stdout(io.StringIO()):
            flash_generator.generate(cls.control.parent, 1)
            grain_generator.generate(cls.grain, 1)
        cls.captures = {arm: fabricate(source / "manifest.json", cls.directory / (arm + "-capture"), arm)
                        for arm, source in (("control", cls.control), ("grain", cls.grain))}

    def assert_metric(self, observed, expected, index):
        count = expected.size; flat = expected.ravel()
        # fsum is independent of the analyzer's ndarray sums and provides known
        # pooled sums from the explicit fixture arrays, not captured outputs.
        sums = (math.fsum(float(x) for x in flat), math.fsum(abs(float(x)) for x in flat), math.fsum(float(x)**2 for x in flat))
        self.assertEqual(observed["componentCount"], count)
        for name, value in zip(("sumNits", "sumAbsoluteNits", "sumSquaredNits2"), sums):
            self.assertEqual(observed[name], value)
        for name, value in zip(("signedMeanNits", "meanAbsoluteNits", "rmsNits"), (sums[0] / count, sums[1] / count, math.sqrt(sums[2] / count))):
            self.assertAlmostEqual(observed[name], value, places=12)
        y, x, c = (int(x) for x in np.unravel_index(int(np.abs(expected).argmax()), expected.shape))
        self.assertEqual(observed["maximumAbsoluteLocation"], {"sourceFrameIndex": index, "x": x, "y": y, "channel": "RGB"[c]})
        self.assertEqual(observed["maximumAbsoluteNits"], abs(expected[y, x, c]))
        self.assertEqual(observed["signedValueAtMaximumNits"], expected[y, x, c])
        return sums

    def test_input_output_residual_algebra_adjacent_groups_and_pooling(self):
        report = analysis.analyze(self.grain / "manifest.json", self.control / "manifest.json", self.captures["control"], self.captures["grain"], self.directory / "valid")
        self.assertTrue(report["complete"] and report["pairedInterpretationAdmitted"] and report["allConsumedPinsUnchanged"])
        self.assertEqual((len(report["frames"]), len(report["adjacentChanges"]), report["csv"]["rows"]), (48, 47, 381))
        self.assertEqual((report["csv"]["frameRows"], report["csv"]["adjacentRows"]), (240, 141))
        self.assertEqual(report["historyResetOrdinals"], {"control": [0], "grain": [0, 36]})
        self.assertEqual(len(report["prefixComparisons"]), 96)
        self.assertTrue(all(row["bytesEqual"] for row in report["prefixComparisons"]))
        inputs = read(self.grain / "manifest.json")
        base = np.fromfile(self.grain / inputs["frames"][0]["path"], dtype="<f4").reshape(90, 160, 3).astype(np.float64)
        weights = np.broadcast_to(np.array([1, -2, 3], dtype=np.float64), base.shape)
        frame_sums, adjacent_sums, previous, nonzero_means = [], [], None, 0
        for index, frame in enumerate(report["frames"]):
            g = np.zeros_like(base)
            if 24 <= index <= 35:
                field = np.fromfile(self.grain / inputs["frames"][index]["grainField"]["path"], dtype=np.int8).reshape(90, 160)
                g = base * field[:, :, None] / 32  # Exact dyadic source at selected scale1.
            expected = {"C": weights * (index**2 / 1024), "R": weights * (index**2 / 1024 + drift(index)),
                        "G": g, "Q": g + weights * drift(index), "D": weights * drift(index)}
            frame_sums.append({name: self.assert_metric(frame["metrics"][name], values, index) for name, values in expected.items()})
            self.assertTrue(frame["algebra"]["DExactlyEqualsQMinusG"])
            if not 24 <= index <= 35:
                self.assertTrue(frame["algebra"]["cleanDExactlyEqualsQ"])
            nonzero_means += int(frame["metrics"]["G"]["signedMeanNits"] != 0)
            if previous is not None:
                row = report["adjacentChanges"][index - 1]
                self.assertEqual(row["previousSourceFrameIndex"], index - 1)
                adjacent_sums.append({"delta" + name: self.assert_metric(row["metrics"]["delta" + name], expected[name] - previous[name], index)
                                      for name in ("G", "Q", "D")})
            previous = expected
        self.assertGreater(nonzero_means, 0)  # No silent balancing/zero-mean assumption.
        phase_groups = {"prefix": list(range(24)), "active": list(range(24, 36)), "returnedInput": list(range(36, 48))}
        adjacent_groups = {"prefix": list(range(1, 24)), "start": [24], "activeInterior": list(range(25, 36)), "return": [36], "returnedInterior": list(range(37, 48))}
        for key, sums, groups, offset in (("pooledFramePhases", frame_sums, {"all": list(range(48)), **phase_groups}, 0),
                                        ("pooledAdjacentPhases", adjacent_sums, {"all": list(range(1, 48)), **adjacent_groups}, 1)):
            for group, indices in groups.items():
                for name, metric in report[key][group].items():
                    total = math.fsum(sums[i - offset][name][2] for i in indices)
                    self.assertEqual(metric["componentCount"], len(indices) * base.size)
                    self.assertEqual(metric["sumSquaredNits2"], total)
                    self.assertAlmostEqual(metric["rmsNits"], math.sqrt(total / (len(indices) * base.size)), places=12)
        self.assertEqual({row["sourceFrameIndex"] for row in report["adjacentChanges"] if row["phase"] in ("start", "return")}, {24, 36})
        pooled = report["pooledFramePhases"]["active"]["D"]["rmsNits"]
        wrong = sum(report["frames"][i]["metrics"]["D"]["rmsNits"] for i in range(24, 36)) / 12
        self.assertNotEqual(pooled, wrong)
        for target in (self.directory / "valid", self.directory / "dangling"):
            if target.name == "dangling": target.symlink_to(self.directory / "absent")
            with self.assertRaisesRegex(ValueError, "[Ee]xist"):
                analysis.analyze("missing", "missing", "missing", "missing", target)
        OBSERVATIONS.append({"case": "known quadratic control and grain/residual algebra", "frameMetricRecords": 240,
            "adjacentMetricRecords": 141, "onsetAndRemovalOrdinals": [24, 36], "nonzeroInputMeanFrames": nonzero_means,
            "activePooledResidualRMS": pooled, "incorrectMeanFrameRMS": wrong, "capturesFabricated": True})

    def test_resealed_prefix_difference_is_rejected(self):
        target = self.directory / "bad-prefix"; shutil.copytree(self.captures["grain"].parent, target)
        capture = read(target / "manifest.json"); entry = capture["frames"][8]["views"]["enhanced"]
        path = target / entry["path"]; values = np.fromfile(path, dtype="<f4"); values[0] += .125; path.write_bytes(values.tobytes())
        entry.update({key: pin(path)[key] for key in ("bytes", "sha256")}); write(target / "manifest.json", capture)
        helper.validate_capture(target / "manifest.json")
        output = self.directory / "bad-prefix-analysis"
        with self.assertRaisesRegex(ValueError, "Pregrain prefix"):
            analysis.analyze(self.grain / "manifest.json", self.control / "manifest.json", self.captures["control"], target / "manifest.json", output)
        failed = read(output / "report.json")
        self.assertFalse(failed["complete"] or failed["pairedInterpretationAdmitted"])
        self.assertEqual(sum(not row["bytesEqual"] for row in failed["prefixComparisons"]), 1)
        OBSERVATIONS.append({"case": "resealed enhanced prefix", "ordinaryCaptureValid": True, "pairRejected": True})

    def test_resealed_recipes_and_both_captures_reject_noncanonical_settings(self):
        numeric_equivalents = {key: float(value) if type(value) in (int, float) else value
                               for key, value in analysis.CANONICAL_CAPTURE_SETTINGS.items()}
        self.assertTrue(analysis.canonical_settings_match(numeric_equivalents, analysis.CANONICAL_CAPTURE_SETTINGS))
        for setting, altered in (("temporal", False), ("strength", True), ("colourStrength", True)):
            with self.subTest(setting=setting, altered=altered):
                sources, captures = {}, {}
                for arm, original in (("control", self.control), ("grain", self.grain)):
                    source = self.directory / (arm + "-" + setting + "-input")
                    target = self.directory / (arm + "-" + setting + "-capture")
                    shutil.copytree(original, source)
                    shutil.copytree(self.captures[arm].parent, target)
                    incoming, outgoing = read(source / "manifest.json"), read(target / "manifest.json")
                    recipe_path = source / incoming["provenance"]["recipe"]["path"]
                    recipe = read(recipe_path); recipe["intendedCaptureSettings"][setting] = altered
                    write(recipe_path, recipe)
                    incoming["provenance"]["recipe"].update({key: pin(recipe_path)[key] for key in ("bytes", "sha256")})
                    write(source / "manifest.json", incoming)
                    shutil.copyfile(source / "manifest.json", target / "input-manifest.json")
                    outgoing["settings"][setting] = altered
                    outgoing.update(inputManifestSHA256=pin(source / "manifest.json")["sha256"],
                        inputManifestPath=str(source / "manifest.json"),
                        sourceIdentity="sha256:" + pin(source / "manifest.json")["sha256"], provenance=incoming["provenance"])
                    write(target / "manifest.json", outgoing)
                    helper.validate_capture(target / "manifest.json")
                    # The former recipe-led settings predicate admits all three cases.
                    self.assertEqual(outgoing["settings"]["modelInputRange"], "bounded-sRGB-after-resample")
                    self.assertTrue(all(outgoing["settings"][key] == value for key, value in recipe["intendedCaptureSettings"].items()))
                    if setting != "temporal":
                        # Ordinary Python dictionary equality also accepts True == 1.
                        self.assertEqual(outgoing["settings"], analysis.CANONICAL_CAPTURE_SETTINGS)
                        self.assertEqual(recipe["intendedCaptureSettings"], analysis.CANONICAL_RECIPE_SETTINGS)
                    sources[arm], captures[arm] = source / "manifest.json", target / "manifest.json"
                self.assertEqual(read(captures["control"])["settings"], read(captures["grain"])["settings"])
                output = self.directory / (setting + "-analysis")
                with self.assertRaisesRegex(ValueError, "canonical temporal capture contract"):
                    analysis.analyze(sources["grain"], sources["control"], captures["control"], captures["grain"], output)
                failed = read(output / "report.json")
                self.assertFalse(failed["complete"] or failed["pairedInterpretationAdmitted"])
                self.assertEqual(failed["frames"], [])
                OBSERVATIONS.append({"case": "resealed recipes and both captures alter canonical setting",
                    "setting": setting, "alteredValue": altered, "ordinaryCapturesValid": 2,
                    "formerRecipeBasedSettingsPredicateAccepted": True,
                    "ordinaryCanonicalDictionaryEqualityAccepted": setting != "temporal",
                    "bothSourcesAndCaptureCopiesResealed": True, "canonicalContractRejected": True,
                    "equivalentIntFloatSettingsAccepted": True, "capturesFabricated": True})

    def test_resealed_field_and_matching_float32_pixels_reject_wrong_sha_stream(self):
        source, target = self.directory / "bad-field-input", self.directory / "bad-field-capture"
        shutil.copytree(self.grain, source); shutil.copytree(self.captures["grain"].parent, target)
        incoming, outgoing = read(source / "manifest.json"), read(target / "manifest.json")
        item = incoming["frames"][24]; field_path = source / item["grainField"]["path"]
        field = np.fromfile(field_path, dtype=np.int8).reshape(90, 160); field[:2, :2] *= -1
        field_path.write_bytes(field.tobytes()); item["grainField"].update({key: pin(field_path)[key] for key in ("bytes", "sha256")})
        positive, negative = int((field == 1).sum()), int((field == -1).sum())
        item["grainField"]["statistics"] = {"positivePixels": positive, "negativePixels": negative, "positiveCells": positive // 4,
            "negativeCells": negative // 4, "meanSign": (positive - negative) / field.size, "meanNominalMultiplier": 1 + (positive - negative) / (32 * field.size)}
        base = np.fromfile(source / incoming["frames"][0]["path"], dtype="<f4").reshape(90, 160, 3)
        altered = np.multiply(base, np.float32(1) + field[:, :, None].astype(np.float32) / np.float32(32), dtype=np.float32)
        path = source / item["path"]; path.write_bytes(altered.tobytes()); item.update({key: pin(path)[key] for key in ("bytes", "sha256")})
        item["statistics"] = flash_generator.statistics(altered)
        write(source / "manifest.json", incoming); shutil.copyfile(source / "manifest.json", target / "input-manifest.json")
        frame = outgoing["frames"][24]; frame["inputSHA256"] = item["sha256"]
        entry = frame["views"]["original"]; (target / entry["path"]).write_bytes(altered.tobytes())
        entry.update({key: pin(path)[key] for key in ("bytes", "sha256")})
        outgoing.update(inputManifestSHA256=pin(source / "manifest.json")["sha256"], inputManifestPath=str(source / "manifest.json"),
                        sourceIdentity="sha256:" + pin(source / "manifest.json")["sha256"])
        write(target / "manifest.json", outgoing); helper.validate_capture(target / "manifest.json")
        with self.assertRaisesRegex(ValueError, "SHA256 grain field differs at24"):
            analysis.analyze(source / "manifest.json", self.control / "manifest.json", self.captures["control"], target / "manifest.json", self.directory / "bad-field-analysis")
        OBSERVATIONS.append({"case": "resealed cell sign and matching Float32 source", "ordinaryCaptureValid": True,
                             "preserved2x2CellStructure": True, "deterministicFieldContractRejected": True})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False); parser.add_argument("--report", type=Path)
    options, arguments = parser.parse_known_args()
    if options.report and (options.report.exists() or options.report.is_symlink()): parser.error("--report must be a fresh path")
    paths = [Path(__file__), HERE / "analyze-grain-reference.py", HERE / "generate-grain-reference.py", HERE / "generate-flash-reference.py",
             HERE / "analyze-flash-reference.py", HERE / "prepare-occlusion-reference.py", HERE / "review-reference-sequence.py", HERE.parent / "pyproject.toml", HERE.parent / "uv.lock"]
    before = [{**pin(path), "path": str(path.resolve())} for path in paths]; started = time.monotonic_ns()
    program = unittest.main(argv=[sys.argv[0], *arguments], exit=False)
    after = [{**pin(path), "path": str(path.resolve())} for path in paths]; passed = program.result.wasSuccessful() and before == after
    if options.report:
        report = {"passed": passed, "testsRun": program.result.testsRun, "sourcesUnchanged": before == after, "sourcePinsBefore": before, "sourcePinsAfter": after,
            "python": sys.version, "numpy": np.__version__, "elapsedSeconds": (time.monotonic_ns() - started) / 1e9, "observations": OBSERVATIONS,
            "scope": "CPU generated inputs and fabricated captures; no model/GPU/native execution.",
            "failures": [{"test": test.id(), "traceback": trace} for test, trace in program.result.failures],
            "errors": [{"test": test.id(), "traceback": trace} for test, trace in program.result.errors], "skipped": [{"test": test.id(), "reason": reason} for test, reason in program.result.skipped]}
        with options.report.open("x") as stream:
            json.dump(report, stream, indent=2, sort_keys=True, allow_nan=False); stream.write("\n")
    raise SystemExit(0 if passed else 1)
