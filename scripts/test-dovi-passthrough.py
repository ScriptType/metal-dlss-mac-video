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
import subprocess
import tempfile
import time
from dovi_fixtures import FIXTURES, source_path, verify_source, verify_metadata

ROOT = Path(__file__).resolve().parents[1]


def native_case(source, directory, base_only, fixture=FIXTURES["8.4"], log_directory=None):
    if base_only and fixture["profile"] != 8:
        raise ValueError("Profile 5 has no HLG/PQ compatible-base case")
    name = "hlg-base" if base_only else "native-dovi"
    ipc = directory / f"{name}.sock"
    log = (log_directory or directory) / f"{name}.log"
    filters = ("format=dolbyvision=no," if base_only else "") + "@enhance:metal-hdr=processing-width=32:processing-height=24:bypass=no"
    args = [str(ROOT / "artifacts/mpv-build/mpv"), "--no-config", "--vo=gpu-next", "--gpu-api=vulkan",
            "--gpu-context=macvk", "--target-colorspace-hint=yes", "--hwdec=videotoolbox", "--pause", "--keep-open=yes",
            "--ao=null", "--input-terminal=no", f"--input-ipc-server={ipc}", f"--log-file={log}", f"--vf={filters}", str(source)]
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
        target = fixture["seekSeconds"]
        assert 0 < target < command("get_property", "duration")
        command("seek", target, "absolute+exact")
        for _ in range(100):
            state = command("get_property", "enhancement-state")
            denominator = state.get("displayed-timebase-den", 0)
            displayed = (Fraction(state.get("displayed-source-pts", -1) * state.get("displayed-timebase-num", 0), denominator)
                         if denominator > 0 else None)
            source_at_target = (displayed is not None and
                (displayed == Fraction(str(target)) if fixture["profile"] == 5 else abs(float(displayed) - target) < .045))
            if (abs(command("get_property", "time-pos") - target) < .045 and source_at_target and
                    state.get("native-color-path") == expected and
                    state.get("displayed-dolby-vision-metadata") == (not base_only)): break
            time.sleep(.05)
        else: raise RuntimeError("Native exact seek failed")
        state = command("get_property", "enhancement-state")
        assert state["native-color-path"] == expected and state["submitted-frames"] == 0
        assert state["displayed-dolby-vision-metadata"] == (not base_only)
        tracks = command("get_property", "track-list")
        command("quit")
        process.wait(timeout=10)
        assert process.returncode == 0
        return {"passed": True, "state": state, "tracks": tracks, "seekSeconds": target,
                "exitCode": process.returncode, "log": str(log)}
    finally:
        if stream: stream.close()
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)


def metadata_guard(source, directory, synthetic=False):
    result = subprocess.run([str(ROOT / "artifacts/mpv-build/mpv"), "--no-config", "--vo=null", "--ao=null", "--hwdec=no",
        "--frames=1", "--vf=format=dolbyvision=no,metal-hdr=bypass=yes", str(source)], capture_output=True, text=True, timeout=15)
    diagnostic = result.stdout + result.stderr
    log = directory / "missing-metadata.log"; log.write_text(diagnostic)
    assert "Dolby Vision lacks a supported metadata path" in diagnostic
    assert "Disabling filter" not in diagnostic and "VO:" not in diagnostic
    counts = re.search(r"HDR engine: submitted=(\d+) completed=(\d+) emitted=(\d+)", diagnostic)
    assert counts and tuple(map(int, counts.groups())) == (0, 0, 0), "Rejected Dolby input entered the engine"
    # The P8.4 synthetic case retains an audio track that can end normally after
    # the video guard rejects; the actual video-only P5 vector must exit in error.
    if not synthetic:
        assert result.returncode == 2, "mpv did not report the expected input failure"
    return {"passed": True, "syntheticNegativeSignalingOnly": synthetic,
            "actualPinnedProfile5Input": not synthetic, "metadataMappingDisabled": True,
            "noVideoOutput": True, "noFilterAutoRemoval": True, "zeroNeuralSubmissions": True, "exitCode": result.returncode, "diagnostic": diagnostic}


