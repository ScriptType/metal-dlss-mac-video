#!/usr/bin/env python3
"""Check pinned Dolby native paths and profile-specific fallback rejection."""
import argparse
from fractions import Fraction
import hashlib
import json
import os
import re
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
from dovi_fixtures import (FIXTURES, FATE_BY_PROFILE, select_fixture, source_path, source_catalog,
                           verify_source, verify_metadata, exact_inventory, native_timeline_offset)

ROOT = Path(__file__).resolve().parents[1]


def create_report_directory(report):
    """Every run owns a new directory, including failed reports and sidecars."""
    report.parent.mkdir(parents=True, exist_ok=False)


def native_case(source, directory, base_only, fixture=FIXTURES["fate-profile84"], log_directory=None, inventory=None, probe_info_control=False):
    if base_only and fixture["profile"] != 8:
        raise ValueError("Profile 5 has no HLG/PQ compatible-base case")
    name = "hlg-base" if base_only else "native-dovi"
    ipc = directory / f"{name}.sock"
    log = (log_directory or directory) / f"{name}.log"
    outputs = [ipc, log]
    fate_screenshot = ((log_directory or directory) / f"interpreted-fate-profile84-{name}.png"
                       if fixture["id"] == "fate-profile84" else None)
    if fate_screenshot:
        outputs.append(fate_screenshot)
    if inventory:
        outputs.extend((log_directory or directory) / f"interpreted-source-{index}.png" for index in range(1, 4))
    for output in outputs:
        if output.exists():
            raise FileExistsError(f"Refusing to overwrite an existing native capture: {output}")
    filters = ("format=dolbyvision=no," if base_only else "") + "@enhance:metal-hdr=processing-width=32:processing-height=24:bypass=no"
    args = [str(ROOT / "artifacts/mpv-build/mpv"), "--no-config", "--vo=gpu-next", "--gpu-api=vulkan",
            "--gpu-context=macvk", "--target-colorspace-hint=yes", "--hwdec=videotoolbox", "--pause", "--keep-open=yes",
            "--ao=null", "--input-terminal=no", f"--input-ipc-server={ipc}", f"--log-file={log}", f"--vf={filters}",
            *(["--demuxer-lavf-probe-info=yes"] if probe_info_control else []), str(source)]
    process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    stream = None
    try:
        deadline = time.monotonic() + 15
        while not ipc.exists():
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f"{name}: no native player IPC; see {log}")
            time.sleep(.05)
        connection = socket.socket(socket.AF_UNIX); connection.settimeout(10); connection.connect(str(ipc))
        stream = connection.makefile("rwb", buffering=0)
        sequence = 0

        def command(*values):
            nonlocal sequence
            sequence += 1
            stream.write((json.dumps({"command": values, "request_id": sequence}) + "\n").encode())
            while line := stream.readline():
                reply = json.loads(line)
                if reply.get("request_id") == sequence:
                    if reply["error"] != "success": raise RuntimeError(str(reply))
                    return reply.get("data")
            raise RuntimeError("mpv closed IPC")

        expected = "hlg-base-layer" if base_only else "native-dolby-vision"
        while time.monotonic() < deadline:
            state = command("get_property", "enhancement-state")
            if (state.get("native-color-path") == expected and
                    (base_only or state.get("displayed-dolby-vision-metadata")) and
                    command("get_property", "time-pos") is not None): break
            time.sleep(.05)
        else: raise RuntimeError(f"{name}: wrong native state {state}")
        assert state["source-dolby-vision"] and state["submitted-frames"] == 0
        assert state["policy"] == "bypass" and not state["buffering"]
        assert state["displayed-dolby-vision-metadata"] == (not base_only)
        tracks = command("get_property", "track-list")
        track = next(value for value in tracks if value["type"] == "video" and value.get("selected"))
        assert (track["dolby-vision-profile"], track["dolby-vision-compatibility-id"]) == (fixture["profile"], fixture["compatibility"])
        offset = Fraction(0)
        def decoder_pts(value):
            denominator = value.get("displayed-timebase-den", 0)
            return (Fraction(value["displayed-source-pts"] * value["displayed-timebase-num"], denominator)
                    if denominator > 0 else None)
        def displayed_pts(value):
            pts = decoder_pts(value)
            return pts - offset if pts is not None else None

        timeline = None
        targets = [(fixture["seekSeconds"], None)]
        if inventory:
            start = command("get_property", "demuxer-start-time")
            rebased = command("get_property", "options/rebase-start-time")
            timebase = Fraction(inventory["timebaseNumerator"], inventory["timebaseDenominator"])
            initial_decoder = decoder_pts(state)
            initial_player = command("get_property", "time-pos")
            offset = native_timeline_offset(start, rebased, initial_decoder, initial_player)
            initial_source = initial_decoder - offset
            assert initial_source in {frame["pts"] * timebase for frame in inventory["frames"]}, f"Recovered file PTS {initial_source} not in inventory"
            targets = [(float(target["pts"] * timebase + offset), target["pts"] * timebase) for target in inventory["targets"]]
            valid_source_pts = {frame["pts"] * timebase for frame in inventory["frames"]}
            timeline = {"nativeDemuxerStartTime": start, "nativeRebaseStartTime": rebased,
                        "sourceToPlayerOffset": str(offset), "initialSourcePTSSeconds": str(initial_source),
                        "initialNativeDecoderPTSSeconds": str(initial_decoder),
                        "timestampScope": "source fields in this timeline are original file PTS; raw enhancement-state displayed-source-pts is the rebased decoder PTS",
                        "initialPlayerSeconds": initial_player, "nativeDurationSeconds": command("get_property", "duration"),
                        "ffprobeFormatStartSeconds": inventory["formatStartSeconds"], "seeks": []}
        for target, exact_source in targets:
            assert 0 < target < command("get_property", "duration")
            command("seek", target, "absolute+exact")
            for _ in range(160):
                state = command("get_property", "enhancement-state")
                displayed = displayed_pts(state)
                source_at_target = (displayed is not None and
                    (displayed == exact_source if exact_source is not None else
                     displayed == Fraction(str(target)) if fixture["profile"] == 5 else abs(float(displayed) - target) < .045))
                if (abs(command("get_property", "time-pos") - target) < .045 and source_at_target and
                        state.get("native-color-path") == expected and
                        state.get("displayed-dolby-vision-metadata") == (not base_only)): break
                time.sleep(.05)
            else: raise RuntimeError(f"Native exact source seek failed: target={exact_source}, state={state}")
            assert state["submitted-frames"] == 0 and not state["buffering"] and state["policy"] == "bypass"
            if timeline is not None:
                timeline["seeks"].append({"playerTargetSeconds": target, "exactSourcePTSSeconds": str(exact_source), "state": state})
                screenshot = (log_directory or directory) / f"interpreted-source-{len(timeline['seeks'])}.png"
                command("screenshot-to-file", str(screenshot.resolve()), "video")
                image = screenshot.read_bytes()
                assert image[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", image[16:24]) == (1920, 1080)
                after_capture = command("get_property", "enhancement-state")
                assert displayed_pts(after_capture) == exact_source and after_capture["displayed-dolby-vision-metadata"]
                assert after_capture["submitted-frames"] == 0
                timeline["seeks"][-1]["screenshot"] = {
                    "path": str(screenshot), "sha256": hashlib.sha256(image).hexdigest(),
                    "width": 1920, "height": 1080, "stateAfterCapture": after_capture,
                    "scope": "libplacebo separate video screenshot render; not raw swapchain, compositor/SCK or physical display"}
                command("set_property", "pause", False)
                observed = set()
                deadline = time.monotonic() + 1
                while time.monotonic() < deadline:
                    playing = command("get_property", "enhancement-state")
                    assert playing["displayed-dolby-vision-metadata"] and playing["native-color-path"] == expected
                    assert playing["submitted-frames"] == 0 and not playing["buffering"]
                    current_source = displayed_pts(playing)
                    assert current_source in valid_source_pts, "Native output left the exact source timestamp inventory"
                    observed.add(str(current_source))
                    time.sleep(.04)
                command("set_property", "pause", True)
                assert len(observed) >= 6, "Native representative sequence did not progress"
                timeline["seeks"][-1]["progressingNativePTSCount"] = len(observed)
        if inventory:
            near_end_source = inventory["frames"][-13]["pts"] * timebase
            near_end_player = float(near_end_source + offset)
            command("seek", near_end_player, "absolute+exact")
            for _ in range(160):
                near_end_state = command("get_property", "enhancement-state")
                if displayed_pts(near_end_state) == near_end_source: break
                time.sleep(.05)
            timeline["nearEnd"] = {"exactSourcePTSSeconds": str(near_end_source), "playerTargetSeconds": near_end_player,
                "selectedExactSource": displayed_pts(near_end_state) == near_end_source,
                "actualPlayerSeconds": command("get_property", "time-pos"),
                "nativeDurationSeconds": command("get_property", "duration"), "state": near_end_state}
            assert timeline["nearEnd"]["selectedExactSource"], f"Native near-end seek lost exact source identity: {timeline['nearEnd']}"
        interpreted = None
        if fate_screenshot:
            before_capture = command("get_property", "enhancement-state")
            command("screenshot-to-file", str(fate_screenshot.resolve()), "video")
            image = fate_screenshot.read_bytes()
            assert image[:8] == b"\x89PNG\r\n\x1a\n"
            width, height = struct.unpack(">II", image[16:24])
            assert sorted((width, height)) == [1080, 1920], "Unexpected rotated FATE screenshot dimensions"
            after_capture = command("get_property", "enhancement-state")
            assert displayed_pts(after_capture) == displayed_pts(before_capture)
            assert after_capture["displayed-dolby-vision-metadata"] == (not base_only)
            assert after_capture["submitted-frames"] == 0
            interpreted = {"path": str(fate_screenshot), "sha256": hashlib.sha256(image).hexdigest(),
                "width": width, "height": height, "stateAfterCapture": after_capture,
                "exactSourcePTSSeconds": str(displayed_pts(after_capture)),
                "scope": "libplacebo separate video screenshot render; not raw swapchain, compositor/SCK or physical display"}
        tracks = command("get_property", "track-list")
        command("quit")
        process.wait(timeout=10)
        assert process.returncode == 0
        return {"passed": True, "state": state, "tracks": tracks, "seekSeconds": target,
                "exitCode": process.returncode, "log": str(log), "timeline": timeline, "interpretedScreenshot": interpreted}
    finally:
        if stream: stream.close()
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)


