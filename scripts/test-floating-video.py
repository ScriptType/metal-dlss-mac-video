#!/usr/bin/env python3
"""Drive View > Float Video in the real player and check the #17 contract.

Scenarios:
  floating-video             float and return without a restart, close orders, quit while floating
  floating-video-close-main  close the panel, then the main window; the app must quit
  floating-space             a helper app takes a fullscreen Space; the panel must stay on screen,
                             and closing it there must leave the main window in view or pause
  floating-space-hidden-main the same after closing the main window while floating

Uses the GPU and the screen. floating-space takes over the screen for a few
seconds. Run only while no other GPU tests run.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tools/FloatingSpaceReference"
SCENARIOS = ("floating-video", "floating-video-close-main", "floating-space", "floating-space-hidden-main")
FLOATING = "floating(mainHidden: false)"


def lifecycle(path: Path) -> list[dict]:
    rows = []
    for line in path.read_text().splitlines() if path.exists() else []:
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass  # The recorder may still be writing the last line.
    return rows


def placements(rows: list[dict]) -> list[str]:
    return [row["details"]["placement"] for row in rows if row["event"] == "video-placement"]


def build_helper(output: Path) -> Path:
    app = output / "FloatingSpaceReference.app"
    shutil.rmtree(app, ignore_errors=True)
    (app / "Contents/MacOS").mkdir(parents=True)
    shutil.copy(HELPER / "Info.plist", app / "Contents/Info.plist")
    executable = app / "Contents/MacOS/FloatingSpaceReference"
    subprocess.run(["swiftc", "-parse-as-library", "-O", str(HELPER / "main.swift"), "-o", str(executable)], check=True)
    return executable


def check_space(output: Path, rows: list[dict], report: dict) -> None:
    seen = json.loads((output / "helper.json").read_text())
    assert seen["fullscreen"] and seen["active"], f"The helper was not the active fullscreen app: {seen}"
    floated = next(row["details"] for row in rows if row["event"] == "video-placement" and row["details"]["placement"] == FLOATING)
    on_screen = {window["number"]: window for window in seen["playerWindowsOnScreen"]}
    panel = on_screen.get(floated["videoWindowNumber"])
    assert panel and panel["layer"] == 3 and panel["alpha"] > 0, f"Panel {floated['videoWindowNumber']} is not on screen: {seen}"
    assert floated["mainWindowNumber"] not in on_screen, "The main window is on screen, so the helper's Space is not active"
    report["checks"].append(f"Over the helper's fullscreen Space, CGWindowListCopyWindowInfo(.optionOnScreenOnly) lists panel "
                            f"{floated['videoWindowNumber']} at floating layer 3, bounds {panel['bounds']}, and not main window "
                            f"{floated['mainWindowNumber']}")


def run(kind: str, output: Path, args: argparse.Namespace, helper: Path | None) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    for name in ("dom.json", "lifecycle.jsonl", "helper.json"):
        (output / name).unlink(missing_ok=True)
    env = dict(os.environ, METAL_DLSS_MPV_LIBRARY=str(args.mpv), HDRPLAYER_UI_SMOKE_KIND=kind,
               HDRPLAYER_UI_SMOKE_REPORT=str(output / "dom.json"), HDRPLAYER_LIFECYCLE_LOG=str(output / "lifecycle.jsonl"))
    for name in ("HDRPLAYER_DEVELOPER_MODES", "HDRPLAYER_UI_SMOKE_KEEP_PREFERENCES"):
        env.pop(name, None)
    report: dict = {"kind": kind, "passed": False, "checks": []}
    helper_process = None
    with (output / "player.log").open("w") as log:
        player = subprocess.Popen([str(args.executable), str(args.source)], cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            if helper:
                ready = "floating(mainHidden: true)" if kind == "floating-space-hidden-main" else FLOATING
                deadline = time.monotonic() + 60
                while ready not in placements(lifecycle(output / "lifecycle.jsonl")):
                    assert player.poll() is None and time.monotonic() < deadline, "The player never floated the video"
                    time.sleep(0.2)
                helper_process = subprocess.Popen([str(helper), str(player.pid), str(output / "helper.json")],
                                                  stdout=log, stderr=subprocess.STDOUT)
                assert helper_process.wait(timeout=60) == 0, "The Space helper failed"
            report["exitCode"] = player.wait(timeout=120)
            assert report["exitCode"] == 0, f"Player exited {report['exitCode']}"
            dom = json.loads((output / "dom.json").read_text())
            assert dom.get("passed") is True, dom.get("failure", "Smoke failed")
            report["checks"] += dom["checks"]
            rows = lifecycle(output / "lifecycle.jsonl")
            events = [row["event"] for row in rows]
            begin, destroyed, finish = (events.index(name) for name in
                                        ("termination-requested", "native-worker-destroyed", "diagnostic-finish"))
            assert begin < destroyed < finish == len(rows) - 1, "Teardown order or final flush is incomplete"
            assert rows[destroyed]["details"]["nativeChildViews"] == 0, "mpv's view survived core destruction"
            report["checks"].append("Exit code 0 after termination-requested, native-worker-destroyed and diagnostic-finish in order")
            before_quit = placements(rows[:begin])
            report["placements"] = placements(rows)
            if kind == "floating-video-close-main":
                closed = events.index("main-window-closed")
                assert events[closed + 1] == "termination-requested", "Closing the main window did not request termination"
                assert before_quit[-2:] == ["main", "quitting"], f"Unexpected placements {before_quit}"
                report["checks"].append("Closing the main window after the panel requested termination itself")
            else:
                expected = "floating(mainHidden: true)" if kind == "floating-video" else FLOATING
                assert before_quit[-1] == expected, f"The video was not floating at quit: {before_quit}"
                report["checks"].append(f"The app quit with placement {expected}")
            if helper:
                check_space(output, rows, report)
            report["passed"] = True
        except (AssertionError, OSError, ValueError, KeyError, StopIteration, subprocess.TimeoutExpired) as error:
            report["failure"] = str(error) or type(error).__name__
        finally:
            for process in (helper_process, player):
                if process and process.poll() is None:
                    process.kill()
                    process.wait()
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--executable", type=Path, default=ROOT / ".build/debug/HDRPlayer")
    parser.add_argument("--source", type=Path, default=ROOT / "assets/test-clips/playback/pq-30-60s.mkv")
    parser.add_argument("--mpv", type=Path, default=ROOT / "artifacts/mpv-build/libmpv.2.dylib")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/floating-video")
    parser.add_argument("--scenario", choices=SCENARIOS, action="append")
    args = parser.parse_args()
    for key in ("executable", "source", "mpv"):
        setattr(args, key, getattr(args, key).resolve())
    output = args.output.resolve()
    runs = {}
    for kind in args.scenario or SCENARIOS:
        helper = build_helper(output) if kind.startswith("floating-space") else None
        runs[kind] = run(kind, output / kind, args, helper)
    report = {"passed": all(run["passed"] for run in runs.values()), "runs": runs}
    output.mkdir(parents=True, exist_ok=True)
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
