#!/usr/bin/env python3
"""Check native subtitle pixel changes on one retained neural frame.

PNG captures exercise gpu-next composition, not physical HDR calibration.
Run with `uv run --frozen scripts/test-mpv-subtitle-brightness.py`.
"""
import argparse
from bisect import bisect_left
from fractions import Fraction
import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("policy_helpers", ROOT / "scripts/test-mpv-policy.py")
HELPERS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPERS)


def require(value, message):
    if not value:
        raise RuntimeError(message)


def pixels(path):
    info = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(path)]))["streams"][0]
    require(info["pix_fmt"] in ("rgb48be", "rgb48le", "rgba64be", "rgba64le"), "capture is not high-bit-depth RGB")
    raw = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(path), "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb48le", "pipe:1"])
    return np.frombuffer(raw, dtype="<u2").reshape(info["height"], info["width"], 3).astype(np.int32), info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "assets/test-clips/player-controls.mkv")
    parser.add_argument("--model", type=Path, default=ROOT / "models/neural-rendering/NeuralRendering.dlssmodel")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/subtitle-brightness")
    parser.add_argument("--strength-sweep", action="store_true", help="Also compare opaque subtitle pixels at neural strengths 1, 0.5 and 0.25")
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    binaries = [ROOT / "artifacts/mpv-build/mpv", ROOT / "artifacts/mpv-build/libmpv.2.dylib", ROOT / ".build/debug/libFrameEngineShared.dylib"]
    hashes = {str(path.relative_to(ROOT)): HELPERS.digest(path) for path in binaries}
    source_hash = HELPERS.digest(args.source)
    inventory, _ = HELPERS.source_inventory(args.source, source_hash)
    expected_pts = inventory[bisect_left(inventory, Fraction(745, 1000))]
    report = {"passed": False, "errors": [], "scope": "Native gpu-next high-bit-depth PNG composition on a retained neural frame; no physical HDR luminance/colour claim",
              "sourceSHA256": source_hash, "weightsSHA256": HELPERS.digest(args.model / "weights.safetensors"),
              "rootRevision": HELPERS.revision(ROOT), "mpvRevision": HELPERS.revision(ROOT / "vendor/mpv"),
              "binaries": hashes, "captures": {}, "conditions": "960x496 requested drawable; paused; dithering and dynamic peak detection disabled for deterministic pixel comparison; muted CoreAudio"}
    with tempfile.TemporaryDirectory(prefix="hdr-subtitle-") as temporary:
        ipc = Path(temporary) / "ipc"
        model = str(args.model.resolve())
        filter_ = f"@enhance:metal-hdr=policy=adaptive:processing-width=32:processing-height=24:strength=1:model=%{len(model.encode())}%{model}"
        process = subprocess.Popen([str(binaries[0]), "--no-config", "--vo=gpu-next", "--gpu-api=vulkan", "--gpu-context=macvk",
            "--target-colorspace-hint=yes", "--hwdec=videotoolbox", "--ao=coreaudio", "--mute=yes", "--pause=yes",
            "--keep-open=yes", "--osc=no", "--osd-level=0", "--geometry=960x496", "--keepaspect-window=no",
            "--input-default-bindings=no", "--input-builtin-bindings=no", "--input-vo-keyboard=no", "--input-terminal=no",
            "--dither-depth=no", "--hdr-compute-peak=no", "--screenshot-format=png", "--screenshot-high-bit-depth=yes",
            "--screenshot-tag-colorspace=yes", "--screenshot-png-compression=1", "--sid=1", "--sub-font-size=36",
            f"--input-ipc-server={ipc}", f"--vf={filter_}", f"--log-file={output / 'mpv.log'}", str(args.source.resolve())],
            cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        client = socket.socket(socket.AF_UNIX)
        try:
            deadline = time.monotonic() + 30
            while not ipc.exists():
                require(process.poll() is None and time.monotonic() < deadline, "mpv IPC did not become ready")
                time.sleep(.02)
            client.connect(str(ipc)); client.settimeout(30)
            stream = client.makefile("rwb", buffering=0)
            sequence = 0

            def command(*values):
                nonlocal sequence
                sequence += 1
                stream.write((json.dumps({"command": values, "request_id": sequence}) + "\n").encode())
                while True:
                    row = stream.readline(); require(row, "mpv closed IPC")
                    event = json.loads(row)
                    if event.get("request_id") == sequence:
                        require(event.get("error") == "success", f"Command failed: {values}: {event}")
                        return event.get("data")

            def state():
                return command("get_property", "enhancement-state")

            def ready(previous_generation=None):
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    current = state()
                    correct_seek = previous_generation is None or (current.get("generation", 0) > previous_generation and HELPERS.displayed_time(current) == expected_pts)
                    if correct_seek and current.get("compare-ready") and not current.get("preview-pending") and current.get("pending-frames") == 0:
                        return current
                    time.sleep(.02)
                raise RuntimeError("Retained neural frame did not become ready")

            initial = ready()
            command("seek", .75, "absolute+exact")
            current = ready(initial["generation"])
            require(current.get("displayed-content-kind") == "enhanced", "selected frame is not neural output")
            report["initial"] = current
            report["subText"] = command("get_property", "sub-text")
            require(report["subText"], "fixture subtitle is unavailable at the selected PTS")
            identity = {key: current.get(key) for key in ("displayed-source-pts", "displayed-timebase-num", "displayed-timebase-den", "displayed-generation", "generation", "submitted-frames")}
            arrays = {}
            # mpv accepts #[AA]RRGGBB, unlike CSS's #RRGGBBAA. Six digits
            # retain opaque alpha while changing the three equal RGB channels.
            for name, colour in (("hidden", None), ("full", "#FFFFFF"), ("half", "#808080"), ("quarter", "#404040"), ("full-repeat", "#FFFFFF"), ("hidden-repeat", None)):
                command("set_property", "sub-visibility", colour is not None)
                if colour:
                    command("set_property", "sub-color", colour)
                time.sleep(.15)
                path = output / f"{name}.png"
                command("screenshot-to-file", str(path), "window")
                image, info = pixels(path); arrays[name] = image
                observed = state()
                require({key: observed.get(key) for key in identity} == identity, "subtitle change changed retained identity or submitted inference")
                report["captures"][name] = {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "requestedColor": colour, "nativeColor": command("get_property", "sub-color"),
                    "width": info["width"], "height": info["height"], "pixelFormat": info["pix_fmt"],
                    "colourTransfer": info.get("color_transfer"), "colourPrimaries": info.get("color_primaries")}
            require(all(image.shape == arrays["hidden"].shape for image in arrays.values()), "capture geometry changed")
            base = arrays["hidden"]; full = arrays["full"]; half = arrays["half"]; quarter = arrays["quarter"]
            height, width, _ = full.shape
            changed = np.any(full != base, axis=2)
            ys, xs = np.nonzero(changed)
            require(len(ys) > 50, "native subtitle did not change captured pixels")
            require(int(ys.min()) >= int(height * .7), "subtitle change affected pixels outside the lower subtitle region")
            require(float(changed.mean()) < .15, "subtitle change affected an unexpectedly large image region")
            require(np.array_equal(full, arrays["full-repeat"]), "repeated subtitle colour changed captured pixels")
            require(np.array_equal(base, arrays["hidden-repeat"]), "video pixels changed after subtitle toggles")
            require(np.all(full >= half) and np.all(half >= quarter), "subtitle greys did not reduce pixel brightness monotonically")
            fill = np.any(full > half, axis=2)
            require(int(fill.sum()) > 50 and np.any(half > quarter), "brightness controls did not alter native subtitle pixels")
            for name in ("full", "half", "quarter"):
                require(np.array_equal(arrays[name][:int(height * .7)], base[:int(height * .7)]), "video region changed with subtitle brightness")
            report["pixelChecks"] = {"changedPixels": int(changed.sum()), "changedFraction": float(changed.mean()),
                "boundingBox": [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1],
                "meanEncodedRGBOnFill": {name: float(arrays[name][fill].mean()) for name in ("full", "half", "quarter")},
                "unchangedUpperVideoRegion": True, "sameFrameAndSubmissionCount": True,
                "repeatCapturesIdentical": True, "monotonicEncodedSubtitleBrightness": True}
            if args.strength_sweep:
                sweep = []
                report["strengthSweep"] = sweep
                reference = None
                for strength in (1, .5, .25):
                    if strength != 1:
                        command("vf", "set", filter_.replace(":strength=1:", f":strength={strength}:"))
                        command("seek", .75, "absolute+exact")
                    deadline = time.monotonic() + 30
                    while time.monotonic() < deadline:
                        selected = state()
                        if selected.get("strength") == strength and HELPERS.displayed_time(selected) == expected_pts and selected.get("compare-ready") and selected.get("pending-frames") == 0 and not selected.get("preview-pending"):
                            break
                        time.sleep(.02)
                    else:
                        raise RuntimeError(f"Strength {strength} did not establish the exact retained frame")
                    frame_identity = {key: selected.get(key) for key in identity}
                    captures = {}
                    record = {"strength": strength, "identity": frame_identity, "captures": {}}
                    for name, colour in (("hidden", None), ("white", "#FFFFFF"), ("black", "#000000"), ("half", "#808080")):
                        command("set_property", "sub-visibility", colour is not None)
                        if colour:
                            command("set_property", "sub-color", colour)
                        time.sleep(.15)
                        path = output / f"strength-{strength}-{name}.png"
                        command("screenshot-to-file", str(path), "window")
                        captures[name], _ = pixels(path)
                        observed = state()
                        require({key: observed.get(key) for key in frame_identity} == frame_identity, "strength capture changed retained frame or resubmitted inference")
                        record["captures"][name] = {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                    if reference is None:
                        reference = captures
                        # Native colour conversion leaves encoded black at 2/65535.
                        # Allow that quantization floor while requiring full white
                        # coverage; compare the unsaturated gray pixels below.
                        opaque = changed & np.all(captures["white"] == 65535, axis=2) & np.all(captures["black"] <= 2, axis=2)
                        require(int(opaque.sum()) > 100, "insufficient fully opaque subtitle pixels for strength comparison")
                    difference = np.abs(captures["half"][opaque] - reference["half"][opaque])
                    record["opaqueSubtitlePixels"] = int(opaque.sum())
                    record["blackCoverageToleranceEncoded"] = 2
                    record["maximumSubtitleEncodedDifference"] = int(difference.max())
                    record["changedVideoPixels"] = int(np.any(captures["hidden"] != reference["hidden"], axis=2).sum())
                    require(record["maximumSubtitleEncodedDifference"] <= 1, "neural strength changed opaque subtitle brightness")
                    if strength != 1:
                        require(record["changedVideoPixels"] > 100, "strength sweep did not change neural video pixels")
                    sweep.append(record)
            report["final"] = state(); report["passed"] = True
            command("quit")
        except Exception as error:
            report["errors"].append(str(error)); process.terminate()
        finally:
            client.close()
            try:
                report["exitCode"] = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill(); report["exitCode"] = process.wait(); report["errors"].append("shutdown timed out")
            report["binariesUnchanged"] = all(HELPERS.digest(ROOT / path) == value for path, value in hashes.items())
            report["sourceUnchanged"] = HELPERS.digest(args.source) == source_hash
            report["passed"] = report["passed"] and report["exitCode"] == 0 and report["binariesUnchanged"] and report["sourceUnchanged"]
            (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report.get(key) for key in ("passed", "errors", "pixelChecks", "exitCode", "binariesUnchanged")}, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
