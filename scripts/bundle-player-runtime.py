#!/usr/bin/env python3
"""Stage native Mach-O dependencies with relative install names into a local app."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ("/System/", "/usr/lib/")


def output(*arguments):
    return subprocess.check_output(arguments, text=True)


def dependency_names(path):
    return [line.strip().split(" (", 1)[0] for line in output("otool", "-L", str(path)).splitlines()[1:]]


def rpaths(path):
    commands = output("otool", "-l", str(path))
    return re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset", commands)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--mpv", type=Path, default=ROOT / "artifacts/mpv-build/libmpv.2.dylib")
    parser.add_argument("--frame-engine", type=Path, default=ROOT / ".build/debug/libFrameEngineShared.dylib")
    parser.add_argument("--molten-vk", type=Path, default=Path("/opt/homebrew/opt/molten-vk/lib/libMoltenVK.dylib"))
    parser.add_argument("--model", type=Path, help="Optional neural package to include")
    args = parser.parse_args()
    contents = args.app.resolve() / "Contents"
    frameworks = contents / "Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    resources = contents / "Resources"
    search = [args.mpv.parent, args.frame_engine.parent, ROOT / "artifacts/local/lib", Path("/opt/homebrew/lib")]
    staged = {}
    names = {}
    rows = []

    def resolve(name, source):
        if name.startswith("@loader_path/"):
            return source.parent / name.removeprefix("@loader_path/")
        if name.startswith("@executable_path/"):
            return contents / "MacOS" / name.removeprefix("@executable_path/")
        if name.startswith("@rpath/"):
            suffix = name.removeprefix("@rpath/")
            candidates = [Path(value.replace("@loader_path", str(source.parent))) / suffix for value in rpaths(source)]
            candidates += [directory / suffix for directory in search]
            for candidate in candidates:
                if candidate.is_file():
                    return candidate
            raise RuntimeError(f"Cannot resolve {name} used by {source}")
        return Path(name)

    def stage(source, requested_name=None):
        original = source
        source = source.resolve(strict=True)
        if source in staged:
            return staged[source]
        name = requested_name or original.name
        if name in names and names[name] != source:
            raise RuntimeError(f"Conflicting dependency basename {name}: {source}, {names[name]}")
        names[name] = source
        destination = frameworks / name
        staged[source] = destination
        shutil.copy2(source, destination)
        destination.chmod(destination.stat().st_mode | 0o200)
        dependencies = dependency_names(source)
        identifiers = output("otool", "-D", str(source)).splitlines()[1:]
        changes = []
        for dependency in dependencies:
            if dependency in identifiers or dependency.startswith(SYSTEM):
                continue
            child = stage(resolve(dependency, source))
            changes += ["-change", dependency, "@loader_path/" + child.name]
        for path in rpaths(source):
            if not path.startswith(SYSTEM):
                changes += ["-delete_rpath", path]
        subprocess.run(["install_name_tool", "-id", "@rpath/" + name, *changes, str(destination)], check=True, capture_output=True)
        rows.append({"library": name, "source": str(source), "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest()})
        return destination

    stage(args.mpv, "libmpv.2.dylib")
    stage(args.frame_engine, "libFrameEngineShared.dylib")
    molten = stage(args.molten_vk, "libMoltenVK.dylib")
    driver = resources / "vulkan/icd.d/MoltenVK_icd.json"
    driver.parent.mkdir(parents=True, exist_ok=True)
    driver.write_text(json.dumps({"file_format_version": "1.0.0", "ICD": {
        "library_path": "../../../Frameworks/" + molten.name, "api_version": "1.2.0", "is_portability_driver": True}}, indent=2) + "\n")
    for destination in staged.values():
        for dependency in dependency_names(destination)[1:]:
            if not dependency.startswith(SYSTEM) and not dependency.startswith("@loader_path/"):
                raise RuntimeError(f"Unbundled dependency in {destination}: {dependency}")
            if dependency.startswith("@loader_path/") and not (destination.parent / dependency.removeprefix("@loader_path/")).is_file():
                raise RuntimeError(f"Missing staged dependency in {destination}: {dependency}")
        subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True, capture_output=True)
    bundled_model = None
    if args.model:
        source = args.model.resolve(strict=True)
        if not (source / "weights.safetensors").is_file():
            raise RuntimeError(f"Invalid neural model package: {source}")
        destination = resources / "Models/NeuralRendering.dlssmodel"
        shutil.copytree(source, destination, dirs_exist_ok=True)
        bundled_model = "Models/NeuralRendering.dlssmodel"
    manifest = {"architecture": output("uname", "-m").strip(), "libraries": sorted(rows, key=lambda row: row["library"]),
        "model": bundled_model, "driver": "vulkan/icd.d/MoltenVK_icd.json",
        "scope": "Locally built development bundle; not a signed/notarized distribution"}
    (resources / "NativeRuntime.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Bundled {len(staged)} native libraries; model {'included' if bundled_model else 'external'}")


if __name__ == "__main__":
    main()
