"""CPU tests with fabricated four-view captures; no model or GPU is executed."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

import numpy as np


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


prepare = module("occlusion_test_prepare", "prepare-occlusion-reference.py")
analysis = module("occlusion_test_analysis", "analyze-occlusion-reference.py")
OBSERVATIONS = []


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def load_json(path):
    return json.loads(path.read_text())


def metric_values(value):
    return [value[key] for key in ("signedMeanNits", "meanAbsoluteNits", "rmsNits", "maximumAbsoluteNits")]


def fabricate_capture(source, output, *, frame_drift):
    """Attach an exactly representable residual to each material, not screen x.

    This intentionally fabricates even the declared usedModel field to exercise
    the captured schema. Nothing in these fixtures is a real neural result.
    """
    output.mkdir()
    source_manifest = source / "manifest.json"
    incoming = load_json(source_manifest)
    width, height = incoming["width"], incoming["height"]
    assert (width, height) == (160, 90)
    shutil.copyfile(source_manifest, output / "input-manifest.json")
    records = []
    x = np.broadcast_to(np.arange(width), (height, width))
    for index, frame in enumerate(incoming["frames"]):
        original = np.fromfile(source / frame["path"], dtype="<f4").reshape(height, width, 3)
        foreground = np.fromfile(source / frame["masks"]["foreground"]["path"], dtype=np.uint8).reshape(height, width).astype(bool)
        step = min(28, max(0, index - 7))
        world_x = x + step
        object_u = x - (48 + 4 * step)
        residual = np.where(foreground, object_u % 7 + 20, world_x % 13 + 2)
        if frame_drift:
            residual = residual + index
        enhanced = (original.astype(np.float64) + residual[:, :, None]).astype("<f4")
        # Scale1's source values and these integer additions are exact dyadic
        # Float32 sums. Fail fixture setup rather than allowing quantization to
        # muddy the analyzer's expected zero/one residual changes.
        np.testing.assert_array_equal(enhanced.astype(np.float64) - original,
                                      np.broadcast_to(residual[:, :, None], original.shape))
        folder = output / f"frame-{index:04d}"
        folder.mkdir()
        views = {}
        for name, pixels in (("original", original), ("proxy", np.full_like(original, .5)),
                             ("identity", original), ("enhanced", enhanced)):
            path = folder / (name + ".rgb32f")
            data = pixels.astype("<f4").tobytes()
            path.write_bytes(data)
            views[name] = {"path": str(path.relative_to(output)), "bytes": len(data),
                           "sha256": digest(path)}
        records.append({"ordinal": index, "sourceFrameIndex": index,
            "inputPath": frame["path"], "inputSHA256": frame["sha256"],
            "pts": frame["pts"], "duration": frame["duration"], "generation": 1,
            "usedModel": True, "historyReset": index == 0,
            "knownInputDiscontinuities": ["cold-start"] if index == 0 else [],
            "specificResetOrCutCause": "unavailable", "views": views})
    manifest = {"schemaVersion": 1, "complete": True, "completedFrames": 48,
        "requestedFrames": 48, "width": width, "height": height,
        "layout": incoming["layout"], "views": ["original", "proxy", "identity", "enhanced"],
        "referenceDomain": {"primaries": "BT.2020", "transfer": "linear", "units": "cd/m2"},
        "proxyDomain": {"primaries": "BT.709", "transfer": "sRGB", "units": "normalized0...1"},
        "inputManifestCopy": "input-manifest.json", "inputManifestSHA256": digest(source_manifest),
        "inputManifestPath": str(source_manifest), "provenance": incoming["provenance"],
        "sourceIdentity": "sha256:" + digest(source_manifest), "generation": 1,
        "settings": {"referenceWhiteNits": 203, "motionRequested": "automatic", "temporal": True,
                     "processingWidth": 160, "processingHeight": 96, "modelInputRange": "bounded-sRGB-after-resample"},
        "model": {"path": "FABRICATED-TEST-NO-MODEL", "files": []},
        "runtime": {"scope": "Fabricated CPU test data; no model, GPU, decoder or native player executed"},
        "frames": records}
    write_json(output / "manifest.json", manifest)
    return output / "manifest.json"


class OcclusionReferenceAnalysisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="occlusion-analysis-cpu-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.source = cls.directory / "source"
        # Generate once using the real preparer. Assertions below use stored
        # pixels/masks and material correspondences, not its render function.
        with contextlib.redirect_stdout(io.StringIO()):
            prepare.generate(cls.source, 1)
        cls.material = fabricate_capture(cls.source, cls.directory / "material", frame_drift=False)
        cls.drift = fabricate_capture(cls.source, cls.directory / "drift", frame_drift=True)

    def run_analysis(self, name, capture):
        return analysis.analyze(self.source / "manifest.json", capture, self.directory / name)

    def assert_metrics(self, metrics, expected):
        self.assertIsInstance(metrics, dict)
        self.assertEqual(metric_values(metrics), [float(expected)] * 4)

    def assert_unavailable(self, temporal):
        self.assertEqual(temporal["supportPixels"], 0)
        self.assertIsNone(temporal["originalCorrespondenceBitExact"])
        self.assertIsNone(temporal["enhancedMinusOriginal"])
        self.assertIsNone(temporal["identityMinusOriginal"])
        self.assertTrue(temporal["reason"])

    def test_material_residual_aligns_exactly_and_empty_regions_are_unavailable(self):
        report = self.run_analysis("material-analysis", self.material)
        self.assertEqual(len(report["frames"]), 48)
        supports = 0
        for index, frame in enumerate(report["frames"]):
            for name, region in frame["regions"].items():
                with self.subTest(index=index, region=name):
                    if region["pixels"]:
                        self.assertGreater(region["spatial"]["enhancedMinusOriginal"]["rmsNits"], 0)
                        self.assert_metrics(region["spatial"]["identityMinusOriginal"], 0)
                    else:
                        self.assertIsNone(region["spatial"]["enhancedMinusOriginal"])
                        self.assertIsNone(region["spatial"]["identityMinusOriginal"])
                    temporal = region["temporal"]
                    if temporal["supportPixels"]:
                        self.assertIn(name, ("background", "foreground"))
                        self.assertTrue(temporal["originalCorrespondenceBitExact"])
                        self.assert_metrics(temporal["enhancedMinusOriginal"], 0)
                        self.assert_metrics(temporal["identityMinusOriginal"], 0)
                        supports += 1
                    else:
                        self.assert_unavailable(temporal)
        self.assertEqual(supports, 47 + 34)
        for name in ("background", "foreground"):
            self.assert_unavailable(report["frames"][0]["regions"][name]["temporal"])
        for index in range(35, 48):
            self.assertEqual(report["frames"][index]["regions"]["foreground"]["pixels"], 0)
        self.assertGreater(report["frames"][35]["regions"]["newlyRevealedBackground"]["pixels"], 0)
        self.assertEqual(report["frames"][36]["regions"]["newlyRevealedBackground"]["pixels"], 0)

        # The same image coordinates do change during the pan, even on pixels
        # that remain background at both times. This guards against a vacuous
        # constant-residual fixture masquerading as motion compensation.
        source = load_json(self.source / "manifest.json")
        capture = load_json(self.material)
        residuals, backgrounds = [], []
        for index in (7, 8):
            views = capture["frames"][index]["views"]
            original = np.fromfile(self.material.parent / views["original"]["path"], dtype="<f4").reshape(90, 160, 3)
            enhanced = np.fromfile(self.material.parent / views["enhanced"]["path"], dtype="<f4").reshape(90, 160, 3)
            residuals.append(enhanced.astype(np.float64) - original)
            backgrounds.append(np.fromfile(self.source / source["frames"][index]["masks"]["background"]["path"],
                                           dtype=np.uint8).reshape(90, 160).astype(bool))
        shared_screen = backgrounds[0] & backgrounds[1]
        fixed_screen_rms = float(np.sqrt(np.mean((residuals[1][shared_screen] - residuals[0][shared_screen])**2)))
        self.assertGreater(fixed_screen_rms, 0)
        self.assertEqual(len(report["cohorts"]), 28 * 6)
        for cohort in report["cohorts"]:
            self.assertEqual(cohort["supportPixels"], cohort["cohortPixels"])
            self.assertTrue(cohort["originalCorrespondenceBitExact"])
            self.assert_metrics(cohort["changeFromReveal"], 0)
        OBSERVATIONS.append({"case": "material-attached residual", "validAlignedRegions": supports,
            "alignedMaximumError": 0, "fixedScreenRMS": fixed_screen_rms,
            "revealObservations": len(report["cohorts"]), "captureWasFabricated": True})

    def test_frame_index_drift_remains_one_and_reveal_change_equals_age(self):
        report = self.run_analysis("drift-analysis", self.drift)
        aligned = 0
        for frame in report["frames"]:
            for name in ("background", "foreground"):
                temporal = frame["regions"][name]["temporal"]
                if temporal["supportPixels"]:
                    self.assert_metrics(temporal["enhancedMinusOriginal"], 1)
                    self.assert_metrics(temporal["identityMinusOriginal"], 0)
                    aligned += 1
        self.assertEqual(aligned, 81)
        observed = set()
        for cohort in report["cohorts"]:
            self.assertEqual(cohort["supportPixels"], cohort["cohortPixels"])
            self.assertTrue(cohort["originalCorrespondenceBitExact"])
            self.assertEqual(cohort["ageFrames"], cohort["observedSourceFrameIndex"] - cohort["revealSourceFrameIndex"])
            self.assert_metrics(cohort["changeFromReveal"], cohort["ageFrames"])
            if cohort["finalObservation"]:
                self.assertEqual(cohort["observedSourceFrameIndex"], 47)
            else:
                observed.add(cohort["ageFrames"])
        self.assertEqual(observed, {0, 1, 2, 4, 8})
        self.assertEqual(len(report["cohorts"]), 168)
        OBSERVATIONS.append({"case": "unit temporal drift", "validAlignedRegions": aligned,
            "expectedAlignedDelta": 1, "revealObservations": 168,
            "expectedRevealDelta": "observed index minus reveal index", "captureWasFabricated": True})

    def test_resealed_wrong_reveal_reaches_geometric_rejection(self):
        with tempfile.TemporaryDirectory(dir=self.directory, prefix="resealed-mask-") as temporary:
            directory = Path(temporary)
            source, capture = directory / "source", directory / "capture"
            shutil.copytree(self.source, source)
            shutil.copytree(self.material.parent, capture)
            incoming = load_json(source / "manifest.json")
            bad = incoming["frames"][8]["masks"]["newlyRevealedBackground"]
            data = np.fromfile(source / bad["path"], dtype=np.uint8)
            location = int(np.flatnonzero(data)[0])
            data[location] = 0
            (source / bad["path"]).write_bytes(data.tobytes())
            bad.update(sha256=digest(source / bad["path"]), truePixels=int(data.sum()))
            write_json(source / "manifest.json", incoming)
            shutil.copyfile(source / "manifest.json", capture / "input-manifest.json")
            outgoing = load_json(capture / "manifest.json")
            outgoing.update(inputManifestSHA256=digest(source / "manifest.json"),
                            sourceIdentity="sha256:" + digest(source / "manifest.json"),
                            inputManifestPath=str(source / "manifest.json"))
            write_json(capture / "manifest.json", outgoing)
            self.assertEqual(digest(capture / "input-manifest.json"), outgoing["inputManifestSHA256"])
            self.assertEqual(digest(source / bad["path"]), bad["sha256"])
            with self.assertRaisesRegex((AssertionError, ValueError), r"(?i)(reveal|geometr)") as caught:
                analysis.analyze(source / "manifest.json", capture / "manifest.json", directory / "analysis")
            OBSERVATIONS.append({"case": "updated-hash wrong reveal", "rejected": True,
                "error": str(caught.exception), "modifiedPixels": 1, "allChangesInTemporaryFabricatedFixture": True})

    def test_source_timing_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory(dir=self.directory, prefix="bad-timing-") as temporary:
            directory = Path(temporary)
            capture = directory / "capture"
            shutil.copytree(self.material.parent, capture)
            outgoing = load_json(capture / "manifest.json")
            # Still strictly between frame7 and frame9: the failure must include
            # the exact source/capture pairing, not merely ordering validation.
            outgoing["frames"][8]["pts"] = {"value": 17, "timescale": 60}
            write_json(capture / "manifest.json", outgoing)
            with self.assertRaises((AssertionError, ValueError)):
                analysis.analyze(self.source / "manifest.json", capture / "manifest.json", directory / "analysis")
            OBSERVATIONS.append({"case": "source/capture exact-time mismatch", "rejected": True})

    def test_existing_and_dangling_output_are_refused_before_input_reads(self):
        with tempfile.TemporaryDirectory(dir=self.directory, prefix="output-guard-") as temporary:
            directory = Path(temporary)
            existing = directory / "existing"
            existing.mkdir()
            marker = existing / "retained.txt"
            marker.write_bytes(b"retained-output")
            dangling = directory / "dangling"
            dangling.symlink_to(directory / "absent-target")
            for output in (existing, dangling):
                with self.subTest(output=output.name), self.assertRaisesRegex(
                        (FileExistsError, ValueError), r"(?i)(exist|output)"):
                    analysis.analyze(directory / "missing-input", directory / "missing-capture", output)
            self.assertEqual(marker.read_bytes(), b"retained-output")
            self.assertTrue(dangling.is_symlink())
            self.assertFalse(dangling.exists())
            OBSERVATIONS.append({"case": "existing/dangling output", "rejectedBeforeInputRead": 2,
                "originalEntryPreserved": True})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--report", type=Path,
                        help="Optional new persistent JSON result outside the tests' temporary fixtures")
    options, unittest_args = parser.parse_known_args()
    if options.report and (options.report.exists() or options.report.is_symlink()):
        parser.error("--report must be a new path")
    pin_paths = [Path(__file__).resolve(), HERE / "analyze-occlusion-reference.py",
                 HERE / "prepare-occlusion-reference.py", HERE / "review-reference-sequence.py",
                 ROOT / "pyproject.toml", ROOT / "uv.lock"]
    before = [{"path": str(path), "sha256": digest(path)} for path in pin_paths]
    started = time.monotonic_ns()
    program = unittest.main(argv=[sys.argv[0], *unittest_args], exit=False)
    after = [{"path": str(path), "sha256": digest(path)} for path in pin_paths]
    passed = program.result.wasSuccessful() and before == after
    if options.report:
        result = {"passed": passed, "testsRun": program.result.testsRun,
            "failures": [{"test": test.id(), "traceback": trace} for test, trace in program.result.failures],
            "errors": [{"test": test.id(), "traceback": trace} for test, trace in program.result.errors],
            "skipped": [{"test": test.id(), "reason": reason} for test, reason in program.result.skipped],
            "scope": "Generated synthetic inputs and fabricated four-view captures only; no model, GPU, native player, or window executed.",
            "invocation": [sys.executable, *sys.argv], "python": sys.version, "numpy": np.__version__,
            "sourcePinsBefore": before, "sourcePinsAfter": after, "sourcesUnchanged": before == after,
            "elapsedSeconds": (time.monotonic_ns() - started) / 1e9, "observations": OBSERVATIONS}
        with options.report.open("x") as stream:
            json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
    sys.exit(0 if passed else 1)
