#!/usr/bin/env python3
"""Exercise the actual AX controls discovered on the tested system PiP owner.

Run against a ready start-system-pip-check.py directory. Identifier names below
were observed in its real com.apple.PIPAgent tree; missing/changed nodes fail
explicitly. The helper revalidates a fresh identity token before each action.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", type=Path, required=True)
    args = parser.parse_args()
    base = args.session.resolve()
    executable = ROOT / "artifacts/pip-accessibility/SystemPiPAccessibility"
    actions = base / "actions"
    actions.mkdir()
    checks, requests = [], []
    original_size = None
    resized = False

    def state():
        live = json.loads((base / "live.json").read_text())
        if time.monotonic() - live["hostSeconds"] > 3:
            raise RuntimeError("Live native state is stale")
        value = live["state"]
        value["systemPiPSourceWindow"] = live.get("sourceWindow", {})
        return value

    def wait(label, condition):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            current = state()
            if condition(current):
                checks.append({"check": label, "hostSeconds": time.monotonic(), "state": current})
                return current
            time.sleep(.1)
        raise RuntimeError("Timed out: " + label)

    def inspect(name):
        result = subprocess.run([str(executable), "--output", str(actions / (name + "-before.json"))],
                                capture_output=True, text=True, check=True, timeout=15)
        report = json.loads(result.stdout)
        if len(report["owners"]) != 1 or report["owners"][0]["windowCount"] != 1:
            raise RuntimeError("Expected exactly one system PiP owner/window")
        return report["owners"][0]

    def node(owner, identifier):
        matches = [value for value in owner["nodes"] if value.get("identifier") == identifier]
        if len(matches) != 1:
            raise RuntimeError(f"Observed control identifier {identifier!r} is not uniquely available")
        return matches[0]

    def action(name, identifier, resize=None):
        owner = inspect(name)
        target = node(owner, identifier)
        command = [str(executable), "--owner-pid", str(owner["pid"]), "--owner-bundle", owner["bundleIdentifier"],
                   "--node", target["path"], "--token", target["matchToken"], "--output", str(actions / (name + ".json"))]
        command.extend(["--resize", f"{resize[0]}x{resize[1]}"] if resize else ["--press"])
        result = subprocess.run(command, capture_output=True, text=True, timeout=15)
        report = json.loads(result.stdout)
        requests.append({"name": name, "identifier": identifier, "observedDescription": target.get("description"),
                         "report": report})
        if result.returncode != 0:
            raise RuntimeError(report.get("error", "AX action failed"))
        return report

    def identity(value):
        return value["pip"]["sourcePTS"], value["pip"]["generation"], value["nativeEnhancement"]["submitted-frames"]

    report = {"passed": False, "scope": "Real system AX actions and independently observed native state; delegate correlation follows process teardown"}
    try:
        initial = state()
        if not initial["pip"]["active"] or not initial["paused"]:
            raise RuntimeError("Setup must provide active paused PiP")
        initial_owner = inspect("00-initial")
        original_size = node(initial_owner, "picture-in-picture")["size"]
        action("01-play", "play")
        wait("system Play resumes native transport", lambda value: not value["paused"] and value["position"] > 20.02)
        action("02-pause", "pause")
        before = wait("system Pause holds native transport", lambda value: value["paused"] and value["pip"]["clockRate"] == 0)
        generation, position = before["pip"]["generation"], before["position"]
        action("03-back", "skip-back")
        before = wait("system backward skip reaches a new supported paused generation", lambda value:
            value["paused"] and value["pip"]["available"] and value["pip"]["generation"] > generation and
            abs(value["position"] - (position - 10)) < .15)
        generation, position = before["pip"]["generation"], before["position"]
        action("04-forward", "skip-forward")
        wait("system forward skip reaches a new supported paused generation", lambda value:
            value["paused"] and value["pip"]["available"] and value["pip"]["generation"] > generation and
            abs(value["position"] - (position + 10)) < .15)
        time.sleep(.4)
        prior_identity = identity(state())
        size = [min(original_size[0] + 120, 1024), min(original_size[1] + 80, 768)]
        action("05-resize", "picture-in-picture", resize=size)
        resized = True
        time.sleep(.8)
        window = node(inspect("05-resize-after"), "picture-in-picture")
        after = state()
        if window["size"] == original_size or identity(after) != prior_identity:
            raise RuntimeError("System window resize did not change bounds or changed paused source/inference identity")
        checks.append({"check": "system PiP window resized while paused identity and inference count stayed unchanged",
                       "hostSeconds": time.monotonic(), "beforeSize": original_size, "afterSize": window["size"], "state": after})
        action("06-restore-size", "picture-in-picture", resize=original_size)
        time.sleep(.5)
        restored = node(inspect("06-restore-size-after"), "picture-in-picture")["size"]
        if restored == window["size"]:
            raise RuntimeError("System PiP size restoration request had no observed effect")
        checks.append({"check": "system PiP accepted the original-size request with its own aspect constraints",
                       "requestedSize": original_size, "observedSize": restored,
                       "exactSizeRestored": restored == original_size})
        resized = False
        (base / "minimize").touch()
        wait("source window is actually minimized before system Restore", lambda value:
             value["systemPiPSourceWindow"].get("minimized") is True and value["pip"]["active"])
        action("07-restore-window", "restore")
        wait("system Restore returns from PiP to the visible active source window", lambda value:
             not value["pip"]["active"] and value["systemPiPSourceWindow"].get("minimized") is False and
             value["systemPiPSourceWindow"].get("visible") is True and value["systemPiPSourceWindow"].get("key") is True and
             value["systemPiPSourceWindow"].get("appActive") is True and value["systemPiPSourceWindow"].get("frontmostIsPlayer") is True)
        report["passed"] = True
    except Exception as error:
        report["failure"] = str(error)
    finally:
        if resized and original_size is not None:
            try:
                action("cleanup-restore-size", "picture-in-picture", resize=original_size)
            except Exception as error:
                report["sizeRestoreFailure"] = str(error)
        report["checks"], report["requests"] = checks, requests
        (base / "action-checks.json").write_text(json.dumps(report, indent=2) + "\n")
        (base / "finish").touch()
    print(json.dumps({"passed": report["passed"], "failure": report.get("failure"), "checks": len(checks)}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
