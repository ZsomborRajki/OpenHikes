"""How this run disagrees with the last one, in both directions.

Growth is the obvious regression. A *fall* is reported just as loudly, because
a suite made entirely of upper bounds cannot notice work that has stopped: a
recording clock once froze and scored perfectly against every budget in the
suite. A counter that reaches zero, and a counter the runner cannot find at
all, are what that failure looks like from here.
"""

from __future__ import annotations

import unittest

from loader import load

report = load("perf-report.py")


def scenario(name: str, counts) -> object:
    return report.Scenario(name, counts=list(counts))


def baseline(counters, metrics=None, tolerance=0.10) -> dict:
    return {"tolerance": tolerance, "counters": counters, "metrics": metrics or {}}


class BaselineTests(unittest.TestCase):
    def drift(self, before, counts, metrics=None, measured=None):
        scenarios = {"map": scenario("map", counts)}
        return report.compare_to_baseline(
            baseline({"map": {"scrub": before}}, metrics), scenarios, measured or {}
        )

    def test_a_count_inside_the_tolerance_is_not_drift(self):
        self.assertEqual(
            self.drift({"MapSheetBody": 100.0}, [("scrub", "MapSheetBody", 105.0, "")]), []
        )

    def test_a_count_that_rose_past_the_tolerance_is_reported(self):
        (note,) = self.drift({"MapSheetBody": 100.0}, [("scrub", "MapSheetBody", 111.0, "")])
        self.assertEqual(note, "`map` · `scrub` · `MapSheetBody` rose 100 → 111.")

    def test_a_count_that_fell_past_the_tolerance_is_reported(self):
        (note,) = self.drift({"MapSheetBody": 100.0}, [("scrub", "MapSheetBody", 89.0, "")])
        self.assertEqual(note, "`map` · `scrub` · `MapSheetBody` fell 100 → 89.")

    # The frozen clock. A counter measuring work that is supposed to happen and
    # reaching zero passes every upper bound in the suite.
    def test_a_count_that_reached_zero_says_the_work_stopped(self):
        (note,) = self.drift(
            {"RecordingClockTick": 51.0}, [("scrub", "RecordingClockTick", 0.0, "")]
        )
        self.assertIn("the work stopped happening", note)

    def test_a_counter_with_no_baseline_is_reported_as_new(self):
        (note,) = self.drift({}, [("scrub", "MapSheetBody", 9.0, "")])
        self.assertEqual(note, "`map` · `scrub` · `MapSheetBody` is new — 9, no baseline.")

    # A counter the runner cannot find is a counter that passes, which is the
    # same failure as a test the runner cannot find.
    def test_a_baselined_counter_that_was_not_reported_is_reported(self):
        (note,) = self.drift({"MapSheetBody": 9.0}, [])
        self.assertIn("was not reported at all this run", note)

    # The tolerance is the baseline file's, so a scenario that is genuinely
    # noisy raises its own rather than everyone paying for it.
    def test_the_baselines_own_tolerance_is_the_one_applied(self):
        scenarios = {"map": scenario("map", [("scrub", "MapSheetBody", 111.0, "")])}
        wide = baseline({"map": {"scrub": {"MapSheetBody": 100.0}}}, tolerance=0.5)
        self.assertEqual(report.compare_to_baseline(wide, scenarios, {}), [])

    def test_a_metric_that_moved_is_reported_in_both_directions(self):
        rose = self.drift({}, [], metrics={"Duration": 1.0}, measured={"Duration": 1.5})
        fell = self.drift({}, [], metrics={"Duration": 1.0}, measured={"Duration": 0.5})
        self.assertIn("`Duration` rose 1 → 1.5.", rose)
        self.assertIn("`Duration` fell 1 → 0.5.", fell)

    def test_a_metric_that_was_not_measured_is_reported(self):
        (note,) = self.drift({}, [], metrics={"Duration": 1.0})
        self.assertEqual(note, "`Duration` was not measured this run — baseline 1.")

    # Only the counters and the XCTest metrics: a footprint reading taken under
    # XCUITest is automation overhead rather than the app's, and comparing one
    # across runs would produce confident nonsense.
    def test_a_snapshot_carries_the_counters_and_the_metrics_and_nothing_else(self):
        snapshot = report.baseline_snapshot(
            {"map": scenario("map", [("scrub", "MapSheetBody", 9.0, "3.0")])},
            {"Duration": 1.0},
        )
        self.assertEqual(
            snapshot,
            {
                "tolerance": report.DEFAULT_TOLERANCE,
                "counters": {"map": {"scrub": {"MapSheetBody": 9.0}}},
                "metrics": {"Duration": 1.0},
            },
        )

    # A snapshot is read back by `--baseline`, so a run compared against its own
    # snapshot has to be silent.
    def test_a_run_compared_against_its_own_snapshot_reports_nothing(self):
        scenarios = {"map": scenario("map", [("scrub", "MapSheetBody", 9.0, "3.0")])}
        metrics = {"Duration": 1.0}
        snapshot = report.baseline_snapshot(scenarios, metrics)
        self.assertEqual(report.compare_to_baseline(snapshot, scenarios, metrics), [])


if __name__ == "__main__":
    unittest.main()
