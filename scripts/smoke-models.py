#!/usr/bin/env python3
"""Bounded inference on SDR fixtures; outputs are not HDR acceptance evidence."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=["m3-dev", "m5-max"], default="m3-dev")
    args = parser.parse_args()
    profile = json.loads((ROOT / f"config/{args.profile}.json").read_text())
    output = ROOT / "artifacts" / ("model-smoke-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ"))
    output.mkdir(parents=True)
    # Input/processing/display sizes are distinct. These checks use 320x192 inputs
    # on both machines; larger M5 benchmark inputs must be prepared separately.
    commands = [
        ("neural-rendering", ["process-video", "assets/test-clips/sdr-24.mp4", "--output", str(output / "nr.mp4"),
          "--model", "models/neural-rendering/NeuralRendering.dlssmodel", "--frames", str(profile["smokeFrames"]),
          "--precision", profile["precision"], "--audio", "off"]),
        ("frame-generation", ["process-video", "assets/test-clips/sdr-24.mp4", "--output", str(output / "fg.mp4"),
          "--framegen-weights", "models/framegen.safetensors", "--factor", "2", "--frames", "3", "--audio", "off"]),
        ("rtx-vsr", ["process-image", "assets/test-clips/smoke.png", "--output", str(output / "vsr.png"),
          "--vsr-weights", "models/vsr.safetensors"]),
    ]
    for name, arguments in commands:
        with (output / f"{name}.json").open("w") as report, (output / f"{name}.log").open("w") as log:
            subprocess.run([str(ROOT / "vendor/MLX-DLSS/.build/release/mlxdlss"), *arguments],
                           cwd=ROOT, stdout=report, stderr=log, check=True, timeout=300)
        result = json.loads((output / f"{name}.json").read_text())
        expected_frames = profile["smokeFrames"] if name == "neural-rendering" else 5 if name == "frame-generation" else 1
        if result["outputFrames"] != expected_frames:
            raise RuntimeError(f"{name}: unexpected output frame count: {result}")
        if name == "rtx-vsr":
            with Image.open(ROOT / "assets/test-clips/smoke.png") as source, Image.open(output / "vsr.png") as image:
                if image.size != (source.width * 2, source.height * 2):
                    raise RuntimeError(f"VSR output dimensions are {image.size}")
        print(f"{name}: completed")
    (output / "profile.json").write_text(json.dumps(profile, indent=2) + "\n")
    print(f"Reports: {output}")


if __name__ == "__main__":
    main()
