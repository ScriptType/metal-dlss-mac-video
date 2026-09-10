#!/usr/bin/env python3
"""Fetch the small public FFmpeg FATE P8.4 regression sample for local tests."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
URL = "https://fate-suite.ffmpeg.org/hevc/dv84.mov"
SHA256 = "aaa9289a9755eaebd9962204f24a6acf8a19ff104657a3a79b6b1fa672993721"
DESTINATION = ROOT / "assets/test-clips/dolbyvision/dv84.mov"


def main():
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    if not DESTINATION.exists() or hashlib.sha256(DESTINATION.read_bytes()).hexdigest() != SHA256:
        with tempfile.TemporaryDirectory(prefix="dovi-fixture-") as temporary:
            downloaded = Path(temporary) / "dv84.mov"
            subprocess.run(["curl", "--fail", "--location", "--max-time", "60", "--max-filesize", "8388608",
                            URL, "-o", str(downloaded)], check=True)
            payload = downloaded.read_bytes()
            if hashlib.sha256(payload).hexdigest() != SHA256:
                raise RuntimeError("FFmpeg FATE sample hash changed; inspect provenance before use")
            DESTINATION.write_bytes(payload)
    manifest = {"source": URL, "sha256": SHA256, "bytes": DESTINATION.stat().st_size,
                "purpose": "Local regression testing; binary remains untracked",
                "testReference": "https://ffmpeg.org/pipermail/ffmpeg-devel/2021-November/287700.html",
                "profile": 8, "baseLayerCompatibilityID": 4}
    DESTINATION.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(DESTINATION)


if __name__ == "__main__":
    main()
