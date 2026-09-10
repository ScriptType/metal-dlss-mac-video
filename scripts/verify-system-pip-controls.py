#!/usr/bin/env python3
"""Correlate recorded real system AX actions with AVKit callbacks and native state."""
import argparse
from fractions import Fraction
import json
from pathlib import Path


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", type=Path, required=True)
    args = parser.parse_args()
    base = args.session.resolve()
    session = json.loads((base / "session.json").read_text())
    actions = json.loads((base / "action-checks.json").read_text())
    pip = json.loads((base / "pip.json").read_text())
    lifecycle = [json.loads(line) for line in (base / "lifecycle.jsonl").read_text().splitlines()]
    report = {"passed": False, "checks": [], "callbacks": [],
        "scope": "Actual system PiP AX controls, callbacks and native state; no physical HDR, acoustic A/V or presented-cadence qualification"}

    def point(prefix):
        matches = [value for value in actions["checks"] if value["check"].startswith(prefix)]
        require(len(matches) == 1, "Missing/ambiguous native state observation: " + prefix)
        return matches[0]

    def request(name):
        return next(value["report"] for value in actions["requests"] if value["name"] == name)

    def callback(name, event, **fields):
        action = request(name)
        later_actions = [value["report"]["actionStartedHostSeconds"] for value in actions["requests"]
                         if value["report"]["actionStartedHostSeconds"] > action["actionStartedHostSeconds"]]
        end = min([action["actionHostSeconds"] + 5, *later_actions])
        matches = [value for value in pip["events"] if value["event"] == event and
            action["actionStartedHostSeconds"] <= value["hostSeconds"] < end and
            all(value.get(key) == expected for key, expected in fields.items())]
        require(len(matches) == 1, "Missing/ambiguous actual delegate callback for " + name)
        result = {"action": name, "actionStartedHostSeconds": action["actionStartedHostSeconds"],
                  "actionReturnedHostSeconds": action["actionHostSeconds"], "delegate": matches[0]}
        report["callbacks"].append(result)
        return matches[0]

    try:
        require(session["setupAndTeardownPassed"] and session["binariesUnchanged"] and actions["passed"],
                "Action/session check failed or a measured binary changed")
        require(len(actions["requests"]) == 7, "Expected seven explicit AX operations")
        for value in actions["requests"]:
            action = value["report"]
            require(action["accessibilityTrusted"] and action["actionsPerformed"] and action["actionAXStatus"] == 0 and
                    not action["requestsPermission"] and not action["changesOSPreferences"], "Invalid permission/action evidence")
            require(action["owners"][0]["bundleIdentifier"] == "com.apple.PIPAgent" and action["owners"][0]["windowCount"] == 1,
                    "Action was not scoped to the inspected system PiP owner")
        report["checks"].append("Seven explicit AX operations matched the inspected system PiP owner without permission or OS-setting changes")
        callback("01-play", "play-request", playing=True)
        callback("02-pause", "play-request", playing=False)
        require(point("system Play")["state"]["paused"] is False and point("system Pause")["state"]["paused"] is True,
                "Play/Pause callbacks did not reach the native transport")
        report["checks"].append("Actual system Play/Pause produced matching AVKit delegates and native transport changes")
        for name, prefix in [("03-back", "system backward"), ("04-forward", "system forward")]:
            asked = callback(name, "skip-request")
            established = [value for value in pip["events"] if value["event"] == "skip-generation-established" and
                           asked["hostSeconds"] <= value["hostSeconds"] <= asked["hostSeconds"] + 5]
            # The next skip can also complete within five seconds. Select the
            # first replacement after this actual delegate request.
            require(established, "Skip never established a supported generation")
            done = min(established, key=lambda value: value["hostSeconds"])
            state = point(prefix)["state"]; native = state["nativeEnhancement"]; selected = state["pip"]
            source = Fraction(selected["sourcePTS"]["value"], selected["sourcePTS"]["timescale"])
            native_source = Fraction(native["displayed-source-pts"] * native["displayed-timebase-num"], native["displayed-timebase-den"])
            duration = Fraction(selected["sourceDuration"]["value"], selected["sourceDuration"]["timescale"])
            require(source == native_source and selected["generation"] == native["displayed-generation"] == done["generation"] and
                    done["generation"] > asked["generation"] and state["paused"] and
                    abs(float(source) - asked["targetSeconds"]) <= float(duration) + .003,
                    "Skip completion has wrong exact source identity/generation or target frame")
            report["callbacks"][-1]["generationEstablished"] = done
            report["callbacks"][-1]["exactSourcePTS"] = selected["sourcePTS"]
        report["checks"].append("Both actual ten-second skip controls established matching exact native/PiP source identity in new paused generations")
        before = point("system forward")["state"]
        resized = point("system PiP window resized")
        after = resized["state"]
        require(resized["beforeSize"] != resized["afterSize"] and
                before["pip"]["sourcePTS"] == after["pip"]["sourcePTS"] and
                before["pip"]["generation"] == after["pip"]["generation"] and
                before["nativeEnhancement"]["submitted-frames"] == after["nativeEnhancement"]["submitted-frames"],
                "Actual system PiP resize was missing or changed paused frame/inference identity")
        report["resize"] = {"before": resized["beforeSize"], "requested": request("05-resize")["requestedSize"],
                            "observed": resized["afterSize"], "restore": point("system PiP accepted")}
        report["resize"]["renderSizeDelegateEvents"] = [value for value in pip["events"] if value["event"] == "render-size"]
        report["checks"].append("Actual system PiP window bounds changed and returned under AVKit constraints without frame/model resubmission")
        minimized = point("source window is actually minimized")["state"]["systemPiPSourceWindow"]
        restored = point("system Restore returns")["state"]["systemPiPSourceWindow"]
        require(minimized["minimized"] and not minimized["visible"] and not restored["minimized"] and
                all(restored[key] for key in ("visible", "key", "appActive", "frontmostIsPlayer")),
                "Restore did not return the actually minimized source window")
        callback("07-restore-window", "restore-interface")
        callback("07-restore-window", "did-stop")
        report["sourceWindowRestore"] = {"before": minimized, "after": restored}
        report["checks"].append("Actual system Restore invoked the delegate and returned the minimized source window to visible/key/active state")
        release = pip["events"][-1]
        destroyed = next(value for value in lifecycle if value["event"] == "native-worker-destroyed")
        require(release["event"] == "renderer-flushed-and-leases-released" and
                release["hostSeconds"] <= destroyed["uptimeSeconds"] and
                pip["state"]["pendingFrames"] == 0 and pip["state"]["submittedLeases"] == 0 and
                pip["state"]["maximumObservedExportLeases"] <= 3,
                "Consumer leases did not drain before core destruction")
        report["checks"].append("Renderer flush and bounded consumer lease release preceded native core destruction")
        report["passed"] = True
    except Exception as error:
        report["failure"] = str(error)
    (base / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "failure": report.get("failure"), "checks": len(report["checks"])}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
