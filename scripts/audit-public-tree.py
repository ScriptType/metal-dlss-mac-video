#!/usr/bin/env python3
"""Check the staged/tracked publication surface, not ignored local model storage."""
from pathlib import Path, PurePosixPath
import subprocess

EVIDENCE_LIMIT = 256 * 1024

files = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
bad = []
oversized = []
for name in filter(None, files):
    path = PurePosixPath(name)
    if path.suffix.lower() in {".dll", ".so", ".dylib", ".safetensors", ".metallib", ".mp4", ".mov", ".npy"}:
        bad.append(name)
    if any(part.endswith((".dlssmodel", ".srmodel", ".mlpackage")) for part in path.parts):
        bad.append(name)
    if name.startswith(("artifacts/", ".venv/", ".build/")) or path.name in {".env", "id_rsa", "id_ed25519"}:
        bad.append(name)
    if name.startswith("docs/evidence/") and Path(name).is_file() and Path(name).stat().st_size > EVIDENCE_LIMIT:
        oversized.append(name)
if bad:
    raise SystemExit("Private/generated assets tracked: " + ", ".join(sorted(set(bad))))
if oversized:
    raise SystemExit("docs/evidence files over 256 KB (keep raw run logs in artifacts/ or a release asset): "
                     + ", ".join(sorted(oversized)))
print("Publication surface: no tracked model, media, private-key or build artifacts; docs/evidence files within 256 KB")
