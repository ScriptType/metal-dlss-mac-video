import copy
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("apple_hdr_playback", Path(__file__).with_name("test-apple-hdr-playback.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class AppleHDRPlaybackTest(unittest.TestCase):
    def inventory(self):
        packets = {"streams": [
            {"codec_type": "video", "index": 0, "time_base": "1/24000", "width": 1920, "height": 1080},
            {"codec_type": "audio", "index": 1, "codec_name": "aac", "sample_rate": "48000", "channels": 2, "time_base": "1/48000"}],
            "format": {"start_time": "9.956000"},
            "packets": [{"stream_index": 0, "pts": 241001 + index * 1001, "duration": 1001} for index in range(2360)] +
                       [{"stream_index": 1, "pts": 477888 + index * 1024, "duration": 1024} for index in range(4617)]}
        dynamic = json.loads('{"side_data_type":"HDR Dynamic Metadata SMPTE2094-40 (HDR10+)","num_windows":1,"maxscl":"5417/100000","maxscl":"4729/100000","maxscl":"5225/100000","average_maxrgb":"520/100000"}', object_pairs_hook=probe.Pairs)
        frames = {"frames": [dict(probe.COLOR, pts=241001 + index * 1001, duration=1001,
                                  side_data_list=[copy.deepcopy(dynamic)]) for index in range(2360)]}
        return packets, frames

    def test_preserves_three_duplicate_maxscl_components_and_source_origin(self):
        packets, frames = self.inventory()
        result = probe.parse_inventory(packets, frames, 1500)
        self.assertEqual(result["expectedMetadata"], {"scene-max-r": 541.7, "scene-max-g": 472.9, "scene-max-b": 522.5, "scene-avg": 52.0})
        self.assertEqual(result["sourcePTS"], 1742501)
        self.assertEqual(result["formatStartSeconds"], 9.956)
        self.assertNotEqual(result["formatStartSeconds"], result["firstVideoPTS"]["value"] / 24000)

    def test_rejects_missing_channel_in_duplicate_key_metadata(self):
        packets, frames = self.inventory()
        dynamic = frames["frames"][1500]["side_data_list"][0]
        dynamic.pairs = [(key, value) for key, value in dynamic.pairs if value != "4729/100000"]
        with self.assertRaisesRegex(ValueError, "maxSCL"):
            probe.parse_inventory(packets, frames, 1500)

    def test_rejects_wrong_decoded_pts_despite_nominal_fps(self):
        packets, frames = self.inventory()
        frames["frames"][1500]["pts"] += 1
        with self.assertRaisesRegex(ValueError, "Decoded presentation"):
            probe.parse_inventory(packets, frames, 1500)

    def test_rejects_missing_pq_tag_or_dynamic_metadata(self):
        for field in ("color_transfer", "side_data_list"):
            packets, frames = self.inventory()
            del frames["frames"][1500][field]
            with self.assertRaises(ValueError):
                probe.parse_inventory(packets, frames, 1500)

    def test_rejects_video_origin_substituted_for_container_origin(self):
        packets, frames = self.inventory()
        packets["format"]["start_time"] = str(241001 / 24000)
        with self.assertRaisesRegex(ValueError, "Container start"):
            probe.parse_inventory(packets, frames, 1500)

    def test_float_statistics_preserve_negative_and_extended_values_ignore_padding_alpha(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frame.rgba16f"
            path.write_bytes(struct.pack("<eeee", -1, 1, 64, 2) + b"\xff" * 8)
            result = probe.float_statistics(path, {"width": 1, "height": 1, "bytesPerRow": 16, "sha256": probe.sha(path)})
            self.assertEqual(result["minimum"], -203)
            self.assertEqual(result["maximum"], 12992)
            self.assertEqual(result["negativeComponents"], 1)
            self.assertEqual(result["above10000Components"], 1)

    def test_float_statistics_reject_nonfinite_or_changed_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frame.rgba16f"
            path.write_bytes(struct.pack("<eeee", 0, 1, float("inf"), 1))
            description = {"width": 1, "height": 1, "bytesPerRow": 8, "sha256": probe.sha(path)}
            with self.assertRaisesRegex(ValueError, "Nonfinite"):
                probe.float_statistics(path, description)
            path.write_bytes(struct.pack("<eeee", 0, 1, 2, 1))
            with self.assertRaisesRegex(ValueError, "hash"):
                probe.float_statistics(path, description)

    def test_target_validation_rejects_old_203_nit_mapping_for_extended_source(self):
        phase = {"video-out-params": {"max-luma": 1018.65},
                 "video-target-params": {"primaries": "bt.2020", "gamma": "linear", "max-luma": 203}}
        with self.assertRaisesRegex(ValueError, "target peak differs"):
            probe.validate_target_range(phase)
        phase["video-target-params"]["max-luma"] = 1018.65
        self.assertEqual(probe.validate_target_range(phase)["absoluteDifferenceNits"], 0)
        phase["video-target-params"]["gamma"] = "pq"
        with self.assertRaisesRegex(ValueError, "target is not linear"):
            probe.validate_target_range(phase)

    def test_native_zero_origin_accepts_nonzero_ffprobe_provenance_and_exact_held_pair(self):
        initial = {"originalFilePTS": {"value": 241001, "timescale": 24000},
                   "decoderPTS": {"value": 241001, "timescale": 24000},
                   "playerPTSSeconds": 241001 / 24000, "decoderToPlayerSeconds": 0}
        mapping = {"ffprobeFormatStartSeconds": 9.956, "nativeDemuxerStartSeconds": 0,
                   "nativeRebaseStartTime": True, "observedDecoderToPlayerSeconds": 0,
                   "demuxPacketOffset": {"value": 0, "timescale": 24000},
                   "heldInitialIdentity": initial}
        self.assertEqual(probe.validate_timeline_mapping(mapping, [initial])["verifiedHeldPairs"], 2)
        incorrect = copy.deepcopy(mapping)
        incorrect["demuxPacketOffset"]["value"] = -238944
        with self.assertRaisesRegex(ValueError, "packet offset disagrees"):
            probe.validate_timeline_mapping(incorrect, [initial])
        incorrect = copy.deepcopy(initial)
        incorrect["playerPTSSeconds"] -= 9.956
        with self.assertRaisesRegex(ValueError, "Held decoder/player pair"):
            probe.validate_timeline_mapping(mapping, [incorrect])

    def test_observed_nonzero_native_origin_respects_both_rebase_modes(self):
        for rebased in (True, False):
            offset_ticks = -238944 if rebased else 0
            decoder_pts = 241001 + offset_ticks
            initial = {"originalFilePTS": {"value": 241001, "timescale": 24000},
                       "decoderPTS": {"value": decoder_pts, "timescale": 24000},
                       "playerPTSSeconds": decoder_pts / 24000, "decoderToPlayerSeconds": 0}
            mapping = {"ffprobeFormatStartSeconds": 9.956, "nativeDemuxerStartSeconds": 9.956,
                       "nativeRebaseStartTime": rebased, "observedDecoderToPlayerSeconds": 0,
                       "demuxPacketOffset": {"value": offset_ticks, "timescale": 24000},
                       "heldInitialIdentity": initial}
            self.assertEqual(probe.validate_timeline_mapping(mapping, [initial])["demuxPacketOffset"]["value"], offset_ticks)
            incorrect = copy.deepcopy(initial)
            incorrect["decoderPTS"]["value"] += 1
            with self.assertRaisesRegex(ValueError, "recover exact file PTS"):
                probe.validate_timeline_mapping(mapping, [incorrect])

    def test_decoder_to_player_offset_is_separate_from_demux_offset(self):
        initial = {"originalFilePTS": {"value": 240000, "timescale": 24000},
                   "decoderPTS": {"value": 1056, "timescale": 24000},
                   "playerPTSSeconds": 0.294, "decoderToPlayerSeconds": 0.25}
        mapping = {"ffprobeFormatStartSeconds": 9.956, "nativeDemuxerStartSeconds": 9.956,
                   "nativeRebaseStartTime": True, "observedDecoderToPlayerSeconds": 0.25,
                   "demuxPacketOffset": {"value": -238944, "timescale": 24000},
                   "heldInitialIdentity": initial}
        self.assertEqual(probe.validate_timeline_mapping(mapping, [initial])["decoderToPlayerSeconds"], 0.25)

    def test_last_frame_end_requires_full_span_not_longest_track_duration(self):
        counts = {"submitted-frames": 2, "completed-frames": 2}
        check = {"declaredPlayerEndSeconds": 98.4756667,
                 "lastFramePlayerEndSeconds": 98.517375,
                 "inferenceBefore": counts, "inferenceAfter": dict(counts)}
        with self.assertRaisesRegex(ValueError, "excludes part of the last"):
            probe.validate_native_end(check)
        check["declaredPlayerEndSeconds"] = 98.517375
        self.assertEqual(probe.validate_native_end(check)["remainingRangeSeconds"], 0)
        check["inferenceAfter"]["submitted-frames"] += 1
        with self.assertRaisesRegex(ValueError, "changed neural work"):
            probe.validate_native_end(check)

    def test_actual_native_cv_attachment_dictionary_keys_and_values(self):
        # Shape retained from the completed RGBA16F buffer in the real Apple
        # HDR10+ capture; raw CVBufferCopyAttachments names include CVImageBuffer.
        actual = {"CGColorSpace": {"name": "kCGColorSpaceExtendedLinearITUR_2020", "model": 1},
                  "CVImageBufferColorPrimaries": "ITU_R_2020",
                  "CVImageBufferTransferFunction": "Linear", "HorizontalDisparityAdjustment": 0}
        probe.validate_float_attachments(actual)
        for key, wrong in (("CVImageBufferColorPrimaries", "ITU_R_709_2"),
                           ("CVImageBufferTransferFunction", "SMPTE_ST_2084_PQ")):
            changed = copy.deepcopy(actual); changed[key] = wrong
            with self.assertRaisesRegex(ValueError, "attachment contract"):
                probe.validate_float_attachments(changed)
        aliases = {"ColorPrimaries": "ITU_R_2020", "TransferFunction": "Linear", "CGColorSpace": actual["CGColorSpace"]}
        with self.assertRaisesRegex(ValueError, "attachment contract"):
            probe.validate_float_attachments(aliases)

    def test_metadata_only_records_occlusion_without_passing_sck_acceptance(self):
        row = {"visible": True, "occlusionVisible": False, "miniaturized": False,
               "windowFrame": [180, 200, 960, 540], "hostBounds": [0, 0, 960, 540],
               "metalLayer": {"drawableSize": [1920, 1080]}}
        result = probe.validate_capture_coverage([row], metadata_only=True)
        self.assertFalse(result["visibilityMaintained"])
        self.assertEqual(result["sckAcceptance"], "not-requested")
        with self.assertRaisesRegex(ValueError, "visibility"):
            probe.validate_capture_coverage([row], metadata_only=False)
        row["occlusionVisible"] = True
        moved = copy.deepcopy(row); moved["windowFrame"][0] = -1683
        with self.assertRaisesRegex(ValueError, "geometry moved"):
            probe.validate_capture_coverage([row, moved], metadata_only=False)


if __name__ == "__main__":
    unittest.main()
