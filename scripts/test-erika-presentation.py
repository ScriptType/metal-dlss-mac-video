#!/usr/bin/env python3
"""Capture actual Erika window state and Metal presentation callbacks without rebuilding."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from adapter_visibility import completed_window, qualify_visibility, window_events

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "assets/test-clips/playback/pq-30-60s.mkv")
    parser.add_argument("--model", type=Path)
    parser.add_argument("--strength", type=float, default=0)
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 8 <= args.seconds <= 60 or not 0 <= args.strength <= 1 or (args.strength > 0 and not args.model):
        parser.error("require 8…60 seconds and strength0…1 with a model for nonzero strength")
    output = args.output.resolve()
    if output.exists():
        parser.error("use a new output directory to preserve prior captures")
    output.mkdir(parents=True)
    binaries = [ROOT / "artifacts/erika-target/debug/macos_native_demo", ROOT / ".build/debug/libFrameEngineShared.dylib",
                ROOT / "artifacts/erika-target/debug/mlx.metallib"]
    hashes = {str(p.relative_to(ROOT)): digest(p) for p in binaries}
    source = args.source.resolve()
    report = {"schemaVersion": 1, "sourceSHA256": digest(source), "binarySHA256": hashes,
        "strength": args.strength, "processingDimensions": [160, 96], "drawableDimensions": [960, 496],
        "erikaRevision": subprocess.check_output(["git", "-C", str(ROOT / "vendor/Erika"), "rev-parse", "HEAD"], text=True).strip(),
        "erikaDiffSHA256": hashlib.sha256(subprocess.check_output(["git", "-C", str(ROOT / "vendor/Erika"), "diff", "HEAD", "--binary"])).hexdigest(),
        "sourceFilesSHA256": {path: digest(ROOT / path) for path in [
            "vendor/Erika/crates/erika/src/shared_hdr.rs", "vendor/Erika/crates/erika/src/shared_hdr_diagnostics.rs",
            "vendor/Erika/crates/erika/src/renderer/metal/apple.rs", "vendor/Erika/examples/macos_native_demo/native/ErikaMetalDemo.m",
            "scripts/test-erika-presentation.py", "scripts/adapter_visibility.py"]},
        "scope": "Public NSWindow visibility plus Metal presentedTime/GPU callbacks; no physical scanout measurement",
        "runs": {}, "errors": []}
    if args.model:
        report["weightsSHA256"] = digest(args.model.resolve() / "weights.safetensors")
    try:
        for name in ["visible", "occluded-midrun"]:
            engine = output / f"{name}.json"
            environment = dict(os.environ)
            for key in ["ERIKA_ADAPTER_SEEK_AT", "ERIKA_ADAPTER_SEEK_TO", "ERIKA_ADAPTER_OCCLUDE_AT", "ERIKA_ADAPTER_REVEAL_AT"]:
                environment.pop(key, None)
            environment.update(ERIKA_FRAME_ENGINE_REPORT=str(engine), ERIKA_FRAME_ENGINE_CAPTURE="none",
                ERIKA_FRAME_ENGINE_WIDTH="160", ERIKA_FRAME_ENGINE_HEIGHT="96", ERIKA_FRAME_ENGINE_STRENGTH=str(args.strength),
                ERIKA_ADAPTER_FOREGROUND="1", ERIKA_ADAPTER_MUTE="1", ERIKA_ADAPTER_DIAGNOSTICS="1",
                ERIKA_ADAPTER_REQUIRE_VISIBLE="0",
                ERIKA_ADAPTER_DISPLAY_WIDTH="960", ERIKA_ADAPTER_DISPLAY_HEIGHT="496", ERIKA_ADAPTER_SECONDS=str(args.seconds))
            if name == "occluded-midrun":
                environment.update(ERIKA_ADAPTER_OCCLUDE_AT="3", ERIKA_ADAPTER_REVEAL_AT="6")
            log_path = output / f"{name}.log"
            with log_path.open("w") as log:
                subprocess.run(["bash", "scripts/run-erika-adapter.sh", str(source), str(args.model.resolve()) if args.model else ""],
                    cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=args.seconds + 45)
            measurements = json.loads(engine.read_text())
            adapter = json.loads(Path(str(engine) + ".adapter.json").read_text())
            windows = []
            for line in log_path.read_text().splitlines():
                if line.startswith("{"):
                    event = json.loads(line)
                    if event.get("event") == "erika_native_window":
                        windows.append(event)
            diagnostics = adapter.get("presentationDiagnostics")
            if not windows or not diagnostics:
                raise RuntimeError("diagnostic-enabled native binary required")
            counts = diagnostics["totals"]
            report["runs"][name] = {"completedFrames": measurements["completedTotal"], "diagnostics": diagnostics,
                "visibility": qualify_visibility(window_events(log_path.read_text(), "erika"), *completed_window(measurements)),
                "nativeWindowEvents": windows,
                "positiveCallbackFraction": counts["presented"] / max(1, counts["presented"] + counts["unpresented"]),
                "nativeVisibleObserved": any(e["state"]["visible"] and e["state"]["occlusionVisible"] for e in windows),
                "nativeHiddenObserved": any(not e["state"]["visible"] for e in windows),
                "controlledOcclusionObserved": any(3.1 <= e["elapsed"] < 6 and not e["state"]["occlusionVisible"] for e in windows),
                "visibleAfterRevealObserved": any(e["elapsed"] >= 6.2 and e["state"]["occlusionVisible"] for e in windows),
                "activeObserved": any(e["state"]["active"] for e in windows),
                "gpuFailures": counts["gpu_failed"]}
            if measurements["completedTotal"] < 30 or counts["gpu_failed"]:
                raise RuntimeError("insufficient completed frames or GPU command failure")
            if max(event["elapsed"] for event in windows) < args.seconds - 1.5:
                raise RuntimeError("window diagnostics ended before the intended playback interval")
            if name == "occluded-midrun" and not (report["runs"][name]["controlledOcclusionObserved"] and report["runs"][name]["visibleAfterRevealObserved"]):
                raise RuntimeError("controlled occlusion/reveal was not observed")
    except Exception as error:
        report["errors"].append(str(error))
    finally:
        report["binaryHashesUnchanged"] = all(digest(ROOT / path) == value for path, value in hashes.items())
        report["sourceHashUnchanged"] = digest(source) == report["sourceSHA256"]
        if not report["binaryHashesUnchanged"] or not report["sourceHashUnchanged"]:
            report["errors"].append("measured binary/source changed")
        report["capturePassed"] = not report["errors"] and len(report["runs"]) == 2
        (output / "presentation.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"capturePassed": report["capturePassed"], "errors": report["errors"], "runs": {
        name: {k: v for k, v in run.items() if k not in ["diagnostics", "nativeWindowEvents"]}
        for name, run in report["runs"].items()}}, indent=2))
    return 0 if report["capturePassed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
