#!/usr/bin/env python3
"""Build a clean engine revision and retain sequential completed-work measurements."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def command(arguments, cwd):
    return subprocess.check_output(arguments, cwd=cwd, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--warmup", type=int, default=30)
    parser.add_argument("--width", type=int, default=32)
    parser.add_argument("--height", type=int, default=24)
    parser.add_argument("--repeat", type=int, default=2)
    parser.add_argument("--metallib", type=Path, help="Reuse an already built matching MLX runtime kernel library")
    args = parser.parse_args()
    project = args.project.resolve()
    video = args.video.resolve()
    output = args.output.resolve()
    model = args.model.resolve() if args.model else None
    if args.frames <= args.warmup or args.warmup < 0 or args.repeat < 1 or args.repeat > 10:
        parser.error("require frames > warmup >= 0 and 1…10 sequential runs")
    if args.width < 1 or args.height < 1:
        parser.error("processing dimensions must be positive")
    relevant = ["Package.swift", "Package.resolved", "packages/CFrameEngine", "packages/FrameEngine/Sources",
                "tools/FrameBenchmark", "vendor/MLX-DLSS"]
    dirty = command(["git", "status", "--porcelain", "--", *relevant], project)
    if dirty:
        raise RuntimeError("Engine sources are modified. Commit them or use --project with an isolated clean worktree.\n" + dirty)
    revision = command(["git", "rev-parse", "HEAD"], project)
    mlx_revision = command(["git", "-C", "vendor/MLX-DLSS", "rev-parse", "HEAD"], project)
    output.mkdir(parents=True, exist_ok=True)
    if any((output / f"run-{i + 1}.json").exists() for i in range(args.repeat)):
        raise RuntimeError("Output already contains measurements; use a new output directory")
    with (output / "build.log").open("w") as log:
        subprocess.run(["bash", "-c", "source scripts/env.sh\nswift build --product hdr-benchmark --jobs 2"],
                       cwd=project, stdout=log, stderr=subprocess.STDOUT, check=True)
    executable = project / ".build/debug/hdr-benchmark"
    if args.metallib:
        import shutil
        shutil.copy2(args.metallib.resolve(), executable.parent / "mlx.metallib")
    else:
        with (output / "runtime-build.log").open("w") as log:
            subprocess.run(["bash", "scripts/prepare-frame-runtime.sh"], cwd=project,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    if command(["git", "status", "--porcelain", "--", *relevant], project):
        raise RuntimeError("Engine sources changed while building")
    provenance = {"schemaVersion": 1, "rootRevision": revision, "mlxRevision": mlx_revision,
        "sourceTreeClean": True, "benchmarkSHA256": digest(executable),
        "metallibSHA256": digest(executable.parent / "mlx.metallib"), "videoSHA256": digest(video),
        "modelSHA256": digest(model / "weights.safetensors") if model else "original",
        "sourcePath": str(video), "processingWidth": args.width, "processingHeight": args.height,
        "requestedFrames": args.frames, "warmupFrames": args.warmup, "runs": [],
        "scope": "Sequential offscreen completed work; no physical presentation or audio measurements"}
    try:
        for index in range(args.repeat):
            report = output / f"run-{index + 1}.json"
            reference = output / f"reference-{index + 1}.json"
            power = command(["pmset", "-g", "batt"], project)
            values = [str(executable), "--video", str(video), "--report", str(report),
                "--reference", str(reference), "--revision", revision, "--power", power,
                "--frames", str(args.frames), "--warmup", str(args.warmup),
                "--width", str(args.width), "--height", str(args.height)]
            if model:
                values += ["--model", str(model)]
            started = time.time()
            environment = dict(os.environ)
            environment["DEVELOPER_DIR"] = environment.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
            subprocess.run(values, cwd=project, env=environment, check=True)
            data = json.loads(report.read_text())
            if data["completedTotal"] != args.frames:
                raise RuntimeError("Source ended before the requested benchmark frame count")
            if digest(executable) != provenance["benchmarkSHA256"]:
                raise RuntimeError("Benchmark binary changed during the run")
            provenance["runs"].append({"index": index + 1, "startedUnixSeconds": started,
                "report": report.name, "reference": reference.name,
                "completed": data["completedTotal"], "warmed": data["warmedSamples"],
                "completedFPS": data["completedThroughputFPS"]})
        references = [json.loads((output / row["reference"]).read_text())["samples"] for row in provenance["runs"]]
        provenance["referenceSamplesIdentical"] = all(value == references[0] for value in references)
        provenance["passed"] = True
    except Exception as error:
        provenance["passed"] = False
        provenance["error"] = str(error)
        raise
    finally:
        (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(json.dumps(provenance["runs"], indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"benchmark-engine: {error}", file=sys.stderr)
        raise SystemExit(1)
