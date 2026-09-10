#!/usr/bin/env python3
"""Capture one selected linear HDR frame under existing mpv target options.

Only this diagnostic host's verified window is captured. No PiP or display
settings changes. Frozen app/core/engine identities are checked across the run.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--metadata-control", action="store_true", help="Hold target-peak1000; clear and restore only actual CAMetalLayer EDRMetadata")
    parser.add_argument("--scale-control", action="store_true", help="Hold target-peak1000; assign fresh public metadata with opticalOutputScale1,203,1 and request redraw")
    args = parser.parse_args()
    if args.metadata_control and args.scale_control:
        parser.error("Select only one control")
    output = args.output.resolve()
    if output.exists():
        raise RuntimeError("Use a new output directory")
    wrapper = output.with_name(output.name + "-wrapper.json")
    if wrapper.exists():
        raise RuntimeError("Wrapper report already exists")
    source = ROOT / "assets/test-clips/playback/pq-30-60s.mkv"
    model = ROOT / "models/neural-rendering/NeuralRendering.dlssmodel"
    host = ROOT / "artifacts/hdr-native-color-probe/HDRNativeColorProbe"
    capture = ROOT / "artifacts/hdr-capture-probe/hdr-capture-probe"
    paths = [host, capture, ROOT / ".build/debug/HDRPlayer", ROOT / "artifacts/mpv-build/mpv",
             ROOT / "artifacts/mpv-build/libmpv.2.dylib", ROOT / ".build/debug/libFrameEngineShared.dylib",
             ROOT / "artifacts/local/lib/libplacebo.dylib", Path("/opt/homebrew/Cellar/molten-vk/1.4.2/lib/libMoltenVK.dylib")]
    paths = [path.resolve() for path in paths]
    report = {"passed": False, "sourceSHA256": sha(source), "weightsSHA256": sha(model / "weights.safetensors"),
              "binaries": {str(path): {"beforeSHA256": sha(path)} for path in paths}, "captures": []}
    process = None
    names = ("scale1", "scale203", "scale1-repeat") if args.scale_control else ("metadata-original", "metadata-cleared", "metadata-restored") if args.metadata_control else ("auto", "peak1000", "auto-repeat")
    try:
        preflight = subprocess.run([str(capture), "--preflight"], capture_output=True, text=True, timeout=10)
        report["screenCapturePreflight"] = json.loads(preflight.stdout)
        if preflight.returncode:
            raise RuntimeError("Screen capture preflight failed; no permission requested")
        with output.with_name(output.name + "-host.log").open("x") as log:
            mode = ["--scale-control"] if args.scale_control else ["--metadata-control"] if args.metadata_control else []
            process = subprocess.Popen([str(host), str(source), str(model), str(output)] + mode, stdout=log, stderr=subprocess.STDOUT)
            report["pid"] = process.pid
            for name in names:
                directory = output / name
                ready = directory / "ready.json"
                deadline = time.monotonic() + 55
                while not ready.exists():
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError(f"Host did not reach {name}")
                    time.sleep(.02)
                phase = json.loads(ready.read_text())
                surface = phase["surface"]
                if surface["pid"] != process.pid or not surface["visible"] or not surface["occlusionVisible"] or surface["miniaturized"]:
                    raise RuntimeError(f"Host is not actually visible: {surface}")
                command = [str(capture), "--owner-pid", str(process.pid), "--owner-bundle", "unbundled",
                    "--window-id", str(surface["windowID"]), "--output", str(directory / "sck-hdr"),
                    "--frame-reference", str(ready)]
                result = subprocess.run(command, capture_output=True, text=True, timeout=22)
                (directory / "capture.stdout").write_text(result.stdout)
                (directory / "capture.stderr").write_text(result.stderr)
                report["captures"].append({"phase": name, "command": command, "exitCode": result.returncode})
                if result.returncode:
                    raise RuntimeError(f"Target capture failed: {result.stderr}")
                (directory / "capture-complete").touch()
            report["hostExitCode"] = process.wait(timeout=25)
            session = json.loads((output / "session.json").read_text())
            report["hostPassed"] = session["passed"]
            if report["hostExitCode"] or not session["passed"]:
                raise RuntimeError(f"Host failed: {session.get('error')}")
            report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
    finally:
        if process is not None and process.poll() is None:
            # Let the bounded host close its leases/core on a failed capture.
            for name in names:
                directory = output / name
                if directory.exists():
                    (directory / "capture-complete").touch()
            try:
                report["hostExitCode"] = process.wait(timeout=35)
            except subprocess.TimeoutExpired:
                process.terminate()
                report["hostExitCode"] = process.wait(timeout=10)
                report["forcedTermination"] = True
        for path in paths:
            report["binaries"][str(path)]["afterSHA256"] = sha(path)
        report["binariesUnchanged"] = all(x["beforeSHA256"] == x["afterSHA256"] for x in report["binaries"].values())
        report["passed"] &= report["binariesUnchanged"]
        wrapper.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report.get(key) for key in ("passed", "error", "binariesUnchanged", "hostExitCode")}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
