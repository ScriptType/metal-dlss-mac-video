"""CPU checks for comparison evidence eligibility; no player or GPU needed."""
import json
import unittest

from adapter_visibility import completed_window, qualify_visibility, window_events


def state(host, **changes):
    return dict(hostSeconds=host, isVisible=True, occlusionVisible=True,
                isMiniaturized=False, appActive=True, windowNumber=42, **changes)


class VisibilityTests(unittest.TestCase):
    def test_visible_background_window_remains_eligible(self):
        events = [state(n) for n in range(5)]
        events[2]["appActive"] = False
        result = qualify_visibility(events, .25, 4.25)
        self.assertTrue(result["eligible"])
        self.assertEqual(result["observedInactiveSeconds"], 1)

    def test_brief_occlusion_is_retained_and_rejected(self):
        events = [state(n) for n in range(5)]
        covered = state(1.1)
        covered["occlusionVisible"] = False
        events += [covered, state(1.15)]
        result = qualify_visibility(events, .25, 4.25)
        self.assertFalse(result["eligible"])
        self.assertEqual(result["ineligibleObservations"], [covered])
        self.assertAlmostEqual(result["observedVisibleSeconds"], 3.95)

    def test_missing_start_tail_gap_and_changed_window_fail(self):
        self.assertFalse(qualify_visibility([state(1), state(2)], .25, 2.25)["eligible"])
        self.assertFalse(qualify_visibility([state(0)], .25, 3)["eligible"])
        events = [state(n) for n in range(5)]
        events[2]["windowNumber"] = 43
        self.assertFalse(qualify_visibility(events, .25, 4.25)["eligible"])

    def test_hidden_or_unavailable_state_fails(self):
        for field, value in [("isVisible", False), ("isMiniaturized", True),
                             ("occlusionVisible", None), ("windowNumber", 0)]:
            events = [state(n) for n in range(3)]
            events[1][field] = value
            self.assertFalse(qualify_visibility(events, .25, 2.25)["eligible"])

    def test_parse_actual_native_states_and_ignore_foreground_request(self):
        erika = json.dumps(dict(event="erika_native_window", host=1,
            state=dict(visible=1, occlusionVisible=0, miniaturized=0, active=1, windowNumber=42)))
        mpv = 'HDRPLAYER_MPV_WINDOW_STATE ' + json.dumps(dict(state(1), forceRenderRequested=True))
        self.assertFalse(window_events('unrelated log\n' + erika, "erika")[0]["occlusionVisible"])
        self.assertEqual(window_events(mpv, "mpv"), [state(1)])
        with self.assertRaises(ValueError):
            window_events('HDRPLAYER_MPV_WINDOW_STATE {"hostSeconds": NaN}', "mpv")

    def test_completed_window_requires_full_inventory_excludes_warmup(self):
        report = dict(retainedSamples=3, completedTotal=3, frames=[
            dict(warmup=True, submittedHostSeconds=0, completedHostSeconds=1),
            dict(warmup=False, submittedHostSeconds=1, completedHostSeconds=2),
            dict(warmup=False, submittedHostSeconds=1.5, completedHostSeconds=3)])
        self.assertEqual(completed_window(report), (1, 3))
        report["completedTotal"] = 4
        with self.assertRaises(ValueError):
            completed_window(report)


if __name__ == "__main__":
    unittest.main()
