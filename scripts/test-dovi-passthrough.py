#!/usr/bin/env python3
"""Check native P8.4 passthrough, explicit HLG base fallback and a negative guard."""
import argparse
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def native_case(source, directory, base_only):
    name = "hlg-base" if base_only else "native-dovi"
    ipc, log = directory / f"{name}.sock", directory / f"{name}.log"
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
        command("seek", .7, "absolute+exact")
        for _ in range(100):
            if abs(command("get_property", "time-pos") - .7) < .08: break
            time.sleep(.05)
        else: raise RuntimeError("Native exact seek failed")
        state = command("get_property", "enhancement-state")
        assert state["native-color-path"] == expected and state["submitted-frames"] == 0
        tracks = command("get_property", "track-list")
        command("quit")
        process.wait(timeout=10)
        assert process.returncode == 0
        return {"passed": True, "state": state, "tracks": tracks, "exitCode": process.returncode, "log": str(log)}
    finally:
        if stream: stream.close()
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, default=ROOT / "artifacts/dovi-passthrough/report.json")
    args = parser.parse_args()
    source = ROOT / "assets/test-clips/dolbyvision/dv84.mov"
    payload = source.read_bytes()
    checksum = hashlib.sha256(payload).hexdigest()
    assert checksum == "aaa9289a9755eaebd9962204f24a6acf8a19ff104657a3a79b6b1fa672993721"
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {"source": str(source), "sha256": checksum, "scope": "Native P8.4 path and policy guards, not color calibration or Profile 5 playback qualification"}
    with tempfile.TemporaryDirectory(prefix="dovi-native-") as temporary:
        directory = Path(temporary)
        report["native"] = native_case(source, directory, False)
        report["baseLayer"] = native_case(source, directory, True)
        # Deliberately inconsistent container signaling is a negative test only:
        # preserve the actual HLG/RPU payload, declare no compatible base, then
        # disable RPU mapping to simulate missing required decoded metadata.
        corrupted = bytearray(payload)
        offset = corrupted.find(b"dvvC")
        if offset < 0: raise RuntimeError("Expected sample decoder configuration")
        corrupted[offset + 6] = (5 << 1) | (corrupted[offset + 6] & 1)
        corrupted[offset + 8] &= 0x0F
        invalid = directory / "incompatible-signaling.mov"; invalid.write_bytes(corrupted)
        result = subprocess.run([str(ROOT / "artifacts/mpv-build/mpv"), "--no-config", "--vo=null", "--ao=null", "--hwdec=no",
            "--frames=1", "--vf=format=dolbyvision=no,metal-hdr=bypass=yes", str(invalid)], capture_output=True, text=True, timeout=15)
        diagnostic = result.stdout + result.stderr
        assert "Dolby Vision lacks a supported metadata path" in diagnostic
        assert "Disabling filter" not in diagnostic and "VO:" not in diagnostic
        report["missingMetadataGuard"] = {"passed": True, "syntheticNegativeSignalingOnly": True, "exitCode": result.returncode, "diagnostic": diagnostic}
        for name in ("native", "baseLayer"):
            source_log = Path(report[name]["log"])
            destination = args.report.parent / source_log.name
            destination.write_bytes(source_log.read_bytes()); report[name]["log"] = str(destination)
    report["passed"] = True
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
