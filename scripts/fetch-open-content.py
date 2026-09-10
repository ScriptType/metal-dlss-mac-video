#!/usr/bin/env python3
"""Fetch explicitly selected, hash-pinned public reference material.

These optional downloads are not part of bootstrap or automated checks.
Original files stay in ignored local assets; only provenance is published.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "config/open-content.json"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(asset, directory):
    destination = directory / asset["filename"]
    valid = destination.is_file() and destination.stat().st_size == asset["bytes"] and digest(destination) == asset["sha256"]
    if destination.exists() and not valid:
        raise RuntimeError("Existing source differs from the pinned asset; move it aside before downloading")
    if not valid:
        with tempfile.TemporaryDirectory(prefix=".open-content-", dir=directory) as temporary:
            downloaded = Path(temporary) / asset["filename"]
            subprocess.run(["curl", "--fail", "--location", "--show-error", "--max-time", "900",
                            "--max-filesize", str(asset["bytes"]), "--header", "If-Match: " + asset["etag"],
                            asset["url"], "-o", str(downloaded)], check=True)
            if downloaded.stat().st_size != asset["bytes"] or digest(downloaded) != asset["sha256"]:
                raise RuntimeError("Public source changed; inspect provenance before updating the pin")
            downloaded.rename(destination)
    return destination


def main():
    catalog = json.loads(CATALOG.read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("asset", choices=list(catalog["assets"]))
    parser.add_argument("--directory", type=Path, default=ROOT / "assets/test-clips/open-content")
    args = parser.parse_args()
    asset = catalog["assets"][args.asset]
    directory = args.directory.resolve() / asset.get("directory", "")
    directory.mkdir(parents=True, exist_ok=True)
    if "members" in asset:
        for member in asset["members"]:
            fetch(member, directory)
        destination = directory / "collection"
    else:
        destination = fetch(asset, directory)
    manifest = {"schemaVersion": 1, "asset": args.asset, **asset,
                "catalogSource": catalog["catalogSource"], "license": catalog["license"],
                "scope": "Unmodified public source for local validation; downloading is not a playback or quality result"}
    manifest_path = destination.with_suffix(".source.json")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(manifest_path if "members" in asset else destination)


if __name__ == "__main__":
    main()
