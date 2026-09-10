"""CPU-only fixture selection, authentication and source/player timing guards.

Small generated metadata/inventories exercise rejection and ordering; these are
not media fixtures and do not qualify Dolby decoding or native playback.
"""
import copy
from fractions import Fraction
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

from dovi_fixtures import (FIXTURES, exact_inventory, native_timeline_offset,
                           select_fixture, verify_metadata, verify_source)


def packet_probe():
    # Decode order deliberately differs from presentation order, as with B frames.
    frames = [{"stream_index": 0, "pts": 240000 + index * 1001, "duration": 1001}
              for index in reversed(range(2360))]
    return {"streams": [{"index": 0, "codec_type": "video", "time_base": "1/24000"}],
            "format": {"start_time": "9.956000"}, "packets": frames}


def decoded_probe():
    return {"streams": [{"codec_type": "video", "duration": "98.431667", "time_base": "1/24000",
                         "side_data_list": [{"side_data_type": "DOVI configuration record",
                                             "dv_profile": 5, "dv_bl_signal_compatibility_id": 0}]}],
            "frames": [{"side_data_list": [{"side_data_type": "Dolby Vision RPU Data"},
                         {"side_data_type": "Dolby Vision Metadata", "vdr_rpu_profile": 0,
                          "bl_video_full_range_flag": 1, "disable_residual_flag": 1}]}]}


class DolbyFixtureTests(unittest.TestCase):
    @staticmethod
    def harness():
        path = Path(__file__).with_name("test-dovi-passthrough.py")
        spec = importlib.util.spec_from_file_location("dovi_harness", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_report_directory_refuses_existing_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "new" / "report.json"
            harness = self.harness()
            harness.create_report_directory(report)
            report.write_text("original failed report")
            with self.assertRaises(FileExistsError):
                harness.create_report_directory(report)
            self.assertEqual(report.read_text(), "original failed report")

    def test_native_capture_refuses_existing_log_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "native-dovi.log"
            log.write_text("original capture")
            with self.assertRaises(FileExistsError):
                self.harness().native_case(root / "absent.mp4", root, False)
            self.assertEqual(log.read_text(), "original capture")

    def test_fixture_identity_does_not_change_legacy_profile_defaults(self):
        self.assertEqual(select_fixture()["id"], "fate-profile84")
        self.assertEqual(select_fixture(profile="5")["id"], "fate-profile5")
        self.assertEqual(select_fixture("apple-profile5")["profile"], 5)
        self.assertNotEqual(select_fixture("apple-profile5")["sha256"], select_fixture(profile="5")["sha256"])

    def test_conflicting_fixture_and_profile_reject(self):
        with self.assertRaises(ValueError):
            select_fixture("apple-profile5", "8.4")

    def test_source_identity_rejects_same_size_byte_change_and_truncation(self):
        original = b"source fixture identity"
        pin = {"bytes": len(original), "sha256": hashlib.sha256(original).hexdigest()}
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.write_bytes(original)
            self.assertEqual(verify_source(source, pin), pin["sha256"])
            for payload in [original[:-1] + b"!", original[:-1]]:
                source.write_bytes(payload)
                with self.assertRaises(ValueError):
                    verify_source(source, pin)

    def test_profile5_requires_both_rpu_and_parsed_interpretation(self):
        probe = decoded_probe()
        self.assertEqual(verify_metadata(probe, FIXTURES["apple-profile5"])["decodedFramesWithParsedRPU"], 1)
        for side_type in ["Dolby Vision RPU Data", "Dolby Vision Metadata"]:
            missing = copy.deepcopy(probe)
            missing["frames"][0]["side_data_list"] = [side for side in missing["frames"][0]["side_data_list"]
                                                       if side["side_data_type"] != side_type]
            with self.subTest(side_type=side_type), self.assertRaises(ValueError):
                verify_metadata(missing, FIXTURES["apple-profile5"])
        wrong = copy.deepcopy(probe)
        wrong["frames"][0]["side_data_list"][1]["bl_video_full_range_flag"] = 0
        with self.assertRaises(ValueError):
            verify_metadata(wrong, FIXTURES["apple-profile5"])

    def test_inventory_uses_presentation_order_and_real_frame_times(self):
        inventory = exact_inventory(packet_probe(), FIXTURES["apple-profile5"])
        self.assertEqual(inventory["frames"][0]["pts"], 240000)
        self.assertEqual([target["pts"] for target in inventory["targets"]], [528288, 1248007, 1968727])
        self.assertEqual(inventory["timebaseDenominator"], 24000)

    def test_source_to_player_offset_obeys_observed_rebase_setting(self):
        offset = native_timeline_offset(9.956, True, Fraction(11, 250), .044)
        self.assertEqual(offset, Fraction(-2489, 250))
        self.assertEqual(Fraction(11, 250) - offset, Fraction(10))
        self.assertEqual(native_timeline_offset(9.956, False, Fraction(10), 10.0), 0)
        self.assertEqual(native_timeline_offset(0.0, True, Fraction(10), 10.0), 0)
        source = Fraction(528288, 24000)
        self.assertEqual(source + offset, Fraction(1507, 125))

    def test_unexpected_or_nonfinite_native_start_rejects(self):
        for start in [float("nan"), float("inf"), None]:
            with self.subTest(start=start), self.assertRaises(ValueError):
                native_timeline_offset(start, True, Fraction(10), .044)
        with self.assertRaises(ValueError):
            native_timeline_offset(9.956, True, Fraction(10), .044)

    def test_unavailable_or_unparsed_native_rebase_rejects(self):
        for option in [None, "yes", 1]:
            with self.subTest(option=option), self.assertRaises(ValueError):
                native_timeline_offset(9.956, option, Fraction(10), .044)

    def test_invalid_inventory_rejects_duplicate_missing_and_zero_duration(self):
        duplicate = packet_probe(); duplicate["packets"].append(duplicate["packets"][0])
        missing = packet_probe(); missing["packets"].pop()
        zero = packet_probe(); zero["packets"][0]["duration"] = 0
        for probe in [duplicate, missing, zero]:
            with self.assertRaises(ValueError):
                exact_inventory(probe, FIXTURES["apple-profile5"])


if __name__ == "__main__":
    unittest.main()