def app_case(source, directory, profile):
    env = dict(os.environ, METAL_DLSS_MPV_LIBRARY=str(ROOT / "artifacts/mpv-build/libmpv.2.dylib"),
        HDRPLAYER_UI_SMOKE_KIND="dolby-vision", HDRPLAYER_DV_PROFILE=profile,
        HDRPLAYER_UI_SMOKE_REPORT=str(directory / "dom.json"), HDRPLAYER_LIFECYCLE_LOG=str(directory / "lifecycle.jsonl"))
    env.pop("HDRPLAYER_UI_SMOKE_KEEP_PREFERENCES", None)
    env.pop("HDRPLAYER_ENABLE_PIP", None)
    # A failed process may not reuse a successful report from an older run.
    for name in ("dom.json", "lifecycle.jsonl"):
        (directory / name).unlink(missing_ok=True)
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
    parser.add_argument("--profile", choices=FIXTURES, default="8.4")
    parser.add_argument("--source", type=Path, help="Optional path to the selected fixture; pinned size/SHA must match")
    parser.add_argument("--app", action="store_true", help="Also run the existing shipped DOM and native teardown check")
    parser.add_argument("--report", type=Path, default=ROOT / "artifacts/dovi-passthrough/report.json")
    args = parser.parse_args()
    fixture = FIXTURES[args.profile]
    source = (args.source or source_path(fixture)).resolve()
    checksum = verify_source(source, fixture)
    payload = source.read_bytes()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_streams", "-show_frames",
                            "-read_intervals", "%+#2", "-of", "json", str(source)], capture_output=True, text=True, check=True, timeout=15)
    decoded = json.loads(probe.stdout)
    metadata = verify_metadata(decoded, fixture)
    (args.report.parent / "decoded-metadata.json").write_text(probe.stdout)
    binaries = {"mpv": ROOT / "artifacts/mpv-build/mpv", "FrameEngineShared": ROOT / ".build/debug/libFrameEngineShared.dylib"}
    if args.app:
        binaries.update(HDRPlayer=ROOT / ".build/debug/HDRPlayer", libmpv=ROOT / "artifacts/mpv-build/libmpv.2.dylib")
    report = {"source": str(source), "sha256": checksum, "fixture": fixture, "decodedMetadata": metadata,
              "scope": "Profile-specific native metadata/path and fallback guards; no colour calibration, varied-content or Dolby certification qualification",
              "colorQualified": False, "binaries": {name: {"path": str(path.resolve()), "beforeSHA256": hashlib.sha256(path.read_bytes()).hexdigest()} for name, path in binaries.items()}}
    try:
        with tempfile.TemporaryDirectory(prefix="dovi-native-") as temporary:
            directory = Path(temporary)
            report["native"] = native_case(source, directory, False, fixture, args.report.parent)
            if args.profile == "8.4":
                report["baseLayer"] = native_case(source, directory, True, fixture, args.report.parent)
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
                report["missingMetadataGuard"] = metadata_guard(source, args.report.parent)
                report["baseLayer"] = {"available": False, "reason": "Profile 5 declares no compatible PQ or HLG base; missing metadata must reject"}
        if args.app:
            report["app"] = app_case(source, args.report.parent, args.profile)
        report["passed"] = True
    except Exception as error:
        report["passed"] = False
        report["failure"] = f"{type(error).__name__}: {error}"
    finally:
        for name, path in binaries.items():
            report["binaries"][name]["afterSHA256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        report["binariesUnchanged"] = all(value["beforeSHA256"] == value["afterSHA256"] for value in report["binaries"].values())
        if not report["binariesUnchanged"]:
            report["passed"] = False
            report["failure"] = "Measured binaries changed during profile check"
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(args.report)
    if not report["passed"]:
        raise SystemExit(report["failure"])



if __name__ == "__main__":
    main()