def metadata_guard(source, directory, synthetic=False, video_only=False):
    log = directory / "missing-metadata.log"
    if log.exists():
        raise FileExistsError(f"Refusing to overwrite an existing metadata guard: {log}")
    result = subprocess.run([str(ROOT / "artifacts/mpv-build/mpv"), "--no-config", "--vo=null", "--ao=null", "--hwdec=no",
        "--frames=1", "--vf=format=dolbyvision=no,metal-hdr=bypass=yes", *(["--aid=no"] if video_only else []), str(source)], capture_output=True, text=True, timeout=15)
    diagnostic = result.stdout + result.stderr
    log.write_text(diagnostic)
    assert "Dolby Vision lacks a supported metadata path" in diagnostic
    assert "Disabling filter" not in diagnostic and "VO:" not in diagnostic
    counts = re.search(r"HDR engine: submitted=(\d+) completed=(\d+) emitted=(\d+)", diagnostic)
    assert counts and tuple(map(int, counts.groups())) == (0, 0, 0), "Rejected Dolby input entered the engine"
    # The P8.4 synthetic case retains an audio track that can end normally after
    # the video guard rejects; the actual video-only P5 vector must exit in error.
    if not synthetic:
        assert result.returncode == 2, "mpv did not report the expected input failure"
    return {"passed": True, "syntheticNegativeSignalingOnly": synthetic,
            "actualPinnedProfile5Input": not synthetic, "metadataMappingDisabled": True, "audioDisabledForGuard": video_only,
            "noVideoOutput": True, "noFilterAutoRemoval": True, "zeroNeuralSubmissions": True, "exitCode": result.returncode, "diagnostic": diagnostic}


