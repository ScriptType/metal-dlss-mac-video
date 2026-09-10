#!/usr/bin/env python3
"""Run bounded original/neural lifecycle stress with recorded source/build identity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def command(arguments, cwd):
    return subprocess.check_output(arguments, cwd=cwd, text=True).strip()


def summarize(report, provenance):
    def median(values):
        return sorted(values)[len(values) // 2]

    modes = []
    for mode in ["original", "neural"]:
        cycles = [value for value in report["cycles"] if value["mode"] == mode]
        measured = [value["drained"] for value in cycles if value["index"] >= report["warmupCycles"]]
        if not measured:
            continue
        half = max(1, len(measured) // 2)
        early, late = measured[:half], measured[-half:]
        modes.append({
            "mode": mode, "cycles": len(cycles), "measuredCycles": len(measured),
            "completedFrames": sum(value["measurements"]["completedTotal"] for value in cycles),
            "cancelledFrames": sum(value["cancelledFrames"] for value in cycles),
            "redrawChecks": sum(value["redraws"] for value in cycles),
            "maximumSlots": max(value["measurements"]["maximumQueueSlots"] for value in cycles),
            "peakReservedFrameBytes": max(value["measurements"]["peakRetainedBytes"] for value in cycles),
            "maximumSubmissionSeconds": max(value["measurements"]["cpuSubmissionSeconds"]["maximum"] for value in cycles),
            "maximumResetGPUDrainSeconds": max(value["resetSeconds"] for value in cycles),
            "maximumCloseConsumerDrainSeconds": max(value["closeDrainSeconds"] for value in cycles),
            "sampledHeldResidentPeakBytes": max(value["held"]["residentBytes"] for value in cycles),
            "mlxReportedPeakActiveBytes": max(value["held"]["mlxPeakActiveBytes"] for value in cycles),
            "drainedResidentRangeBytes": [min(value["residentBytes"] for value in measured), max(value["residentBytes"] for value in measured)],
            "drainedActiveValuesBytes": sorted(set(value["mlxActiveBytes"] for value in measured)),
            "drainedCacheMaximumBytes": max(value["mlxCacheBytes"] for value in measured),
            "sampledDrainedResidentMedianGrowthBytes": median([value["residentBytes"] for value in late]) - median([value["residentBytes"] for value in early]),
            "sampledDrainedActiveMedianGrowthBytes": median([value["mlxActiveBytes"] for value in late]) - median([value["mlxActiveBytes"] for value in early]),
            "allDrainedModelCountsZero": all(value["drained"]["models"]["residentModels"] == 0 for value in cycles),
            "allDrainedModelPayloadBytesZero": all(value["drained"]["models"]["residentModelPayloadBytes"] == 0 for value in cycles),
        })
    first = report["cycles"][0]["measurements"] if report["cycles"] else {}
    identity_keys = ["rootRevision", "mlxRevision", "sourceTreeClean", "benchmarkSHA256", "metallibSHA256", "videoSHA256",
                     "alternateVideoSHA256", "modelSHA256", "binaryUnchanged", "sourcesUnchanged"]
    return {
        "schemaVersion": 1, "passed": report["passed"], "scope": report["scope"],
        "provenance": {key: provenance.get(key) for key in identity_keys},
        "engineSourceManifestSHA256": hashlib.sha256(json.dumps(provenance["sourceHashes"], sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        "device": first.get("device"), "osVersion": first.get("osVersion"), "physicalMemoryBytes": first.get("physicalMemoryBytes"),
        "sourceWidth": first.get("configuration", {}).get("sourceWidth"), "sourceHeight": first.get("configuration", {}).get("sourceHeight"),
        "processingWidth": report["processingWidth"], "processingHeight": report["processingHeight"],
        "warmupCyclesPerMode": report["warmupCycles"],
        "residentGrowthToleranceBytes": report["residentGrowthToleranceBytes"], "activeGrowthToleranceBytes": report["activeGrowthToleranceBytes"],
        "elapsedSeconds": provenance["finishedUnixSeconds"] - provenance["startedUnixSeconds"],
        "modes": modes, "violations": report["violations"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--alternate-video", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--width", type=int, default=160)
    parser.add_argument("--height", type=int, default=96)
    parser.add_argument("--cycles", type=int, default=12)
    parser.add_argument("--warmup-cycles", type=int, default=3)
    parser.add_argument("--rss-growth-mib", type=int, default=128)
    parser.add_argument("--active-growth-mib", type=int, default=64)
    parser.add_argument("--timeout-seconds", type=int, default=1800)
    parser.add_argument("--allow-dirty", action="store_true", help="Record a development build explicitly; no clean-revision claim")
    args = parser.parse_args()
    project, output = args.project.resolve(), args.output.resolve()
    video, alternate, model = args.video.resolve(), args.alternate_video.resolve(), args.model.resolve()
    if not (4 <= args.cycles <= 100 and args.warmup_cycles >= 1 and args.cycles - args.warmup_cycles >= 3):
        parser.error("require4…100cycles and at least3measured cycles after warmup")
    if not (1 <= args.width <= 16384 and 1 <= args.height <= 16384):
        parser.error("invalid processing geometry")
    if not (0 <= args.rss_growth_mib <= 4096 and 0 <= args.active_growth_mib <= 4096):
        parser.error("growth tolerances must be0…4096MiB")
    if not 30 <= args.timeout_seconds <= 7200:
        parser.error("timeout must be30…7200seconds")
    relevant = ["Package.swift", "Package.resolved", "packages/CFrameEngine", "packages/FrameEngine/Sources",
                "tools/FrameBenchmark", "vendor/MLX-DLSS", "scripts/stress-frame-engine.py"]
    dirty = command(["git", "status", "--porcelain", "--", *relevant], project)
    if dirty and not args.allow_dirty:
        raise RuntimeError("Commit engine sources or pass --allow-dirty for a labelled development run.\n" + dirty)
    revision = command(["git", "rev-parse", "HEAD"], project)
    mlx_revision = command(["git", "-C", "vendor/MLX-DLSS", "rev-parse", "HEAD"], project)
    output.mkdir(parents=True, exist_ok=True)
    if (output / "stress.json").exists() or (output / "provenance.json").exists():
        raise RuntimeError("Use a new output directory; existing stress evidence will not be overwritten")
    with (output / "build.log").open("w") as log:
        subprocess.run(["bash", "-c", "source scripts/env.sh\nswift build --product hdr-benchmark --jobs 2"],
                       cwd=project, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(["bash", "scripts/prepare-frame-runtime.sh"], cwd=project,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    executable = project / ".build/debug/hdr-benchmark"
    # Includes untracked implementation files; records exact content without
    # copying private local paths or entire source patches into the report.
    source_files = [project / "Package.swift", project / "Package.resolved"]
    for relative in ["packages/CFrameEngine", "packages/FrameEngine/Sources", "tools/FrameBenchmark"]:
        source_files.extend(path for path in (project / relative).rglob("*") if path.is_file())
    source_hashes = {str(path.relative_to(project)): digest(path) for path in sorted(source_files) if path.exists()}
    provenance = {
        "schemaVersion": 1, "rootRevision": revision, "mlxRevision": mlx_revision,
        "sourceTreeClean": not bool(dirty), "workingTreeStatus": dirty, "sourceHashes": source_hashes,
        "benchmarkSHA256": digest(executable), "metallibSHA256": digest(executable.parent / "mlx.metallib"),
        "videoSHA256": digest(video), "alternateVideoSHA256": digest(alternate),
        "modelSHA256": digest(model / "weights.safetensors"),
        "processingWidth": args.width, "processingHeight": args.height,
        "cyclesPerMode": args.cycles, "warmupCycles": args.warmup_cycles,
        "rssGrowthToleranceMiB": args.rss_growth_mib, "activeGrowthToleranceMiB": args.active_growth_mib,
        "powerConfiguration": command(["pmset", "-g", "batt"], project),
        "startedUnixSeconds": time.time(), "scope": "Sequential offscreen lifecycle stress; sampled plateau, not a hard transient memory bound",
    }
    arguments = [str(executable), "--stress", "--video", str(video), "--alternate-video", str(alternate),
        "--model", str(model), "--report", str(output / "stress.json"), "--revision", revision + ("+dirty" if dirty else ""),
        "--width", str(args.width), "--height", str(args.height), "--cycles", str(args.cycles),
        "--warmup-cycles", str(args.warmup_cycles), "--rss-growth-mib", str(args.rss_growth_mib),
        "--active-growth-mib", str(args.active_growth_mib)]
    try:
        with (output / "run.log").open("w") as log:
            process = subprocess.run(arguments, cwd=project, env=dict(os.environ), stdout=log,
                                     stderr=subprocess.STDOUT, timeout=args.timeout_seconds)
        provenance["exitCode"] = process.returncode
        provenance["binaryUnchanged"] = digest(executable) == provenance["benchmarkSHA256"]
        provenance["sourcesUnchanged"] = all(digest(project / path) == value for path, value in source_hashes.items())
        if process.returncode or not provenance["binaryUnchanged"] or not provenance["sourcesUnchanged"]:
            raise RuntimeError("Stress failed or implementation changed; inspect run.log and stress.json")
        report = json.loads((output / "stress.json").read_text())
        if not report["passed"] or len(report["cycles"]) != args.cycles * 2:
            raise RuntimeError("Stress did not complete all requested original/neural cycles")
        print(f"PASS {len(report['cycles'])} cycles, {args.width}x{args.height}, report={output / 'stress.json'}")
    finally:
        provenance["finishedUnixSeconds"] = time.time()
        (output / "provenance.json").write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
        if (output / "stress.json").exists():
            aggregate = summarize(json.loads((output / "stress.json").read_text()), provenance)
            (output / "summary.json").write_text(json.dumps(aggregate, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
