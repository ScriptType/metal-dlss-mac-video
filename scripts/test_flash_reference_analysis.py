"""Four CPU controls using fabricated outputs; no model, native runtime or GPU."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
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
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


analysis = module("flash_analysis_test_subject", "analyze-flash-reference.py")
generator = module("flash_analysis_test_generator", "generate-flash-reference.py")
helper = module("flash_analysis_test_capture_helper", "review-reference-sequence.py")


def read(path):
    return json.loads(path.read_bytes())


def write(path, value):
    path.write_bytes((json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n").encode())


def pin(path):
    data = path.read_bytes()
    return {"path": path.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def coefficient(index):
    return 0 if index < 24 else 2 if index == 24 else index - 36


def fabricate(source_path, output, arm):
    """Control residual=i²*[1,-2,3]; flash adds t(i)*[1,-2,3].

    The nonconstant i² field rejects comparison with an earlier control frame.
    Signed returned-input t spans -11...11, so RMS pooling cannot accidentally
    pass by averaging per-frame RMS. All sums are exact dyadic Float32 here.
    Even usedModel=true below is fabricated schema data, never actual inference.
    """
    output.mkdir()
    source = read(source_path)
    width, height = source["width"], source["height"]
    shutil.copyfile(source_path, output / "input-manifest.json")
    frames = []
    for index, frame in enumerate(source["frames"]):
        original = np.fromfile(source_path.parent / frame["path"], dtype="<f4").reshape(height, width, 3)
        value = index**2 + (coefficient(index) if arm == "flash" else 0)
        residual = np.array([value, -2 * value, 3 * value], dtype=np.float64)
        enhanced = (original.astype(np.float64) + residual).astype("<f4")
        np.testing.assert_array_equal(enhanced.astype(np.float64) - original,
                                      np.broadcast_to(residual, original.shape))
        folder = output / f"frame-{index:04d}"
        folder.mkdir()
        views = {}
        for name, rgb in (("original", original), ("proxy", np.full_like(original, .5)),
                          ("identity", original), ("enhanced", enhanced)):
            path = folder / (name + ".rgb32f")
            path.write_bytes(rgb.astype("<f4").tobytes())
            views[name] = {**pin(path), "path": str(path.relative_to(output))}
        frames.append({"ordinal": index, "sourceFrameIndex": index, "pts": frame["pts"], "duration": frame["duration"],
            "inputPath": frame["path"], "inputSHA256": frame["sha256"], "generation": 1, "usedModel": True,
            "historyReset": index == 0 or (arm == "flash" and index == 24),
            "knownInputDiscontinuities": ["cold-start"] if index == 0 else [],
            "specificResetOrCutCause": "unavailable", "views": views})
    settings = {**read(source_path.parent / "recipe.json")["intendedCaptureSettings"],
                "modelInputRange": "bounded-sRGB-after-resample", "mlxCacheBytes": 268435456}
    fake_sha = hashlib.sha256(b"fabricated CPU fixture; no runtime/model/source executed").hexdigest()
    manifest = {"schemaVersion": 1, "complete": True, "completedFrames": 48, "requestedFrames": 48,
        "width": width, "height": height, "layout": helper.LAYOUT, "views": list(helper.VIEWS),
        "referenceDomain": {"primaries": "BT.2020", "transfer": "linear", "units": "cd/m2"},
        "proxyDomain": {"primaries": "BT.709", "transfer": "sRGB", "units": "normalized0...1"},
        "rawPayloadBytes": width * height * 48 * 48, "generation": 1, "inputManifestCopy": "input-manifest.json",
        "inputManifestPath": str(source_path), "inputManifestSHA256": pin(source_path)["sha256"],
        "sourceIdentity": "sha256:" + pin(source_path)["sha256"], "provenance": source["provenance"], "settings": settings,
        "model": {"path": "/fabricated-cpu-fixture/no-model", "files": {"manifest.json": fake_sha, "weights.safetensors": fake_sha}},
        "runtime": {"scope": "FABRICATED CPU capture; no model/GPU executed", "binary": "/fabricated-cpu-fixture/no-binary",
            "binarySHA256": fake_sha, "sourceSHA256": {"fabricated-source-not-executed": fake_sha}, "arguments": [arm]},
        "frames": frames}
    write(output / "manifest.json", manifest)
    return output / "manifest.json"


class FlashReferenceAnalysisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="flash-analysis-cpu-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.input = cls.directory / "input"
        with contextlib.redirect_stdout(io.StringIO()):
            generator.generate(cls.input, 1)
        cls.captures = {arm: fabricate(cls.input / arm / "manifest.json", cls.directory / arm, arm) for arm in analysis.ARMS}

    def test_same_ordinal_signed_metrics_and_pooled_rms(self):
        report = analysis.analyze(self.input / "pair.json", self.captures["control"], self.captures["flash"], self.directory / "valid")
        self.assertTrue(report["complete"] and report["pairedInterpretationAdmitted"] and report["allConsumedPinsUnchanged"])
        self.assertEqual(report["csv"]["rows"], 144)
        self.assertEqual(len(report["prefixComparisons"]), 96)
        self.assertTrue(all(x["bytesEqual"] for x in report["prefixComparisons"]))
        self.assertEqual(report["historyResetOrdinals"], {"control": [0], "flash": [0, 24]})
        count = 160 * 90 * 3
        for index, frame in enumerate(report["frames"]):
            values = (index**2, index**2 + coefficient(index), coefficient(index))
            for name, value in zip(analysis.RESIDUALS, values):
                metrics = frame["metrics"][name]
                self.assertEqual(metrics["componentCount"], count)
                self.assertAlmostEqual(metrics["signedMeanNits"], 2 * value / 3)
                self.assertEqual(metrics["meanAbsoluteNits"], 2 * abs(value))
                self.assertAlmostEqual(metrics["rmsNits"], abs(value) * np.sqrt(14 / 3))
                self.assertEqual(metrics["maximumAbsoluteNits"], 3 * abs(value))
                self.assertEqual(metrics["maximumAbsoluteLocation"], {"sourceFrameIndex": index, "x": 0, "y": 0,
                                                                    "channel": "B" if value else "R"})
                self.assertEqual(metrics["signedValueAtMaximumNits"], 3 * value)
            self.assertIs(frame["returnedInputDirectDifferenceExact"], True if index > 24 else None)
        for name, indices in (("all", range(48)), ("prefix", range(24)), ("event", [24]), ("returnedInput", range(25, 48))):
            expected = float(np.sqrt(np.mean([coefficient(index)**2 for index in indices]) * 14 / 3))
            actual = report["pooledPhases"][name]["pairedResidualDifference"]
            self.assertEqual(actual["componentCount"], len(indices) * count)
            self.assertAlmostEqual(actual["rmsNits"], expected)
        returned = report["pooledPhases"]["returnedInput"]["pairedResidualDifference"]
        self.assertEqual(returned["signedMeanNits"], 0)
        wrong_mean_rms = float(np.mean([abs(coefficient(i)) * np.sqrt(14 / 3) for i in range(25, 48)]))
        self.assertGreater(returned["rmsNits"] - wrong_mean_rms, 1)
        # Fresh-path refusal must precede input access and preserve the prior report.
        previous = (self.directory / "valid/report.json").read_bytes()
        for target in (self.directory / "valid", self.directory / "dangling"):
            if target.name == "dangling":
                target.symlink_to(self.directory / "absent")
            with self.assertRaisesRegex(ValueError, "[Ee]xist"):
                analysis.analyze("missing", "missing", "missing", target)
        self.assertEqual((self.directory / "valid/report.json").read_bytes(), previous)
        OBSERVATIONS.append({"case": "same-ordinal dyadic RGB residuals", "frames": 48, "metricRows": 144,
            "returnedInputPooledRMS": returned["rmsNits"], "incorrectMeanFrameRMS": wrong_mean_rms,
            "resetFlagsAreObservations": True, "capturesFabricated": True})

    def test_resealed_changed_prefix_rejects_paired_interpretation(self):
        target = self.directory / "bad-prefix"
        shutil.copytree(self.captures["flash"].parent, target)
        capture = read(target / "manifest.json")
        entry = capture["frames"][8]["views"]["enhanced"]
        path = target / entry["path"]
        pixels = np.fromfile(path, dtype="<f4")
        pixels[0] += 1
        path.write_bytes(pixels.tobytes())
        entry.update({key: pin(path)[key] for key in ("bytes", "sha256")})
        write(target / "manifest.json", capture)
        helper.validate_capture(target / "manifest.json")  # Valid hashes/layout; pairing alone is wrong.
        output = self.directory / "bad-prefix-analysis"
        with self.assertRaisesRegex(ValueError, "Preflash prefix"):
            analysis.analyze(self.input / "pair.json", self.captures["control"], target / "manifest.json", output)
        failed = read(output / "report.json")
        self.assertFalse(failed["complete"] or failed["pairedInterpretationAdmitted"])
        self.assertEqual(len(failed["prefixComparisons"]), 96)
        self.assertEqual(sum(not row["bytesEqual"] for row in failed["prefixComparisons"]), 1)
        OBSERVATIONS.append({"case": "resealed changed prefix", "ordinaryCaptureValidationPassed": True, "pairRejected": True})

    def test_resealed_pair_requires_typed_canonical_settings(self):
        cases = (("non-temporal", {"temporal": False}, True, False),
                 ("boolean-strength", {"strength": True}, True, False),
                 ("boolean-colour", {"colourStrength": True}, True, False),
                 ("capture-only-boolean-strength", {"strength": True}, False, False),
                 ("numeric-equivalents", {"strength": 1.0, "colourStrength": 1.0}, True, True))
        for label, altered, change_recipe, accepted in cases:
            with self.subTest(case=label):
                directory = self.directory / label
                directory.mkdir()
                source = directory / "input"
                shutil.copytree(self.input, source)
                pair, captures = read(source / "pair.json"), {}
                for arm in analysis.ARMS:
                    target = directory / arm
                    shutil.copytree(self.captures[arm].parent, target)
                    source_path = source / arm / "manifest.json"
                    incoming, outgoing = read(source_path), read(target / "manifest.json")
                    recipe_path = source_path.parent / incoming["provenance"]["recipe"]["path"]
                    recipe = read(recipe_path)
                    if change_recipe:
                        recipe["intendedCaptureSettings"].update(altered)
                        write(recipe_path, recipe)
                    incoming["provenance"]["recipe"].update({key: pin(recipe_path)[key] for key in ("bytes", "sha256")})
                    write(source_path, incoming)
                    pair["arms"][arm].update({key: pin(source_path)[key] for key in ("bytes", "sha256")})
                    shutil.copyfile(source_path, target / "input-manifest.json")
                    outgoing["settings"].update(altered)
                    outgoing.update(inputManifestPath=str(source_path), inputManifestSHA256=pin(source_path)["sha256"],
                        sourceIdentity="sha256:" + pin(source_path)["sha256"], provenance=incoming["provenance"])
                    write(target / "manifest.json", outgoing)
                    helper.validate_capture(target / "manifest.json")
                    # All cases pass the former recipe-led predicate, including True == 1.
                    self.assertEqual(outgoing["settings"]["modelInputRange"], "bounded-sRGB-after-resample")
                    self.assertTrue(all(outgoing["settings"][key] == value for key, value in recipe["intendedCaptureSettings"].items()))
                    captures[arm] = target / "manifest.json"
                write(source / "pair.json", pair)
                self.assertEqual(read(captures["control"])["settings"], read(captures["flash"])["settings"])
                output = directory / "analysis"
                if accepted:
                    result = analysis.analyze(source / "pair.json", captures["control"], captures["flash"], output)
                    self.assertTrue(result["complete"] and result["pairedInterpretationAdmitted"])
                    self.assertEqual(result["csv"]["rows"], 144)
                else:
                    boundary = "Recipe" if change_recipe else "Capture"
                    with self.assertRaisesRegex(ValueError, boundary + " settings.*canonical temporal capture contract"):
                        analysis.analyze(source / "pair.json", captures["control"], captures["flash"], output)
                    result = read(output / "report.json")
                    self.assertFalse(result["complete"] or result["pairedInterpretationAdmitted"])
                    self.assertEqual(result["frames"], [])
                OBSERVATIONS.append({"case": label, "alteredSettings": altered, "recipesResealed": change_recipe,
                    "bothCaptureCopiesAndPairResealed": True, "ordinaryCapturesValid": 2,
                    "formerRecipeBasedSettingsPredicateAccepted": True, "canonicalContractAccepted": accepted,
                    "capturesFabricated": True})

    def test_resealed_misplaced_source_flash_reaches_pixel_rejection(self):
        source, capture_path = self.directory / "misplaced-input", self.directory / "misplaced-capture"
        shutil.copytree(self.input, source)
        shutil.copytree(self.captures["flash"].parent, capture_path)
        manifest_path = source / "flash/manifest.json"
        incoming, outgoing, pair = read(manifest_path), read(capture_path / "manifest.json"), read(source / "pair.json")
        paths = [manifest_path.parent / incoming["frames"][i]["path"] for i in (24, 25)]
        before = [path.read_bytes() for path in paths]
        for index, path, data in zip((24, 25), paths, reversed(before)):
            path.write_bytes(data)
            item = incoming["frames"][index]
            item.update({key: pin(path)[key] for key in ("bytes", "sha256")})
            pixels = np.frombuffer(data, dtype="<f4").reshape(90, 160, 3)
            item["statistics"] = {"minimumNitsRGB": pixels.min(axis=(0, 1)).astype(float).tolist(),
                                  "maximumNitsRGB": pixels.max(axis=(0, 1)).astype(float).tolist()}
            outgoing["frames"][index]["inputSHA256"] = item["sha256"]
            original = outgoing["frames"][index]["views"]["original"]
            (capture_path / original["path"]).write_bytes(data)
            original.update({key: pin(path)[key] for key in ("bytes", "sha256")})
        write(manifest_path, incoming)
        pair["arms"]["flash"].update({key: pin(manifest_path)[key] for key in ("bytes", "sha256")})
        write(source / "pair.json", pair)
        shutil.copyfile(manifest_path, capture_path / "input-manifest.json")
        outgoing.update(inputManifestPath=str(manifest_path), inputManifestSHA256=pin(manifest_path)["sha256"],
                        sourceIdentity="sha256:" + pin(manifest_path)["sha256"])
        write(capture_path / "manifest.json", outgoing)
        helper.validate_capture(capture_path / "manifest.json")
        with self.assertRaisesRegex(ValueError, "Source flash must occur only at24"):
            analysis.analyze(source / "pair.json", self.captures["control"], capture_path / "manifest.json", self.directory / "misplaced-analysis")
        OBSERVATIONS.append({"case": "resealed source flash moved24 to25", "ordinaryCaptureValidationPassed": True,
            "sourceAndPairHashesResealed": True, "pixelEventContractRejected": True})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--report", type=Path, help="Optional new persistent JSON test report")
    options, arguments = parser.parse_known_args()
    if options.report and (options.report.exists() or options.report.is_symlink()):
        parser.error("--report must be a fresh path")
    source_files = [Path(__file__), HERE / "analyze-flash-reference.py", HERE / "generate-flash-reference.py",
                    HERE / "prepare-occlusion-reference.py", HERE / "review-reference-sequence.py", HERE.parent / "pyproject.toml", HERE.parent / "uv.lock"]
    before = [{**pin(path), "path": str(path.resolve())} for path in source_files]
    started = time.monotonic_ns()
    program = unittest.main(argv=[sys.argv[0], *arguments], exit=False)
    after = [{**pin(path), "path": str(path.resolve())} for path in source_files]
    passed = program.result.wasSuccessful() and before == after
    if options.report:
        report = {"passed": passed, "testsRun": program.result.testsRun, "sourcesUnchanged": before == after,
            "sourcePinsBefore": before, "sourcePinsAfter": after, "python": sys.version, "numpy": np.__version__,
            "elapsedSeconds": (time.monotonic_ns() - started) / 1e9, "observations": OBSERVATIONS,
            "scope": "CPU generated inputs and fabricated output schema only; no model/GPU/native runtime.",
            "failures": [{"test": test.id(), "traceback": trace} for test, trace in program.result.failures],
            "errors": [{"test": test.id(), "traceback": trace} for test, trace in program.result.errors],
            "skipped": [{"test": test.id(), "reason": reason} for test, reason in program.result.skipped]}
        with options.report.open("x") as stream:
            json.dump(report, stream, indent=2, sort_keys=True, allow_nan=False); stream.write("\n")
    raise SystemExit(0 if passed else 1)
