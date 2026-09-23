import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("sleep_wake_log", Path(__file__).with_name("check-sleep-wake-log.py"))
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def row(event, paused, position, source="/clip.mkv", track=1):
    return {"event": event, "state": {"source": source, "videoTrackID": track, "paused": paused, "position": position}}


def cycle(before_paused, before_position, after):
    return [row("state", before_paused, before_position - 1), row("will-sleep.before-pause", before_paused, before_position),
            row("system-will-sleep", True, before_position), row("system-has-powered-on", True, before_position),
            *after, {"event": "diagnostic-finish", "state": {}}]


class SleepWakeLogTests(unittest.TestCase):
    def verdict(self, rows, expect):
        return all(ok for ok, _ in CHECK.judge(rows, expect))

    def test_paused_clip_that_stays_paused_passes(self):
        rows = cycle(True, 12.0, [row("did-wake.restore-enqueued", True, 12.0), row("state", True, 12.05)])
        self.assertTrue(self.verdict(rows, "paused"))

    def test_paused_clip_that_resumes_or_moves_fails(self):
        self.assertFalse(self.verdict(cycle(True, 12.0, [row("state", False, 12.0)]), "paused"))
        self.assertFalse(self.verdict(cycle(True, 12.0, [row("state", True, 12.5)]), "paused"))

    def test_playing_clip_that_resumes_passes(self):
        rows = cycle(False, 20.0, [row("state", True, 20.0), row("state", False, 20.4), row("state", False, 24.0)])
        self.assertTrue(self.verdict(rows, "playing"))

    def test_playing_clip_that_stays_paused_fails(self):
        self.assertFalse(self.verdict(cycle(False, 20.0, [row("state", True, 20.0), row("state", True, 20.0)]), "playing"))

    def test_changed_source_fails(self):
        rows = cycle(True, 12.0, [row("state", True, 12.0, source="/other.mkv")])
        self.assertFalse(self.verdict(rows, "paused"))

    def test_workspace_events_without_iokit_pair_fail(self):
        rows = [row("will-sleep.before-pause", True, 5), row("did-wake.restore-enqueued", True, 5), row("state", True, 5)]
        self.assertEqual(CHECK.judge(rows, "paused"),
                         [(False, "no IOKit system-will-sleep followed by system-has-powered-on in the log")])


if __name__ == "__main__":
    unittest.main()
