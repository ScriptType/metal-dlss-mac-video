"""CPU integrity checks for the pinned Apple temporal reference preparation."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

import numpy as np

spec = importlib.util.spec_from_file_location("apple_reference", Path(__file__).with_name("prepare-apple-hdr-reference.py"))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def inventory():
    return [{"pts": 241001 + index * 1001, "duration": 1001,
        "width": 1920, "height": 1080, "pix_fmt": "yuv420p10le", "color_range": "tv",
        "color_space": "bt2020nc", "color_primaries": "bt2020", "color_transfer": "smpte2084",
        "chroma_location": "topleft", "side_data_list": [{"side_data_type": name} for name in
            ("Mastering display metadata", "Content light level metadata", "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)")]}
        for index in range(2360)]


class AppleReferenceTests(unittest.TestCase):
    def test_exact_window_keeps_all_prelude_frames(self):
        selected = prepare.select_frames(inventory())
        self.assertEqual(len(selected), 56)
        self.assertEqual(selected[0]["pts"], 1730489)
        self.assertEqual(selected[-1]["pts"], 1785544)
        self.assertEqual(prepare.FIRST+prepare.PRELUDE, 1496)

    def test_wrong_timing_or_missing_dynamic_metadata_is_rejected(self):
        for field, value in (("pts", 0), ("duration", 1000), ("side_data_list", [])):
            frames = inventory();frames[1500][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                prepare.select_frames(frames)

    def test_range_chroma_or_transfer_change_is_not_silently_assumed(self):
        for field, value in (("color_range", "pc"), ("chroma_location", "left"),
                             ("color_transfer", "bt709"), ("width", 960)):
            frames = inventory();frames[1500][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                prepare.select_frames(frames)

    def test_gbr_planar_order_is_explicit(self):
        planes = np.array([[[2, 2], [2, 2]], [[3, 3], [3, 3]], [[1, 1], [1, 1]]], dtype="<f4")
        actual = prepare.unpack_gbr(planes.tobytes(), 2, 2)
        np.testing.assert_array_equal(actual, np.tile([1, 2, 3], (2, 2, 1)))

    def test_nonfinite_or_truncated_float_payload_is_rejected(self):
        for data in (b"\0", np.full((3, 2, 2), float("nan"), dtype="<f4").tobytes()):
            with self.assertRaises(ValueError): prepare.unpack_gbr(data, 2, 2)

    def test_linear_box_preserves_range_and_averages_linear_values(self):
        rgb = np.array([[[-100, 100, 10000], [-100, 300, 20000]],
                        [[-100, 500, 30000], [-100, 700, 40000]]], dtype="<f4")
        np.testing.assert_array_equal(prepare.box_half(rgb), [[[-100, 400, 25000]]])
        self.assertEqual(prepare.box_half(rgb).dtype, np.dtype("<f4"))

    def test_scalar_reference_black_white_and_chroma_co_siting(self):
        neutral = np.full((2, 2), 512, dtype="<u2")
        black = prepare.independent_reference(np.full((4, 4), 64), neutral, neutral)
        white = prepare.independent_reference(np.full((4, 4), 940), neutral, neutral)
        np.testing.assert_allclose(black, 0, atol=1e-10)
        np.testing.assert_allclose(white, 10000, atol=1e-8)
        cb = np.array([[492, 532], [492, 532]])
        rgb = prepare.independent_reference(np.full((4, 4), 509), cb, neutral)
        # Co-sited x0 retains the first chroma sample; x1 blends both; x2/x3
        # use the last sample, including clamp-to-edge on the last luma pixel.
        self.assertLess(rgb[0, 0, 2], rgb[0, 1, 2])
        self.assertLess(rgb[0, 1, 2], rgb[0, 2, 2])
        self.assertEqual(rgb[0, 2, 2], rgb[0, 3, 2])

    def test_showinfo_requires_original_pts_and_duration_without_duplicates(self):
        selected = prepare.select_frames(inventory())
        lines = ["config in time_base: 1/24000, frame_rate: 24000/1001"] + [
            f"n: {i} pts: {frame['pts']} pts_time: 72.0 duration: {frame['duration']} duration_time:0.041708"
            for i, frame in enumerate(selected)]
        text = "\n".join(lines)
        self.assertEqual(len(prepare.verify_showinfo(text, selected)), 56)
        for changed in (text.replace("1/24000", "1/1000"), text.replace("1/24000", "1/240000"),
                        text+"\nconfig in time_base: 1/240000, frame_rate: 24000/1001",
                        text.replace("1730489", "1491545"),
                        text+"\n"+lines[-1], text.replace("duration: 1001", "duration: 1000")):
            with self.assertRaises(ValueError): prepare.verify_showinfo(changed, selected)

    def test_existing_output_and_changed_pin_are_rejected_without_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory);source = path/"source";source.write_bytes(b"retained")
            with self.assertRaises(FileExistsError): prepare.require_new_output(path)
            pin = {"bytes": 8, "sha256": prepare.digest(source)}
            prepare.verify_pin(source, pin)
            with self.assertRaises(ValueError): prepare.verify_pin(source, {**pin, "sha256": "0"*64})
            self.assertEqual(source.read_bytes(), b"retained")
            dangling = path/"dangling";dangling.symlink_to(path/"missing")
            with self.assertRaises(FileExistsError): prepare.require_new_output(dangling)
            self.assertTrue(dangling.is_symlink())

    def test_optional_audit_requires_a_pass_and_matching_converter(self):
        self.assertIsNone(prepare.audit_pin(None, "a"*64))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"audit.json"
            for value in ({"passed": False, "ffmpeg": {"sha256": "a"*64}},
                          {"passed": True, "ffmpeg": {"sha256": "b"*64}}):
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError): prepare.audit_pin(path, "a"*64)
            path.write_text(json.dumps({"passed": True, "ffmpeg": {"sha256": "a"*64}}))
            self.assertEqual(prepare.audit_pin(path, "a"*64)["sha256"], prepare.digest(path))

    def test_partial_pipe_reads_are_combined_and_eof_fails(self):
        class Partial(io.BytesIO):
            def read(self, n): return super().read(min(n, 2))
        self.assertEqual(prepare.read_exact(Partial(b"abcdef"), 6), b"abcdef")
        with self.assertRaises(ValueError): prepare.read_exact(Partial(b"abc"), 6)

    def test_deadline_reaps_a_partial_output_sleeping_decoder(self):
        process = subprocess.Popen([sys.executable, "-c", "import os,time;os.write(1,b'ab');time.sleep(30)"], stdout=subprocess.PIPE)
        report = {};timer = prepare.decoder_watchdog(process, report, timeout=.1)
        try:
            with self.assertRaises(ValueError): prepare.read_exact(process.stdout, 3)
            self.assertNotEqual(process.wait(timeout=5), 0)
            self.assertTrue(report["decoderDeadlineExpired"])
        finally:
            timer.cancel()
            if process.poll() is None: process.kill();process.wait(timeout=5)
            process.stdout.close()


if __name__ == "__main__":
    unittest.main()
