#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    subprocess.run(["git", *args], cwd=ROOT, check=True)


git("submodule", "update", "--init")
git("-C", "vendor/libplacebo", "submodule", "update", "--init", "--depth", "1",
    "3rdparty/fast_float", "3rdparty/Vulkan-Headers", "3rdparty/jinja", "3rdparty/markupsafe")
for source in json.loads((ROOT / "config/sources.json").read_text())["references"]:
    path = ROOT / source["path"]
    if not path.exists():
        git("clone", "--filter=blob:none", "--no-checkout", source["url"], source["path"])
        git("-C", source["path"], "checkout", "--detach", source["revision"])
    actual = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    if actual != source["revision"]:
        raise RuntimeError(f"{source['path']} is on {actual}; preserving local checkout")
    print(f"{source['path']}: {actual}")