def app_case(source, directory, fixture, inventory_path=None, probe_info_control=False):
    env = dict(os.environ, METAL_DLSS_MPV_LIBRARY=str(ROOT / "artifacts/mpv-build/libmpv.2.dylib"),
        HDRPLAYER_UI_SMOKE_KIND="dolby-vision", HDRPLAYER_DV_FIXTURE=fixture["id"],
        HDRPLAYER_UI_SMOKE_REPORT=str(directory / "dom.json"), HDRPLAYER_LIFECYCLE_LOG=str(directory / "lifecycle.jsonl"))
    env.pop("HDRPLAYER_DV_PROFILE", None)
    env.pop("HDRPLAYER_DV_INVENTORY", None)
    env.pop("HDRPLAYER_DV_PROBE_INFO", None)
    if probe_info_control:
        env["HDRPLAYER_DV_PROBE_INFO"] = "yes"
    if inventory_path:
        env["HDRPLAYER_DV_INVENTORY"] = str(inventory_path.resolve())
    env.pop("HDRPLAYER_UI_SMOKE_KEEP_PREFERENCES", None)
    env.pop("HDRPLAYER_ENABLE_PIP", None)
    for name in ("dom.json", "lifecycle.jsonl", "player.log"):
        if (directory / name).exists():
            raise FileExistsError(f"Refusing to overwrite an existing app capture: {directory / name}")
    with (directory / "player.log").open("w") as log:
        result = subprocess.run([str(ROOT / ".build/debug/HDRPlayer"), str(source)], cwd=ROOT, env=env,
                                stdout=log, stderr=subprocess.STDOUT, timeout=60)
    assert result.returncode == 0, f"DOM player exited {result.returncode}"
    dom = json.loads((directory / "dom.json").read_text())
    assert dom["passed"], dom.get("failure", "Dolby DOM check failed")
    rows = [json.loads(line) for line in (directory / "lifecycle.jsonl").read_text().splitlines()]
    events = [row["event"] for row in rows]
    assert events.index("termination-requested") < events.index("native-worker-destroyed") < events.index("diagnostic-finish")
    assert rows[-1]["details"]["workerDestroyed"] and rows[-1]["details"]["nativeChildViews"] == 0
    return {"passed": True, "exitCode": result.returncode, "checks": dom["checks"],
            "nativeCoreDestroyed": True, "report": str(directory / "dom.json")}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", choices=FATE_BY_PROFILE, help="Legacy FATE profile selector; default is 8.4")
    parser.add_argument("--fixture", choices=FIXTURES, help="Explicit fixture identity, independent of Dolby profile")
    parser.add_argument("--source", type=Path, help="Optional path to the selected fixture; pinned size/SHA must match")
    parser.add_argument("--app", action="store_true", help="Also run the existing shipped DOM and native teardown check")
    parser.add_argument("--probe-info-control", action="store_true", help="Diagnostic only: explicitly enable lavf stream-info probing in native/app cases")
    parser.add_argument("--report", type=Path, default=ROOT / "artifacts/dovi-passthrough/report.json")
    args = parser.parse_args()
    fixture = select_fixture(args.fixture, args.profile)
    source = (args.source or source_path(fixture)).resolve()
    checksum = verify_source(source, fixture)
    payload = source.read_bytes()
    create_report_directory(args.report)
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_streams", "-show_frames",
                            "-read_intervals", "%+#2", "-of", "json", str(source)], capture_output=True, text=True, check=True, timeout=15)
    decoded = json.loads(probe.stdout)
    metadata = verify_metadata(decoded, fixture)
    (args.report.parent / "decoded-metadata.json").write_text(probe.stdout)
    inventory = None
    inventory_path = None
    if fixture.get("catalogAsset"):
        packets = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-show_packets", "-of", "json", str(source)],
                                 capture_output=True, text=True, check=True, timeout=30)
        inventory = exact_inventory(json.loads(packets.stdout), fixture)
        (args.report.parent / "packet-inventory.json").write_text(packets.stdout)
        inventory_path = args.report.parent / "seek-inventory.json"
        inventory_path.write_text(json.dumps(inventory, indent=2) + "\n")
    binaries = {"mpv": ROOT / "artifacts/mpv-build/mpv", "FrameEngineShared": ROOT / ".build/debug/libFrameEngineShared.dylib"}
    if args.app:
        binaries.update(HDRPlayer=ROOT / ".build/debug/HDRPlayer", libmpv=ROOT / "artifacts/mpv-build/libmpv.2.dylib")
    harness_paths = ["scripts/test-dovi-passthrough.py", "scripts/dovi_fixtures.py",
                     "apps/macos/Sources/PlayerSmokeCheck.swift", "apps/macos/Sources/MPVPlaybackController.swift"]
    core_paths = ["vendor/mpv/demux/demux_lavf.c", "vendor/mpv/demux/lavf_timing.h", "vendor/mpv/video/decode/vd_lavc.c",
                  "vendor/mpv/player/command.c", "vendor/mpv/video/filter/vf_metal_hdr.m",
                  "vendor/mpv/video/out/vo_gpu_next.c", "vendor/libplacebo/src/shaders/colorspace.c",
                  "vendor/libplacebo/src/include/libplacebo/utils/libav_internal.h"]
    report = {"source": str(source), "sha256": checksum, "fixture": fixture, "catalog": source_catalog(fixture), "decodedMetadata": metadata,
              "probeInfoControl": args.probe_info_control,
              "harnessSourceSHA256": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in harness_paths},
              "coreSourceSHA256": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in core_paths},
              "mpvRevisionAtCapture": subprocess.check_output(["git", "-C", str(ROOT / "vendor/mpv"), "rev-parse", "HEAD"], text=True).strip(),
              "sourceHashScope": "Selected harness, timing and Dolby-render source files at capture; source hashes also cover a pre-commit core build, binary hashes identify the actual executable",
              "scope": "Profile-specific native metadata/path and fallback guards; Apple adds representative-frame transport checks. No colour calibration or Dolby certification qualification",
              "colorQualified": False, "binaries": {name: {"path": str(path.resolve()), "beforeSHA256": hashlib.sha256(path.read_bytes()).hexdigest()} for name, path in binaries.items()}}
    try:
        with tempfile.TemporaryDirectory(prefix="dovi-native-") as temporary:
            directory = Path(temporary)
            report["native"] = native_case(source, directory, False, fixture, args.report.parent, inventory, args.probe_info_control)
            if fixture["id"] == "fate-profile84":
                report["baseLayer"] = native_case(source, directory, True, fixture, args.report.parent, probe_info_control=args.probe_info_control)
                # Deliberately inconsistent container signaling is a negative test:
                # retain the actual HLG/RPU payload but declare no compatible base.
                corrupted = bytearray(payload)
                offset = corrupted.find(b"dvvC")
                if offset < 0: raise RuntimeError("Expected sample decoder configuration")
                corrupted[offset + 6] = (5 << 1) | (corrupted[offset + 6] & 1)
                corrupted[offset + 8] &= 0x0F
                invalid = directory / "incompatible-signaling.mov"; invalid.write_bytes(corrupted)
                report["missingMetadataGuard"] = metadata_guard(invalid, args.report.parent, synthetic=True)
            else:
                report["missingMetadataGuard"] = metadata_guard(source, args.report.parent, video_only=bool(inventory))
                report["baseLayer"] = {"available": False, "reason": "Profile 5 declares no compatible PQ or HLG base; missing metadata must reject"}
        if args.app:
            report["app"] = app_case(source, args.report.parent, fixture, inventory_path, args.probe_info_control)
        report["passed"] = True
    except Exception as error:
        report["passed"] = False
        report["failure"] = f"{type(error).__name__}: {error}"
    finally:
        for name, path in binaries.items():
            report["binaries"][name]["afterSHA256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        report["binariesUnchanged"] = all(value["beforeSHA256"] == value["afterSHA256"] for value in report["binaries"].values())
        report["sourcesUnchanged"] = all(hashlib.sha256((ROOT / path).read_bytes()).hexdigest() == expected
            for key in ("harnessSourceSHA256", "coreSourceSHA256") for path, expected in report[key].items())
        if not report["binariesUnchanged"]:
            report["passed"] = False
            report["failure"] = "Measured binaries changed during profile check"
        if not report["sourcesUnchanged"]:
            report["passed"] = False
            report["failure"] = "Measured source files changed during profile check"
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(args.report)
    if not report["passed"]:
        raise SystemExit(report["failure"])



if __name__ == "__main__":
    main()
