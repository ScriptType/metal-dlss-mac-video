#!/usr/bin/env python3
"""Fetch pinned Apple HDR test renditions and copy their packets into local MP4s.

Optional local engineering media only; not part of bootstrap or CI. The combined
original corpus, including both video renditions and shared audio, is <100 MiB.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "config/apple-hdr-samples.json"


def validate_catalog(catalog):
    files = [catalog["master"]] + [file for asset in catalog["assets"].values()
                                   for file in [asset["playlist"], *asset["members"]]]
    if catalog["schemaVersion"] != 1:
        raise ValueError("Unsupported catalog version")
    for asset in catalog["assets"].values():
        if not re.fullmatch(r"[A-Za-z0-9_-]+", asset["directory"]):
            raise ValueError("Invalid asset directory")
    for file in files:
        if type(file["bytes"]) is not int or file["bytes"] <= 0 or not re.fullmatch(r"[0-9a-f]{64}", file["sha256"]):
            raise ValueError("Invalid size or hash pin")
        if not file["url"].startswith("https://devstreaming-cdn.apple.com/videos/streaming/examples/"):
            raise ValueError("Unexpected publisher URL")
    if sum(file["bytes"] for file in files) > 100 * 1024 * 1024:
        raise ValueError("Combined download exceeds 100 MiB")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(asset, directory):
    name = asset["filename"]
    if Path(name).name != name or not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
        raise ValueError("Invalid catalog filename")
    destination = directory / name
    if destination.exists():
        if destination.is_symlink() or not destination.is_file() or destination.stat().st_size != asset["bytes"] or digest(destination) != asset["sha256"]:
            raise RuntimeError(f"Existing source differs from pin: {destination}")
        return destination
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".apple-download-", dir=directory) as temporary:
        partial = Path(temporary) / name
        command = ["curl", "--fail", "--silent", "--show-error", "--max-time", "90",
                   "--max-filesize", str(asset["bytes"]), "--proto", "=https"]
        if asset.get("etag"):
            command += ["--header", "If-Match: " + asset["etag"]]
        subprocess.run(command + [asset["url"], "--output", str(partial)], check=True)
        if partial.stat().st_size != asset["bytes"] or digest(partial) != asset["sha256"]:
            raise RuntimeError("Public source changed; inspect provenance before changing the pin")
        partial.rename(destination)
    return destination


def concatenate(asset, directory):
    source = directory / (asset["directory"] + "-source.mp4")
    members = [fetch(member, directory / asset["directory"]) for member in asset["members"]]
    fetch(asset["playlist"], directory / asset["directory"])
    if source.exists():
        if source.is_symlink() or digest(source) != asset["concatenatedSHA256"]:
            raise RuntimeError(f"Existing concatenation differs from original fragments: {source}")
        return source
    with tempfile.TemporaryDirectory(prefix=".apple-concat-", dir=directory) as temporary:
        partial = Path(temporary) / source.name
        with partial.open("wb") as output:
            for member in members:
                with member.open("rb") as stream:
                    shutil.copyfileobj(stream, output)
        if digest(partial) != asset["concatenatedSHA256"]:
            raise RuntimeError("Concatenated source hash mismatch")
        partial.rename(source)
    return source


def probe(path):
    result = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format",
                             "-show_packets", "-show_data_hash", "sha256", "-of", "json", str(path)],
                            check=True, capture_output=True, text=True)
    output = json.loads(result.stdout)
    # Request only codec data here: -show_data alongside -show_packets would
    # otherwise dump the entire compressed movie a second time.
    configuration = json.loads(subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_streams", "-show_data", "-of", "json", str(path)], text=True))
    by_index = {s["index"]: s for s in configuration["streams"]}
    for stream in output["streams"]:
        stream["extradata"] = by_index[stream["index"]].get("extradata")
    return output


def codec_bytes(stream):
    text = stream.get("extradata")
    if text is None:
        return None
    data = bytearray.fromhex("".join(line.split(": ", 1)[1].split("  ", 1)[0]
                                    for line in text.splitlines() if ": " in line))
    if stream.get("codec_name") == "hevc":
        if len(data) < 23 or data[0] != 1:
            raise RuntimeError("Invalid hvcC configuration")
        position = 23
        for _ in range(data[22]):
            if position + 3 > len(data):
                raise RuntimeError("Truncated hvcC array")
            data[position] &= 0x7f  # Only array_completeness may change on remux.
            count = int.from_bytes(data[position + 1:position + 3], "big")
            position += 3
            for _ in range(count):
                if position + 2 > len(data):
                    raise RuntimeError("Truncated hvcC NAL length")
                length = int.from_bytes(data[position:position + 2], "big")
                position += 2 + length
                if position > len(data):
                    raise RuntimeError("Truncated hvcC NAL")
        if position != len(data):
            raise RuntimeError("Unexpected trailing hvcC data")
    return bytes(data)


def verify_packets(source, output, kind):
    original_stream = next(s for s in source["streams"] if s["codec_type"] == kind)
    output_stream = next(s for s in output["streams"] if s["codec_type"] == kind)
    if original_stream["time_base"] != output_stream["time_base"]:
        raise RuntimeError("Remux changed the stream time base")
    fields = ("pts", "dts", "duration", "size", "data_hash")
    original = [tuple(p.get(k) for k in fields) for p in source["packets"] if p["stream_index"] == original_stream["index"]]
    copied = [tuple(p.get(k) for k in fields) for p in output["packets"] if p["stream_index"] == output_stream["index"]]
    if not original or copied != original:
        raise RuntimeError(f"Remux changed {kind} packets or exact timestamps")
    if codec_bytes(original_stream) != codec_bytes(output_stream):
        raise RuntimeError(f"Remux changed {kind} codec data")
    # These are decoded configuration summaries; hvcC container flags may differ.
    for key in ("codec_name", "codec_tag_string", "profile", "width", "height", "pix_fmt",
                "color_range", "color_space", "color_primaries", "color_transfer",
                "chroma_location", "sample_rate", "channels", "side_data_list"):
        if original_stream.get(key) != output_stream.get(key):
            raise RuntimeError(f"Remux changed {kind} configuration field {key}")
    return {"packets": len(original), "timeBase": original_stream["time_base"],
            "preservedFields": list(fields), "sourceExtradataHash": original_stream.get("extradata_hash"),
            "remuxExtradataHash": output_stream.get("extradata_hash"),
            "codecDataIdenticalIgnoringHEVCArrayCompleteness": True}


def remux(video, audio, destination):
    originals = {"video": probe(video), "audio": probe(audio)}
    with tempfile.TemporaryDirectory(prefix=".apple-remux-", dir=destination.parent) as temporary:
        partial = Path(temporary) / destination.name
        candidate = destination if destination.exists() else partial
        command = ["ffmpeg", "-v", "error", "-nostdin", "-copyts", "-i", str(video), "-i", str(audio),
                   "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-avoid_negative_ts", "disabled",
                   "-strict", "unofficial", "-movflags", "+faststart", str(partial)]
        if candidate == partial:
            subprocess.run(command, check=True)
        elif candidate.is_symlink():
            raise RuntimeError("Existing remux is a symlink")
        output = probe(candidate)
        checks = {kind: verify_packets(source, output, kind) for kind, source in originals.items()}
        if candidate == partial:
            partial.rename(destination)
        return {"path": str(destination), "sha256": digest(destination), "bytes": destination.stat().st_size,
                "packetVerification": checks, "remuxCommand": command,
                "containerNote": "Original fragments retained; hvcC flags and container metadata can be rewritten. Separate c608 track omitted."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=["hdr10plus", "dolby-profile5", "all"])
    parser.add_argument("--directory", type=Path, default=ROOT / "assets/test-clips/apple-hdr")
    args = parser.parse_args()
    catalog = json.loads(CATALOG.read_text())
    validate_catalog(catalog)
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    fetch(catalog["master"], directory)
    audio = concatenate(catalog["assets"]["audio"], directory)
    profiles = ["hdr10plus", "dolby-profile5"] if args.profile == "all" else [args.profile]
    report = {"schemaVersion": 1, "catalogSHA256": digest(CATALOG), "scope": catalog["usage"],
              "ffmpegVersion": subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0],
              "ffprobeVersion": subprocess.check_output(["ffprobe", "-version"], text=True).splitlines()[0], "outputs": {}}
    for profile in profiles:
        video = concatenate(catalog["assets"][profile], directory)
        result = remux(video, audio, directory / f"apple-advanced-{profile}-aac.mp4")
        report["outputs"][profile] = result
        print(result["path"])
    (directory / f"{args.profile}.source.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
