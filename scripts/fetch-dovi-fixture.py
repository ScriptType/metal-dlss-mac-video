#!/usr/bin/env python3
"""Fetch a pinned public FFmpeg FATE Dolby fixture; P8.4 remains the default."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
from dovi_fixtures import FATE_BY_PROFILE, source_path, verify_source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=FATE_BY_PROFILE, default="8.4")
    args = parser.parse_args()
    fixture = FATE_BY_PROFILE[args.profile]
    destination = source_path(fixture)
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        verify_source(destination, fixture)
    except (OSError, ValueError):
        with tempfile.TemporaryDirectory(prefix="dovi-fixture-") as temporary:
            downloaded = Path(temporary) / fixture["filename"]
            subprocess.run(["curl", "--fail", "--location", "--max-time", "60", "--max-filesize", "8388608",
                            fixture["url"], "-o", str(downloaded)], check=True)
            verify_source(downloaded, fixture)
            destination.write_bytes(downloaded.read_bytes())
    manifest = {"source": fixture["url"], "sha256": fixture["sha256"], "bytes": destination.stat().st_size,
                "purpose": "Local regression testing; binary remains untracked",
                "testReference": fixture["provenance"], "blankTestVideo": fixture["blankTestVideo"],
                "profile": fixture["profile"], "baseLayerCompatibilityID": fixture["compatibility"],
                "license": "No explicit per-file redistribution license found; public contributor-provided FATE regression input. No FFmpeg code license is inferred for the media.",
                "colorQualification": False}
    destination.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(destination)


if __name__ == "__main__":
    main()
