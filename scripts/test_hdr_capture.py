import base64
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

import numpy as np

SPEC = importlib.util.spec_from_file_location("capture_analysis", Path(__file__).with_name("analyze-hdr-capture.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def profile():
    # Synthetic identity primaries and sRGB parametric decoding, independently
    # encoded as ICC s15Fixed16 values. No dependency on a captured profile.
    tags = []
    for channel, name in enumerate((b"rXYZ", b"gXYZ", b"bXYZ")):
        tags.append((name, b"XYZ " + bytes(4) + struct.pack(">iii", *[65536 if i == channel else 0 for i in range(3)])))
    params = [round(value * 65536) for value in [2.4, 1 / 1.055, .055 / 1.055, 1 / 12.92, .04045]]
    for name in (b"rTRC", b"gTRC", b"bTRC"):
        tags.append((name, b"para" + bytes(4) + struct.pack(">HHiiiii", 3, 0, *params)))
    data = bytearray(132 + 12 * len(tags))
    data[8] = 4; data[12:24] = b"mntrRGB XYZ "; data[36:40] = b"acsp"
    struct.pack_into(">I", data, 128, len(tags))
    for index, (name, value) in enumerate(tags):
        struct.pack_into(">4sII", data, 132 + 12 * index, name, len(data), len(value))
        data.extend(value)
    struct.pack_into(">I", data, 0, len(data))
    return bytes(data)


class CaptureTests(unittest.TestCase):
    def test_actual_icc_curve_decodes_known_srgb_values(self):
        matrix, curves = MODULE.matrix_profile(profile())
        samples = np.array([[0, .01, .04], [.18, .5, 1.]])
        reference = np.where(samples <= .04045, samples / 12.92, ((samples + .055) / 1.055) ** 2.4)
        np.testing.assert_allclose(MODULE.to_xyz(samples, matrix, curves), reference, atol=3e-5, rtol=0)

    def test_extended_and_nonfinite_are_not_extrapolated(self):
        matrix, curves = MODULE.matrix_profile(profile())
        for value in [-.01, 1.01, float("nan"), float("inf")]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.to_xyz(np.array([[value, .5, .5]]), matrix, curves)

    def test_corrupt_icc_tag_bounds_rejected(self):
        data = bytearray(profile()); struct.pack_into(">I", data, 136, len(data) + 1)
        with self.assertRaises(ValueError): MODULE.matrix_profile(data)

    def test_stats_preserve_negative_extended_nonfinite_and_alpha_counts(self):
        pixels = np.array([[[-.5, 2, np.nan, .5], [0, 0, 0, 1]]])
        value = MODULE.statistics(pixels)
        self.assertEqual([value[k] for k in ["rgbComponentsBelowZero", "rgbComponentsAboveOne", "nonfiniteComponents", "nonopaquePixels"]], [1, 1, 1, 1])

    def test_strided_reader_ignores_padding_and_verifies_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory); icc = profile()
            # One pixel per row; poison padding must not count as captured RGB.
            data = np.array([[.25, .5, .75, 1, np.nan, np.nan, np.nan, np.nan],
                             [1, .5, .25, 1, np.nan, np.nan, np.nan, np.nan]], dtype="<f2").tobytes()
            report = {"pixelStorage": {"file": "pixels.rgba16f", "width": 1, "height": 2, "bytesPerRow": 16, "sha256": MODULE.sha(data)},
                      "pixelAttachmentsPropagating": {"CVImageBufferICCProfile": {"base64": base64.b64encode(icc).decode(), "sha256": MODULE.sha(icc)}}}
            (path / "report.json").write_text(json.dumps(report)); (path / "pixels.rgba16f").write_bytes(data)
            _, pixels, _ = MODULE.read_capture(path)
            self.assertEqual(pixels.shape, (2, 1, 4)); self.assertTrue(np.isfinite(pixels).all())
            (path / "pixels.rgba16f").write_bytes(data[:-1])
            with self.assertRaises(ValueError): MODULE.read_capture(path)

    def test_comparison_reports_nonopaque_and_extended_exclusions(self):
        report = {"configuration": {"dynamicRange": 1}}
        pixels = np.array([[[.5, .5, .5, 1], [.5, .5, .5, .5], [2, .5, .5, 1]]])
        value = (report, pixels, profile())
        result = MODULE.compare(value, value, "0,0,3,1", "0,0,3,1")
        self.assertEqual(result["comparedPixels"], 1); self.assertEqual(result["excludedPixels"], 2)
        self.assertEqual(result["maximumAbsoluteRelativeXYZD50Difference"], [0, 0, 0])

    def test_mismatched_intent_and_geometry_rejected(self):
        pixels = np.ones((1, 2, 4)); icc = profile()
        first = ({"configuration": {"dynamicRange": 1}}, pixels, icc)
        second = ({"configuration": {"dynamicRange": 2}}, pixels, icc)
        with self.assertRaises(ValueError): MODULE.compare(first, second, "0,0,1,1", "0,0,1,1")
        with self.assertRaises(ValueError): MODULE.compare(first, first, "0,0,1,1", "0,0,2,1")


if __name__ == "__main__":
    unittest.main()
