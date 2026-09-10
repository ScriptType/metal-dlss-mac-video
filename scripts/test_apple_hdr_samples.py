"""CPU regressions for immutable source acquisition and exact remux verification."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("apple_samples", Path(__file__).with_name("fetch-apple-hdr-samples.py"))
FETCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FETCH)


class AppleSampleTests(unittest.TestCase):
    def source(self):
        return {"streams": [{"index": 0, "codec_type": "video", "time_base": "1/24000",
                             "codec_name": "hevc", "codec_tag_string": "dvh1",
                             "side_data_list": [{"side_data_type": "DOVI configuration record", "dv_profile": 5}]}],
                "packets": [{"stream_index": 0, "pts": 241001, "dts": 240000,
                             "duration": 1001, "size": 12, "data_hash": "SHA256:original"}]}

    def test_unchanged_packets_and_configuration_pass(self):
        source = self.source()
        self.assertEqual(FETCH.verify_packets(source, copy.deepcopy(source), "video")["packets"], 1)

    def test_timestamp_payload_and_packet_count_changes_fail(self):
        source = self.source()
        for field in ("pts", "dts", "duration", "size", "data_hash"):
            with self.subTest(field=field):
                changed = copy.deepcopy(source)
                changed["packets"][0][field] = "changed"
                with self.assertRaises(RuntimeError):
                    FETCH.verify_packets(source, changed, "video")
        changed = copy.deepcopy(source)
        changed["packets"] = []
        with self.assertRaises(RuntimeError):
            FETCH.verify_packets(source, changed, "video")

    def test_dropped_dolby_configuration_fails_even_with_identical_packets(self):
        source = self.source()
        changed = copy.deepcopy(source)
        del changed["streams"][0]["side_data_list"]
        with self.assertRaisesRegex(RuntimeError, "side_data_list"):
            FETCH.verify_packets(source, changed, "video")

    def test_changed_time_base_fails(self):
        source = self.source()
        changed = copy.deepcopy(source)
        changed["streams"][0]["time_base"] = "1/1000"
        with self.assertRaisesRegex(RuntimeError, "time base"):
            FETCH.verify_packets(source, changed, "video")

    def test_hevc_array_flag_may_change_but_nal_payload_must_match(self):
        header = bytes([1] + [0] * 21 + [1])
        complete = header + bytes.fromhex("a7000100034e0100")
        incomplete = header + bytes.fromhex("27000100034e0100")

        def stream(data):
            return {"codec_name": "hevc", "extradata": "00000000: " + data.hex() + "  test"}

        self.assertEqual(FETCH.codec_bytes(stream(complete)), FETCH.codec_bytes(stream(incomplete)))
        self.assertNotEqual(FETCH.codec_bytes(stream(complete)), FETCH.codec_bytes(stream(incomplete[:-1] + b"\x01")))
        with self.assertRaisesRegex(RuntimeError, "Truncated"):
            FETCH.codec_bytes(stream(complete[:-1]))

    def test_combined_corpus_bound_checked_before_fetch(self):
        catalog = json.loads(FETCH.CATALOG.read_text())
        FETCH.validate_catalog(catalog)
        catalog["master"]["bytes"] = 100 * 1024 * 1024
        with self.assertRaisesRegex(ValueError, "100 MiB"):
            FETCH.validate_catalog(catalog)

    def test_corrupt_existing_source_is_preserved_and_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / "sample.mp4"
            path.write_bytes(b"bad")
            asset = {"filename": path.name, "bytes": 4, "sha256": hashlib.sha256(b"good").hexdigest()}
            with patch.object(FETCH.subprocess, "run") as run:
                with self.assertRaises(RuntimeError):
                    FETCH.fetch(asset, directory)
                run.assert_not_called()
            self.assertEqual(path.read_bytes(), b"bad")

    def test_interrupted_download_never_publishes_partial_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            asset = {"filename": "sample.mp4", "url": "https://example.invalid/sample.mp4",
                     "bytes": 4, "sha256": hashlib.sha256(b"good").hexdigest()}

            def interrupt(command, **kwargs):
                Path(command[-1]).write_bytes(b"go")
                raise subprocess.CalledProcessError(18, command)

            with patch.object(FETCH.subprocess, "run", side_effect=interrupt):
                with self.assertRaises(subprocess.CalledProcessError):
                    FETCH.fetch(asset, directory)
            self.assertEqual(list(directory.iterdir()), [])

    def test_download_with_wrong_hash_never_publishes(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            asset = {"filename": "sample.mp4", "url": "https://example.invalid/sample.mp4",
                     "bytes": 4, "sha256": hashlib.sha256(b"good").hexdigest()}
            with patch.object(FETCH.subprocess, "run", side_effect=lambda command, **kwargs: Path(command[-1]).write_bytes(b"bad!")):
                with self.assertRaisesRegex(RuntimeError, "source changed"):
                    FETCH.fetch(asset, directory)
            self.assertEqual(list(directory.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
