#!/usr/bin/env python3
"""Fetch checksummed sources, extract models locally, or verify existing models."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import struct
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def verify(entry):
    path = ROOT / entry["path"]
    if not path.is_file() or path.stat().st_size != entry["bytes"] or digest(path) != entry["sha256"]:
        raise RuntimeError(f"Missing or mismatched artifact: {entry['path']}")


def fetch(entry):
    path = ROOT / entry["path"]
    if path.exists():
        verify(entry)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(ROOT).free < entry["bytes"] + 5 * 1024**3:
        raise RuntimeError("Keep at least 5 GiB free after downloads")
    temporary = path.with_name(path.name + ".part")
    subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "30",
                    "--output", str(temporary), entry["url"]], check=True)
    if temporary.stat().st_size != entry["bytes"] or digest(temporary) != entry["sha256"]:
        raise RuntimeError(f"Download checksum mismatch: {entry['path']}")
    temporary.replace(path)


def extract_member(archive, member, destination, expected):
    output = ROOT / destination
    if output.exists():
        if digest(output) != expected:
            raise RuntimeError(f"Existing source differs: {destination}")
        return
    with zipfile.ZipFile(ROOT / archive) as source:
        data = source.read(member)
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError(f"Extracted source checksum mismatch: {member}")
    temporary = output.with_suffix(output.suffix + ".part")
    temporary.write_bytes(data)
    temporary.replace(output)


def weights(*args):
    subprocess.run([str(ROOT / ".venv/bin/mlxdlss-weights"), *args], cwd=ROOT, check=True)


def canonicalize_safetensors(path):
    """Sort header metadata; copy tensor bytes verbatim. Upstream metadata order varies."""
    temporary = path.with_suffix(path.suffix + ".canonical")
    with path.open("rb") as source, temporary.open("wb") as output:
        length = struct.unpack("<Q", source.read(8))[0]
        header = json.loads(source.read(length))
        encoded = json.dumps(header, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        encoded += b" " * (-len(encoded) % 8)
        output.write(struct.pack("<Q", len(encoded)))
        output.write(encoded)
        shutil.copyfileobj(source, output)
    temporary.replace(path)


def prepare_models():
    destination = ROOT / "models/neural-rendering"
    if not (destination / "NeuralRendering.dlssmodel").exists():
        if destination.exists():
            raise RuntimeError("Incomplete models/neural-rendering exists; preserve or remove it before retrying")
        with tempfile.TemporaryDirectory(prefix=".prepare-nr-", dir=ROOT / "models") as directory:
            stage = Path(directory)
            packed = stage / "dlssnr-weights-packed.safetensors"
            logical = stage / "dlssnr-weights-logical.safetensors"
            weights("extract", "models/sources/nvngx_dlssnr.dll", str(packed))
            canonicalize_safetensors(packed)
            weights("decode", str(packed), str(logical))
            canonicalize_safetensors(logical)
            weights("mlx", str(logical), str(stage / "NeuralRendering.dlssmodel"))
            stage.replace(destination)
    for command, source, target in [
        ("extract-fg", "models/sources/libnvidia-ngx-dlssg.so.310.7.0", "models/framegen.safetensors"),
        ("extract-vsr", "models/sources/libnvidia-ngx-vsr.so.1.8.2", "models/vsr.safetensors"),
    ]:
        output = ROOT / target
        if not output.exists():
            staging = output.with_suffix(output.suffix + ".part")
            weights(command, source, str(staging))
            canonicalize_safetensors(staging)
            staging.replace(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true", help="Verify local model hashes without network access")
    args = parser.parse_args()
    if not args.verify:
        downloads = json.loads((ROOT / "config/downloads.json").read_text())["downloads"]
        for entry in downloads:
            fetch(entry)
        extract_member("models/sources/nvngx_dlssnr_310.8.0.zip", "nvngx_dlssnr.dll",
                       "models/sources/nvngx_dlssnr.dll", "e16bcf15e16e13f527491cdf7845b2fe6521a738d8f7c9c721866a8496e1fc8e")
        extract_member("models/sources/nvidia-vfx-linux.whl", "nvvfx/libs/libnvidia-ngx-vsr.so.1.8.2",
                       "models/sources/libnvidia-ngx-vsr.so.1.8.2", "c7f2387a565e41b77a624634c102c2254d5285d28f886bd5db7491df8b1b037e")
        prepare_models()
    for model in json.loads((ROOT / "models/manifest.json").read_text())["models"]:
        for entry in model["files"]:
            verify(entry)
        print(f"{model['name']}: {'checksums OK' if model['files'] else model['status']}")


if __name__ == "__main__":
    main()
