#!/usr/bin/env python3
"""Seed six seconds of real Prepared output, then exercise the app's PiP consumer.

GPU/window integration: run in a coordinated test slot with stable binaries.
The seed core closes before the app opens the same cache. Neither phase creates
an independent PiP decoder or audio renderer. No system PiP button is simulated.
"""
from __future__ import annotations

import argparse
from bisect import bisect_left
from datetime import datetime, timezone
from fractions import Fraction
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepared_playback_checks", ROOT / "scripts/test-mpv-prepared-playback.py")
prepared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepared)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "assets/test-clips/playback/pq-30-60s.mkv")
    parser.add_argument("--model", type=Path, default=ROOT / "models/neural-rendering/NeuralRendering.dlssmodel")
    parser.add_argument("--cache-directory", type=Path, help="Reuse this retained diagnostic cache; its source/model/settings are verified")
    parser.add_argument("--reuse-seed", action="store_true", help="Validate existing seed and skip the preparation core/job entirely")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve(); args.source = args.source.resolve(); args.model = args.model.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    report_path = args.output / "report.json"
    prepared.require(not report_path.exists(), "use a new output directory; prior evidence will not be overwritten")
    args.report = args.output / "seed.json"; args.width = 160; args.height = 96
    capacity = 1_073_741_824
    cache = args.cache_directory.resolve() if args.cache_directory else args.output / "cache"
    prepared.require(not args.reuse_seed or args.cache_directory is not None, "--reuse-seed requires --cache-directory")
    binaries = {name: path.resolve() for name, path in {
        "HDRPlayer": ROOT / ".build/debug/HDRPlayer", "mpv": ROOT / "artifacts/mpv-build/mpv",
        "libmpv": ROOT / "artifacts/mpv-build/libmpv.2.dylib",
        "FrameEngineShared": ROOT / ".build/debug/libFrameEngineShared.dylib",
        "mlx.metallib": ROOT / ".build/debug/mlx.metallib"}.items()}
    report = {"passed": False, "recordedUTC": datetime.now(timezone.utc).isoformat(),
        "scope": "Actual Prepared PiP cache transitions and source identity; no physical presentation or acoustic A/V qualification",
        "binaries": {name: {"path": str(path), "beforeSHA256": prepared.digest(path)} for name, path in binaries.items()},
        "sourceSHA256": prepared.digest(args.source), "modelSHA256": prepared.digest(args.model / "weights.safetensors"),
        "configuration": {"source": str(args.source), "cacheDirectory": str(cache), "capacityBytes": capacity,
            "processingWidth": args.width, "processingHeight": args.height, "strength": 1, "colourStrength": 1,
            "referenceWhiteNits": 203, "maximumLuminanceRatio": 2, "segmentFrames": 60, "prerollFrames": 8,
            "prepareSeconds": 6, "cachedSeekSeconds": 1, "uncachedSeekSeconds": 8}}
    player = None
    try:
        inventory, inventory_provenance = prepared.helpers.source_inventory(args.source, report["sourceSHA256"])
        end_index = bisect_left(inventory, Fraction(6))
        expected = inventory[:end_index]
        prepared.require(end_index == 180 and all(Fraction(value) in inventory for value in (1, 2, 6, 8)),
                         "scenario requires the sustained 30-fps source with exact one/two/six/eight-second frames")
        stream = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,avg_frame_rate", "-of", "json", str(args.source)]))["streams"][0]
        prepared.require((stream["width"], stream["height"]) == (320, 192), "scenario expects the 320x192 sustained fixture")
        provenance = {"sourceSHA256": report["sourceSHA256"], "modelSHA256": report["modelSHA256"],
            "revisions": {"root": prepared.helpers.revision(ROOT), "mpv": prepared.helpers.revision(ROOT / "vendor/mpv"),
                          "MLX-DLSS": prepared.helpers.revision(ROOT / "vendor/MLX-DLSS")}}
        report["provenance"] = provenance; report["inventory"] = inventory_provenance
        configuration = args.output / "prepared.json"
        configuration.write_text(json.dumps({"sourcePath": str(args.source), "cacheDirectory": str(cache), "capacityBytes": capacity,
            "rangeStart": prepared.rational(inventory[0]), "rangeEnd": prepared.rational(inventory[end_index]),
            "segmentFrames": 60, "prerollFrames": 8}))
        if args.reuse_seed:
            report["seed"] = {"reusedExistingSeed": True, "preparationCoreStarted": False, "processedFrames": 0}
        else:
            player = prepared.Player(args, args.source, configuration, "prepare", provenance, stream)
            player.wait(lambda value: value.get("prepared", {}).get("configurationState") == "ready")
            began = time.monotonic()
            player.command("vf-command", "enhance", "prepare", "start")
            result = player.wait(lambda value: value.get("prepared", {}).get("jobState") == "complete", timeout=180)
            report["seed"] = {"wallSeconds": time.monotonic() - began, "state": result, "preparationCoreStarted": True}
            player.close(); player = None
            report["seed"]["coreClosedBeforeAppLaunch"] = True
        before = prepared.cache_snapshot(cache, expected, report["modelSHA256"], capacity, verify_pixels=True)
        prepared.require(len(before["segments"]) == 3, "seed must commit exactly three sixty-frame segments")
        current_version = subprocess.check_output([str(binaries["mpv"]), "--version"], text=True).splitlines()[0].split(" Copyright")[0]
        report["currentProviderMPVVersion"] = current_version
        for path in (cache / "segments").glob("*/manifest.json"):
            identity = json.loads(path.read_text())["identity"]
            source, settings = identity["source"], identity["settings"]
            prepared.require(source["contentSHA256"] == report["sourceSHA256"] and source["byteCount"] == args.source.stat().st_size and
                source["streamIndex"] == 0, "retained cache source identity differs")
            prepared.require(f";{current_version};" in source["interpretation"]["decoder"],
                "retained cache provider version differs from the current core; refresh the diagnostic seed explicitly")
            prepared.require(settings["processingWidth"] == args.width and settings["processingHeight"] == args.height and
                settings["outputWidth"] == 320 and settings["outputHeight"] == 192 and
                settings["effects"] == {"strength": 1, "colourStrength": 1, "maximumLuminanceRatio": 2} and
                float(settings["colourPolicy"]["referenceWhiteNits"]) == 203,
                "retained cache processing or colour settings differ")
        # The app's existing cache-open and exact-hit checks independently
        # validate the current provider/implementation/preroll interpretation.
        report["cacheBeforeApp"] = before
        env = dict(os.environ, HDRPLAYER_CACHE_DIRECTORY=str(cache), MLXDLSS_NEURAL_RENDERING_PACKAGE=str(args.model))
        with (args.output / "app-wrapper.log").open("w") as log:
            result = subprocess.run([sys.executable, str(ROOT / "scripts/test-player-lifecycle-playback.py"),
                "--scenario", "pip-prepared", "--source", str(args.source), "--output", str(args.output / "app")],
                cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=150)
        app = json.loads((args.output / "app/report.json").read_text())
        report["app"] = app
        prepared.require(result.returncode == 0 and app["passed"], app.get("failure", "Prepared PiP app scenario failed"))
        after = prepared.cache_snapshot(cache, expected, report["modelSHA256"], capacity, verify_pixels=True)
        report["cacheAfterApp"] = after
        identities = lambda snapshot: [(segment["key"], segment["payloadInventorySHA256"]) for segment in snapshot["segments"]]
        prepared.require(identities(before) == identities(after), "PiP playback changed prepared pixel payloads")
        clock = app["pipState"]["clock"]
        prepared.require(clock["rate"] == 0 and clock["holdUpdates"] > 0 and clock["updates"] > clock["holdUpdates"],
                         "consumer did not observe progressing and held native clocks")
        for key in ("maximumAnchorCorrectionSeconds", "maximumSnapshotAgeSeconds", "maximumSteadyCorrectionSeconds"):
            prepared.require(math.isfinite(clock[key]) and clock[key] >= 0, f"invalid diagnostic clock metric: {key}")
        report["passed"] = True
    except Exception as error:
        report["failure"] = str(error)
    finally:
        if player is not None:
            try:
                player.close()
            except Exception as error:
                report["passed"] = False; report["teardownFailure"] = str(error)
        for name, path in binaries.items():
            report["binaries"][name]["afterSHA256"] = prepared.digest(path)
        report["binariesUnchanged"] = all(value["beforeSHA256"] == value["afterSHA256"] for value in report["binaries"].values())
        if not report["binariesUnchanged"]:
            report["passed"] = False; report["failure"] = "A measured binary changed during the Prepared PiP test"
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report.get(key) for key in ("passed", "failure", "binariesUnchanged")}, indent=2))
    print(report_path)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
