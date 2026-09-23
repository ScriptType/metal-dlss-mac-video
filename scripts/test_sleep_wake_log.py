import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("check-sleep-wake-log.py")
SPEC = importlib.util.spec_from_file_location("sleep_wake_log", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def row(event, uptime, paused, position, pts=None, source="/clip.mkv"):
    state = {"source": source, "videoTrackID": 1, "paused": paused, "position": position,
             "exactDisplayedPTSAvailable": pts is not None}
    if pts is not None:
        state["displayed-source-pts"] = pts
    return {"event": event, "uptimeSeconds": uptime, "state": state, "details": {}}


FINISH = {"event": "diagnostic-finish", "uptimeSeconds": 200.0, "state": {}, "details": {"workerDestroyed": True}}


def cycle(paused, position, pts, after, finish=True):
    rows = [row("state", 90.0, paused, position - 1, pts - 30), row("will-sleep.before-pause", 99.0, paused, position, pts),
            row("system-will-sleep", 99.5, True, position, pts), row("system-has-powered-on", 100.0, True, position, pts),
            *after]
    return rows + [FINISH] if finish else rows


class SleepWakeLogTests(unittest.TestCase):
    def verdict(self, rows, expect):
        return all(ok for ok, _ in CHECK.judge(rows, expect))

    def test_paused_clip_that_stays_paused_on_the_same_frame_passes(self):
        after = [row("did-wake.restore-enqueued", 100.5, True, 12.0, 360), row("state", 112.0, True, 12.05, 360)]
        self.assertTrue(self.verdict(cycle(True, 12.0, 360, after), "paused"))

    def test_paused_clip_that_resumes_moves_or_changes_frame_fails(self):
        self.assertFalse(self.verdict(cycle(True, 12.0, 360, [row("state", 112.0, False, 12.0, 360)]), "paused"))
        self.assertFalse(self.verdict(cycle(True, 12.0, 360, [row("state", 112.0, True, 12.5, 360)]), "paused"))
        self.assertFalse(self.verdict(cycle(True, 12.0, 360, [row("state", 112.0, True, 12.0, 361)]), "paused"))

    def test_playing_clip_that_resumes_and_shows_new_frames_passes(self):
        after = [row("state", 101.0, True, 20.0, 600), row("state", 102.0, False, 20.4, 612), row("state", 111.0, False, 29.0, 870)]
        self.assertTrue(self.verdict(cycle(False, 20.0, 600, after), "playing"))

    def test_playing_clip_with_a_frozen_picture_fails(self):
        after = [row("state", 102.0, False, 20.4, 600), row("state", 111.0, False, 29.0, 600)]
        self.assertFalse(self.verdict(cycle(False, 20.0, 600, after), "playing"))

    def test_playing_clip_that_resumes_late_or_not_at_all_fails(self):
        late = [row("state", 101.0, True, 20.0, 600), row("state", 120.0, False, 20.1, 603), row("state", 125.0, False, 25.0, 750)]
        self.assertFalse(self.verdict(cycle(False, 20.0, 600, late), "playing"))
        never = [row("state", 101.0, True, 20.0, 600), row("state", 111.0, True, 20.0, 600)]
        self.assertFalse(self.verdict(cycle(False, 20.0, 600, never), "playing"))

    def test_short_observation_crash_or_changed_source_fails(self):
        self.assertFalse(self.verdict(cycle(True, 12.0, 360, [row("state", 101.0, True, 12.0, 360)]), "paused"))
        self.assertFalse(self.verdict(cycle(True, 12.0, 360, [row("state", 112.0, True, 12.0, 360)], finish=False), "paused"))
        other = [row("state", 112.0, True, 12.0, 360, source="/other.mkv")]
        self.assertFalse(self.verdict(cycle(True, 12.0, 360, other), "paused"))

    def test_workspace_events_without_iokit_pair_fail(self):
        rows = [row("will-sleep.before-pause", 1.0, True, 5, 150), row("did-wake.restore-enqueued", 2.0, True, 5, 150), FINISH]
        self.assertEqual(CHECK.judge(rows, "paused"),
                         [(False, "no IOKit system-will-sleep followed by system-has-powered-on in the log")])

    def test_truncated_log_prints_fail_instead_of_crashing(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl") as log:
            log.write('{"event": "state", "uptimeSeconds": 1.0, "state": {\n')
            log.flush()
            result = subprocess.run([sys.executable, str(SCRIPT), "--expect", "paused", log.name], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("SLEEP/WAKE CHECK: FAIL", result.stdout)


if __name__ == "__main__":
    unittest.main()
