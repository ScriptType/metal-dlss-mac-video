#!/usr/bin/env python3
"""Validate source-bound Prepared playback, exact hits/misses and process reuse."""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]


def check_source_guards(source, directory):
    config = directory / "guard-configuration.json"
    request = {"sourcePath": str(directory / "wrong-source.mp4"),
               "cacheDirectory": str(directory / "guard-cache"), "capacityBytes": 33554432}
    config.write_text(json.dumps(request))
    command = [str(ROOT / "artifacts/mpv-build/mpv"), "--no-config", "--vo=null", "--ao=null",
        "--frames=1", "--hwdec=no", "--msg-level=all=error",
        f"--vf=metal-hdr=prepared-config={config}:processing-width=32:processing-height=24:strength=0"]
    result = subprocess.run([*command, str(source)], capture_output=True, text=True, timeout=10)
    mismatch = result.stdout + result.stderr
    if "Prepared source differs" not in mismatch:
        raise RuntimeError(f"different opened source was not rejected: {mismatch}")
    multiple = directory / "two-video.mp4"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(source),
        "-map", "0:v:0", "-map", "0:v:0", "-c", "copy", str(multiple)], check=True)
    request["sourcePath"] = str(multiple)
    config.write_text(json.dumps(request))
    result = subprocess.run([*command, "--vid=2", str(multiple)], capture_output=True, text=True, timeout=10)
    second = result.stdout + result.stderr
    if "first video stream" not in second:
        raise RuntimeError(f"second video stream was not rejected: {second}")
    return {"wrongSourceRejected": True, "nonFirstVideoRejected": True,
            "wrongSourceDiagnostic": mismatch.strip(), "nonFirstVideoDiagnostic": second.strip()}


class Playback:
    def __init__(self, source, configuration, log, model):
        self.directory = tempfile.TemporaryDirectory(prefix="mpv-prepared-ipc-")
        path = Path(self.directory.name) / "ipc"
        self.sequence = 0
        effect = 1 if model else 0
        value = str(configuration)
        options = f"@enhance:metal-hdr=prepared-config=%{len(value.encode())}%{value}:processing-width=32:processing-height=24:strength={effect}:policy=adaptive"
        if model:
            value = str(model)
            options += f":model=%{len(value.encode())}%{value}"
        self.process = subprocess.Popen([str(ROOT / "artifacts/mpv-build/mpv"), "--no-config",
            "--vo=gpu-next", "--gpu-api=vulkan", "--gpu-context=macvk", "--target-colorspace-hint=yes",
            "--hwdec=videotoolbox", "--pause", "--keep-open=yes", "--ao=null",
            "--input-default-bindings=no", "--input-builtin-bindings=no", "--input-vo-keyboard=no",
            "--input-terminal=no", f"--input-ipc-server={path}", f"--log-file={log}",
            f"--vf={options}", str(source)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 20
        while not path.exists():
            if self.process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("Prepared player did not open IPC")
            time.sleep(.02)
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(30)
        self.socket.connect(str(path))
        self.stream = self.socket.makefile("rwb", buffering=0)

    def command(self, *values):
        self.sequence += 1
        self.stream.write((json.dumps({"command": values, "request_id": self.sequence}) + "\n").encode())
        while line := self.stream.readline():
            response = json.loads(line)
            if response.get("request_id") == self.sequence:
                if response["error"] != "success":
                    raise RuntimeError(str(response))
                return response.get("data")
        raise RuntimeError("Prepared player closed IPC")

    def wait(self, predicate):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            state = self.command("get_property", "enhancement-state")
            if state.get("prepared", {}).get("error"):
                raise RuntimeError(state["prepared"]["error"])
            if predicate(state):
                return state
            time.sleep(.05)
        raise RuntimeError(f"Prepared state timed out: {state}")

    def close(self):
        self.command("quit")
        self.socket.close()
        status = self.process.wait(timeout=30)
        self.directory.cleanup()
        if status:
            raise RuntimeError(f"Prepared player exit code {status}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=ROOT / "assets/test-clips/hdr10-30.mp4")
    parser.add_argument("--model", type=Path)
    parser.add_argument("--report", type=Path, default=ROOT / "artifacts/mpv-prepared-smoke.json")
    args = parser.parse_args()
    source = args.source.resolve()
    model = args.model.resolve() if args.model else None
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {"source": str(source), "model": str(model), "phases": [], "errors": []}
    with tempfile.TemporaryDirectory(prefix="mpv-prepared-cache-") as directory:
        cache = Path(directory) / "cache"
        configuration = Path(directory) / "configuration.json"
        request = {"sourcePath": str(source), "cacheDirectory": str(cache), "capacityBytes": 33554432,
            "rangeStart": {"value": 0, "timescale": 30}, "rangeEnd": {"value": 6, "timescale": 30},
            "segmentFrames": 3, "prerollFrames": 1}
        configuration.write_text(json.dumps(request))
        try:
            for phase in range(2):
                player = Playback(source, configuration, args.report.with_suffix(f".phase{phase}.log"), model)
                try:
                    initial = player.wait(lambda s: s.get("compare-ready") and s.get("prepared", {}).get("configurationState") == "ready")
                    player.command("vf-command", "enhance", "prepare", "start")
                    complete = player.wait(lambda s: s.get("prepared", {}).get("jobState") == "complete")
                    generation, hits = complete["generation"], complete["prepared"]["cacheHits"]
                    player.command("seek", .1, "absolute+exact")
                    hit = player.wait(lambda s: s.get("compare-ready") and s.get("generation", 0) > generation and
                                      s.get("prepared", {}).get("cacheHits", 0) > hits)
                    if hit["displayed-source-pts"] * hit["displayed-timebase-num"] / hit["displayed-timebase-den"] != .1:
                        raise RuntimeError("cached frame has wrong source timestamp")
                    expected = "prepared-enhanced" if model else "prepared-original"
                    if hit.get("displayed-content-kind") != expected:
                        raise RuntimeError("cached frame lost immutable content provenance")
                    generation, misses = hit["generation"], hit["prepared"]["cacheMisses"]
                    player.command("seek", .7, "absolute+exact")
                    miss = player.wait(lambda s: s.get("compare-ready") and s.get("generation", 0) > generation and
                                       s.get("prepared", {}).get("cacheMisses", 0) > misses)
                    if miss.get("displayed-content-kind") != "original":
                        raise RuntimeError("cache miss incorrectly labeled enhanced")
                    report["phases"].append({"initial": initial, "prepared": complete, "hit": hit, "miss": miss})
                finally:
                    player.close()
            first, second = (phase["prepared"]["prepared"] for phase in report["phases"])
            if first["processedFrames"] != 6 or second["reusedSegments"] != 2 or second["processedFrames"] != 0:
                raise RuntimeError("reopening did not reuse the published completed segments")
            report["sourceGuards"] = check_source_guards(source, Path(directory))
            report["passed"] = True
        except Exception as error:
            report["passed"] = False
            report["errors"].append(str(error))
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "errors": report["errors"],
                      "completedProcesses": len(report["phases"])}, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
