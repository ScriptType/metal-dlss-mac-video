"""CPU-only policy timestamp, evidence retention and lifecycle regression checks."""
from fractions import Fraction
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("policy_smoke", Path(__file__).with_name("test-mpv-policy.py"))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class PolicyTimingTests(unittest.TestCase):
    def test_retained_core_provenance_names_resolve_in_this_checkout(self):
        root = Path(__file__).resolve().parents[1]
        self.assertIn("demux/lavf_timing.h", smoke.CORE_SOURCES)
        for name in smoke.CORE_SOURCES:
            with self.subTest(source=name):
                self.assertTrue((root / "vendor/mpv" / name).is_file())

    def mapping(self, rebased=True):
        decoder = Fraction(2057 if rebased else 241001, 24000)
        return smoke.mapping_from_observation(Fraction(241001, 24000), Fraction(1, 24000),
            9.956, rebased, decoder, float(decoder))

    def test_zero_origin_preserves_player_target_and_five_ms_tolerance(self):
        mapping = smoke.mapping_from_observation(Fraction(0), Fraction(1, 30), 0, True, Fraction(0), 0)
        inventory = [Fraction(index, 30) for index in range(60)]
        selected = smoke.select_target(inventory, mapping, player_target=Fraction("0.73"))
        self.assertEqual(smoke.seconds(selected["seekTarget"]), Fraction("0.73"))
        self.assertEqual(smoke.seconds(selected["expectedSeekPTS"]), Fraction(22, 30))
        selected = smoke.select_target(inventory, mapping, player_target=Fraction("0.737"))
        self.assertEqual(smoke.seconds(selected["expectedSeekPTS"]), Fraction(22, 30))

    def test_exact_natural_file_target_maps_to_decoder_and_player(self):
        inventory = [Fraction(241001 + index * 1001, 24000) for index in range(2360)]
        selected = smoke.select_target(inventory, self.mapping(), file_target=Fraction(1742501, 24000))
        self.assertEqual(selected["expectedFileFrameIndex"], 1500)
        self.assertEqual(smoke.seconds(selected["expectedFilePTS"]), Fraction(1742501, 24000))
        self.assertEqual(smoke.seconds(selected["expectedSeekPTS"]), Fraction(1503557, 24000))
        self.assertEqual(smoke.seconds(selected["seekTarget"]), Fraction(1503557, 24000))
        player_selection = smoke.select_target(inventory, self.mapping(), player_target=Fraction(1503557, 24000))
        self.assertEqual(player_selection["expectedFilePTS"], selected["expectedFilePTS"])

    def test_rebase_disabled_preserves_original_file_timeline(self):
        mapping = self.mapping(False)
        self.assertEqual(smoke.seconds(mapping["packetOffset"]), 0)
        self.assertEqual(mapping["decoderToPlayerSeconds"], 0)

    def test_wrong_first_frame_and_nonintegral_offset_fail(self):
        with self.assertRaisesRegex(ValueError, "exact first file"):
            smoke.mapping_from_observation(Fraction(241001, 24000), Fraction(1, 24000),
                9.956, True, Fraction(2058, 24000), 2058 / 24000)
        with self.assertRaisesRegex(ValueError, "not exactly representable"):
            smoke.mapping_from_observation(Fraction(241001, 24000), Fraction(1, 24000),
                9.9560001, True, Fraction(2057, 24000), 2057 / 24000)
        with self.assertRaisesRegex(ValueError, "finite native"):
            smoke.mapping_from_observation(Fraction(0), Fraction(1, 30), float("nan"), True, Fraction(0), 0)

    def test_unsettled_position_cannot_be_inferred_as_an_offset(self):
        with self.assertRaisesRegex(ValueError, "Settled player PTS differs"):
            smoke.mapping_from_observation(Fraction(241001, 24000), Fraction(1, 24000),
                9.956, True, Fraction(2057, 24000), 0)

    def test_seek_requires_one_coordinate_and_a_valid_inventory_target(self):
        for keywords in ({}, {"player_target": Fraction(1), "file_target": Fraction(1)},
                         {"player_target": Fraction(-1)}, {"file_target": Fraction(1000)}):
            with self.assertRaises(ValueError):
                smoke.select_target([Fraction(241001, 24000)], self.mapping(), **keywords)

    def test_startup_and_changed_selected_frame_do_not_count_as_held_observations(self):
        sample = [0]
        elapsed = [0.0]
        calls = [0]
        observations = []
        def value(name):
            if name == "demuxer-start-time": return 9.956
            if name == "rebase-start-time": return True
            if name == "mpv-version": return "mpv test"
            if name == "duration": return 98.517375
            if name == "pause": return True
            if name == "seeking": return sample[0] == 0
            if name == "time-pos": return 0 if sample[0] == 0 else 2057 / 24000
            if name == "enhancement-state":
                calls[0] += 1
                pts = 2058 if sample[0] == 1 and calls[0] % 2 == 0 else 2057
                return {"displayed-source-pts": pts, "displayed-timebase-num": 1, "displayed-timebase-den": 24000}
            raise AssertionError(name)
        def sleep(delay):
            elapsed[0] += delay
            sample[0] += 1
        with patch.object(smoke.time, "monotonic", side_effect=lambda: elapsed[0]), \
                patch.object(smoke.time, "sleep", side_effect=sleep):
            mapping = smoke.observe_mapping(value, [Fraction(241001, 24000)], Fraction(1, 24000), observations)
        self.assertEqual(mapping["decoderToPlayerSeconds"], 0)
        self.assertTrue(observations[0]["seekingBefore"])
        self.assertFalse(observations[1]["unchangedSelectedPTS"])
        self.assertGreaterEqual(len(observations), 5)
        self.assertGreaterEqual(observations[-1]["elapsedSeconds"] - observations[2]["elapsedSeconds"], .1)

    def test_every_retained_sidecar_prevents_launch_without_modifying_it(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            for path in smoke.evidence_paths(report):
                path.write_bytes(b"retained capture")
                with self.assertRaises(FileExistsError):
                    smoke.require_new_evidence(report)
                self.assertEqual(path.read_bytes(), b"retained capture")
                path.unlink()
            smoke.require_new_evidence(report)
            with self.assertRaisesRegex(ValueError, "collides"):
                smoke.require_new_evidence(Path(directory) / "report.log")

    def test_relative_report_keeps_callers_destination_when_child_changes_directory(self):
        caller = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            try:
                os.chdir(directory)
                requested_directory = Path.cwd()
                report = smoke.require_new_evidence(Path("artifacts/report.json"))
                self.assertEqual(report, requested_directory / "artifacts/report.json")
                self.assertTrue(all(path.is_absolute() for path in smoke.evidence_paths(report)))
                # The absolute child log argument keeps pointing to the caller's
                # artifacts even though the actual player runs from the repo.
                os.chdir(caller)
                self.assertEqual(report.with_suffix(".log"), requested_directory / "artifacts/report.log")
            finally:
                os.chdir(caller)

    def test_dangling_report_and_every_sidecar_symlink_fail_before_native_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            target = Path(directory) / "uncreated-target"
            for path in smoke.evidence_paths(report):
                with self.subTest(path=path.name):
                    path.symlink_to(target)
                    self.assertFalse(path.exists())
                    with self.assertRaises(FileExistsError):
                        smoke.require_new_evidence(report)
                    self.assertTrue(path.is_symlink())
                    self.assertFalse(target.exists())
                    path.unlink()

    def test_visibility_checks_playback_outside_completed_work(self):
        engine = {"retainedSamples": 1, "completedTotal": 1,
            "frames": [{"warmup": False, "submittedHostSeconds": 1, "completedHostSeconds": 2}]}
        events = [{"hostSeconds": timestamp, "isVisible": True, "occlusionVisible": timestamp < 3,
            "isMiniaturized": False, "appActive": True, "windowNumber": 10} for timestamp in range(5)]
        visibility = smoke.capture_visibility(engine, events, 1, 4)
        self.assertTrue(visibility["completedWork"]["eligible"])
        self.assertFalse(visibility["playbackClock"]["eligible"])
        self.assertFalse(visibility["eligible"])

    def test_timeout_reaps_an_actual_child_process(self):
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        original_wait = process.wait
        report = {"passed": True, "errors": []}
        calls = [0]
        def wait(timeout):
            calls[0] += 1
            if calls[0] == 1:
                raise subprocess.TimeoutExpired(process.args, timeout)
            return original_wait(timeout=timeout)
        try:
            with patch.object(process, "wait", side_effect=wait):
                smoke.reap_process(process, report)
            self.assertIsNotNone(process.poll())
            self.assertFalse(report["passed"])
            self.assertIn("shutdown timed out; process killed", report["errors"])
        finally:
            if process.poll() is None:
                process.kill()
                original_wait(timeout=5)

    def clock_sample(self, status="playing", active=True, valid=True, offset=.003):
        return {"elapsed": 3, "paused": False, "seeking": False, "avOffset": 0,
            "state": {"audio-status": status, "video-status": "playing", "audio-clock-active": active,
                "scheduled-avsync-valid": valid, "scheduled-avsync-seconds": offset if valid else None,
                "scheduled-audio-pts-seconds": 98.3 if valid else None,
                "scheduled-video-pts-seconds": 98.28 if valid else None}}

    def test_legacy_zero_without_validity_cannot_qualify_clock(self):
        result = smoke.summarize_scheduled_clock([{"elapsed": 3, "avOffset": 0, "state": {}}])
        self.assertFalse(result["diagnosticsAvailable"])
        self.assertEqual(result["unavailableSamples"], 1)
        self.assertIsNone(result["target20msMet"])

    def test_atomic_tail_offsets_override_legacy_zero_property(self):
        result = smoke.summarize_scheduled_clock([self.clock_sample("eof", offset=.1348)])
        self.assertEqual(result["activeTailSamples"], 1)
        self.assertEqual(result["maximumAbsoluteSeconds"], .1348)
        self.assertFalse(result["target20msMet"])

    def test_playing_draining_and_logical_eof_use_same_clock_bound(self):
        result = smoke.summarize_scheduled_clock([
            self.clock_sample("playing", offset=-.020), self.clock_sample("draining", offset=.020),
            self.clock_sample("eof", offset=.001)])
        self.assertTrue(result["target20msMet"])
        self.assertEqual(result["activeTailSamples"], 2)
        self.assertEqual(result["validSamples"], 3)

    def test_inactive_eof_is_unavailable_instead_of_zero_success(self):
        result = smoke.summarize_scheduled_clock([self.clock_sample("eof", active=False, valid=False)])
        self.assertEqual(result["inactiveSamples"], 1)
        self.assertEqual(result["validSamples"], 0)
        self.assertIsNone(result["target20msMet"])
        result = smoke.summarize_scheduled_clock([self.clock_sample(), self.clock_sample(valid=False)])
        self.assertEqual(result["invalidActiveSamples"], 1)
        self.assertIsNone(result["target20msMet"])
        sample = self.clock_sample(active=True, valid=False)
        sample["state"]["video-status"] = "eof"
        result = smoke.summarize_scheduled_clock([sample])
        self.assertEqual(result["inactiveSamples"], 1)
        self.assertEqual(result["invalidActiveSamples"], 0)

    def test_malformed_or_stale_valid_tuple_prevents_qualification(self):
        for value in (None, True, float("nan"), float("inf")):
            sample = self.clock_sample()
            sample["state"]["scheduled-avsync-seconds"] = value
            result = smoke.summarize_scheduled_clock([sample, self.clock_sample()])
            self.assertEqual(result["malformedSamples"], 1)
            self.assertIsNone(result["target20msMet"])
        sample = self.clock_sample(active=False)
        self.assertEqual(smoke.summarize_scheduled_clock([sample])["malformedSamples"], 1)

    def test_seek_pause_and_startup_are_explicitly_outside_steady_clock(self):
        for field, value in (("elapsed", 1), ("paused", True), ("seeking", True)):
            sample = self.clock_sample(offset=.3)
            sample[field] = value
            result = smoke.summarize_scheduled_clock([sample, self.clock_sample()])
            self.assertEqual(result["validSamples"], 1)
            self.assertTrue(result["target20msMet"])

    def test_eof_guard_rejects_captured_gapless_drain_and_requires_tail_overlap(self):
        log = "audio EOF reached\nvideo EOF reached\nAdaptive enhancement buffer: both playback clocks paused; video=98.308833333 audio-before=98.344241251 audio-after=98.496 transition=0.134800042\n"
        report = {"playbackReachedEOF": True, "scheduledClock": smoke.summarize_scheduled_clock([self.clock_sample("eof")])}
        self.assertFalse(smoke.validate_eof_clock(report, log)["passed"])
        fast_jump = log.replace("0.134800042", "0.001")
        self.assertFalse(smoke.validate_eof_clock(report, fast_jump)["passed"])
        short_pause = fast_jump.replace("audio-after=98.496", "audio-after=98.345241251")
        self.assertTrue(smoke.validate_eof_clock(report, short_pause)["passed"])
        report["scheduledClock"] = smoke.summarize_scheduled_clock([self.clock_sample()])
        self.assertFalse(smoke.validate_eof_clock(report, short_pause)["passed"])
        self.assertFalse(smoke.validate_eof_clock(report, "")["passed"])

    def test_eof_guard_rejects_backward_audio_clock_reset(self):
        log = "audio EOF reached\nvideo EOF reached\nAdaptive enhancement buffer: both playback clocks paused; video=98.308833333 audio-before=98.344241251 audio-after=98.244241251 transition=0.001\n"
        report = {"playbackReachedEOF": True, "scheduledClock": smoke.summarize_scheduled_clock([self.clock_sample("eof")])}
        result = smoke.validate_eof_clock(report, log)
        self.assertFalse(result["passed"])
        self.assertAlmostEqual(result["pauseAudioClockResidualRangeSeconds"][0], -.101)

    def test_malformed_pause_diagnostics_fail_instead_of_disappearing(self):
        prefix = "Adaptive enhancement buffer: both playback clocks paused; "
        for line in ("missing", "video=1 audio-before=1 audio-after=1 transition=nan",
                     "video=1 audio-before=1 audio-after=1 transition=-1"):
            with self.assertRaises(ValueError):
                smoke.enhancement_pause_transitions(prefix + line)


if __name__ == "__main__":
    unittest.main()
