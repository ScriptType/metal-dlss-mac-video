import copy
from fractions import Fraction
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import subprocess
import sys
from unittest.mock import patch
import unittest

spec = importlib.util.spec_from_file_location("prepared_smoke", Path(__file__).with_name("test-mpv-prepared.py"))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class PreparedTimingSmokeTest(unittest.TestCase):
    def mapping(self):
        return smoke.mapping_from_observation(Fraction(241001, 24000), Fraction(1, 24000),
            9.956, True, Fraction(2057, 24000), 2057 / 24000)

    def test_1080p_capacity_contains_all_six_float_frames(self):
        self.assertEqual(smoke.bounded_capacity(1920, 1080), 256 * 1024 * 1024)
        self.assertEqual(smoke.bounded_capacity(320, 192), 32 * 1024 * 1024)
        with self.assertRaisesRegex(ValueError, "512MiB"):
            smoke.bounded_capacity(3840, 2160)

    def test_file_decoder_and_player_coordinates_are_separate(self):
        mapping = self.mapping()
        self.assertEqual(smoke.seconds(mapping["packetOffset"]), Fraction(-12445, 1250))
        self.assertEqual(mapping["decoderToPlayerSeconds"], 0)
        unrebased = smoke.mapping_from_observation(Fraction(241001, 24000), Fraction(1, 24000),
            9.956, False, Fraction(241001, 24000), 241001 / 24000)
        self.assertEqual(smoke.seconds(unrebased["packetOffset"]), 0)

    def test_nonrepresentable_offset_and_wrong_decoded_first_frame_fail(self):
        with self.assertRaisesRegex(ValueError, "not exactly representable"):
            smoke.mapping_from_observation(Fraction(241001, 24000), Fraction(1, 24000),
                9.9560001, True, Fraction(2057, 24000), 2057 / 24000)
        with self.assertRaisesRegex(ValueError, "exact first file"):
            smoke.mapping_from_observation(Fraction(241001, 24000), Fraction(1, 24000),
                9.956, True, Fraction(2058, 24000), 2058 / 24000)

    def test_unsettled_zero_player_position_cannot_create_an_offset(self):
        with self.assertRaisesRegex(ValueError, "Settled player PTS differs"):
            smoke.mapping_from_observation(Fraction(241001, 24000), Fraction(1, 24000),
                9.956, True, Fraction(2057, 24000), 0)

    def test_restart_completion_and_repeated_held_clock_pair_are_required(self):
        class Player:
            sample = 0
            positions = [0, 2057 / 24000, 2057 / 24000, 2057 / 24000]
            def wait(self, predicate):
                return self.command("get_property", "enhancement-state")
            def command(self, _, name):
                if name == "demuxer-start-time": return 9.956
                if name == "rebase-start-time": return True
                if name == "mpv-version": return "mpv test-revision"
                if name == "pause": return True
                if name == "seeking": return self.sample == 0
                if name == "time-pos": return self.positions[self.sample]
                if name == "enhancement-state":
                    return {"displayed-source-pts": 2057, "displayed-timebase-num": 1, "displayed-timebase-den": 24000}
                raise AssertionError(name)
        player = Player()
        elapsed = [0.0]
        def sleep(delay):
            elapsed[0] += delay
            player.sample += 1
        inventory = {"timings": [(Fraction(241001, 24000), None)], "timebase": Fraction(1, 24000)}
        with patch.object(smoke.time, "monotonic", side_effect=lambda: elapsed[0]), patch.object(smoke.time, "sleep", side_effect=sleep):
            result = smoke.observe_mapping(player, inventory)
        self.assertEqual(result["decoderToPlayerSeconds"], 0)
        self.assertEqual(len(result["observations"]), 4)
        self.assertEqual(result["observations"][0]["playerSeconds"], 0)
        self.assertGreaterEqual(result["observations"][-1]["elapsedSeconds"] - result["observations"][1]["elapsedSeconds"], .1)

    def test_every_retained_phase_log_is_reserved(self):
        paths = smoke.evidence_paths(Path("run.json"))
        for phase in ("origin", "phase0", "phase1"):
            self.assertIn(Path(f"run.{phase}.log"), paths)
            self.assertIn(Path(f"run.{phase}.stderr.log"), paths)
        self.assertEqual(len(paths), len(set(paths)))

    def test_ipc_open_timeout_reaps_actual_child_and_removes_temp_directory(self):
        spawn = subprocess.Popen
        children, ipc_directories = [], []
        def child(arguments, **kwargs):
            path = next(value.split("=", 1)[1] for value in arguments if value.startswith("--input-ipc-server="))
            ipc_directories.append(Path(path).parent)
            process = spawn([sys.executable, "-c", "import time; time.sleep(30)"], **kwargs)
            children.append(process)
            return process
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "run.log"
            try:
                with patch.object(smoke.subprocess, "Popen", side_effect=child), patch.object(smoke.time, "monotonic", side_effect=[0, 21]):
                    with self.assertRaisesRegex(RuntimeError, "did not open IPC"):
                        smoke.Playback(Path("source.mp4"), None, log, None)
                self.assertIsNotNone(children[0].poll())
                self.assertFalse(ipc_directories[0].exists())
                self.assertTrue(log.with_suffix(".stderr.log").exists())
            finally:
                for process in children:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)

    def provider(self, offset="-9.9559999999999995", version="mpv test-revision"):
        return f"mpv-independent-demux-vt-v1;{version};libavcodec=4060000;demux=lavf;offset={offset};white=203;hlg=1000;exact-decoder-pts-duration-native-fallback"

    def test_actual_provider_version_and_numeric_offset_are_bound(self):
        smoke.verify_provider(self.provider(), self.mapping(), "mpv test-revision")
        with self.assertRaisesRegex(ValueError, "offset differs"):
            smoke.verify_provider(self.provider("0"), self.mapping(), "mpv test-revision")
        with self.assertRaisesRegex(ValueError, "actual native version"):
            smoke.verify_provider(self.provider(version="mpv old-revision"), self.mapping(), "mpv test-revision")

    def make_cache(self, directory):
        cache, archive = directory / "cache", directory / "archive"
        (cache / "segments").mkdir(parents=True); (cache / "staging").mkdir(); archive.mkdir()
        file_pts = [Fraction(241001 + index * 1001, 24000) for index in range(12)]
        duration = Fraction(1001, 24000)
        mapped = [pts - Fraction(2489, 250) for pts in file_pts]
        inventory = {"width": 1, "height": 1, "timings": [(pts, duration) for pts in file_pts], "exactDurationComparison": True}
        for index in (0, 3):
            timings = [{"presentationTime": smoke.rational(pts), "duration": smoke.rational(duration)} for pts in mapped[index:index + 3]]
            identity = {"source": {"contentSHA256": "a" * 64, "interpretation": {"decoder": self.provider()}},
                        "settings": {"modelSHA256": "b" * 64, "outputWidth": 1, "outputHeight": 1},
                        "range": {"start": smoke.rational(mapped[index]), "end": smoke.rational(mapped[index + 3])},
                        "preroll": {"start": smoke.rational(mapped[max(0, index - 1)])},
                        "timingInventorySHA256": hashlib.sha256(smoke.canonical(timings)).hexdigest()}
            key = hashlib.sha256(smoke.canonical(identity)).hexdigest()
            segment = cache / "segments" / key; segment.mkdir()
            records = []
            for frame, timing in enumerate(timings):
                name = f"{frame:08d}.rgba32f"
                pixels = struct.pack("<ffff", index + frame, 203, 1000, 1)
                (segment / name).write_bytes(pixels)
                records.append({"fileName": name, "byteCount": len(pixels), "sha256": hashlib.sha256(pixels).hexdigest(), "timing": timing})
            (segment / "manifest.json").write_text(json.dumps({"schemaVersion": 2,
                "storagePolicy": "rgba-f32le-linear-bt2020-absolute-nits-straight-alpha-v1",
                "key": key, "identity": identity, "frames": records}))
        return cache, archive, inventory, mapped

    def snapshot(self, setup):
        cache, archive, inventory, mapped = setup
        return smoke.snapshot_cache(cache, archive, 0, inventory, mapped, self.mapping(), "mpv test-revision", "a" * 64, "b" * 64, 32 * 1024 * 1024)

    def test_archives_validated_manifests_and_exact_timing_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            setup = self.make_cache(Path(temporary))
            result = self.snapshot(setup)
            self.assertEqual(len(result["segments"]), 2)
            for segment in result["segments"]:
                self.assertEqual(smoke.digest(segment["manifest"]), segment["manifestSHA256"])
                self.assertTrue(segment["pixelPayloadsVerified"])

    def test_changed_payload_is_rejected_even_when_manifest_and_timing_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            setup = self.make_cache(Path(temporary))
            pixel = next((setup[0] / "segments").glob("*/*.rgba32f"))
            pixel.write_bytes(b"\0" * 16)
            with self.assertRaisesRegex(ValueError, "pixel payload"):
                self.snapshot(setup)

    def test_changed_duration_cannot_hide_behind_valid_pts_or_regenerated_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            setup = self.make_cache(Path(temporary))
            manifest_path = next((setup[0] / "segments").glob("*/manifest.json"))
            manifest = json.loads(manifest_path.read_text())
            manifest["frames"][0]["timing"]["duration"] = smoke.rational(Fraction(1, 30))
            manifest["identity"]["timingInventorySHA256"] = hashlib.sha256(smoke.canonical([record["timing"] for record in manifest["frames"]])).hexdigest()
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "durations differ"):
                self.snapshot(setup)


if __name__ == "__main__":
    unittest.main()
