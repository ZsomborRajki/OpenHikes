"""What the report reads, before it decides anything about it.

Every number in the report starts as text in one of two files nothing else
validates: the `xcodebuild` log, and the tab-separated event file the app wrote
into its own container. A parser that quietly drops a column, or quietly keeps
a malformed one, produces a report that is confident and wrong — which is the
one failure this generator has already shipped.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from loader import load

report = load("perf-report.py")


class ParsingTests(unittest.TestCase):
    def written(self, text: str) -> Path:
        """`text` as a file, cleaned up when the test ends."""
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "input"
        path.write_text(text)
        return path

    # `PERF-PHASE` is what lets an event in one file be attributed to a gesture
    # in the other, so its two timestamps have to survive as numbers.
    def test_a_phase_line_becomes_a_phase_on_its_scenario(self):
        scenarios, _, _, _ = report.parse_build_log(
            self.written("PERF-PHASE\tidle\tsettle\t1000.0\t1010.5\n")
        )
        (phase,) = scenarios["idle"].phases
        self.assertEqual(phase.name, "settle")
        self.assertEqual(phase.start, 1000.0)
        self.assertEqual(phase.end, 1010.5)
        self.assertAlmostEqual(phase.duration, 10.5)

    # A phase whose end precedes its start is a clock that moved, not a
    # negative duration.
    def test_a_phase_that_ends_before_it_starts_has_no_duration(self):
        phase = report.Phase("idle", "settle", start=10.0, end=9.0)
        self.assertEqual(phase.duration, 0.0)

    # The suite prints no trailing field for a counter with no per-fix ratio,
    # and `strip()` has already eaten the empty one. Requiring six fields threw
    # ValueError on the first counter that had no fixes to divide by.
    def test_a_counter_with_no_ratio_still_parses(self):
        scenarios, _, _, _ = report.parse_build_log(
            self.written("PERF-COUNT\tidle\tidle\tProcess\t7.0\n")
        )
        self.assertEqual(scenarios["idle"].counts, [("idle", "Process", 7.0, "")])

    def test_a_counter_keeps_its_ratio_as_written(self):
        scenarios, _, _, _ = report.parse_build_log(
            self.written("PERF-COUNT\tmap\tscrub\tMapSheetBody\t9.0\t3.0\n")
        )
        self.assertEqual(scenarios["map"].counts, [("scrub", "MapSheetBody", 9.0, "3.0")])

    # Both halves of the XCTest line, because the report prints the deviation
    # and compares the average — reading one out of the other's group would
    # baseline the wrong number.
    def test_an_xctest_metric_is_read_as_average_and_deviation(self):
        _, measurements, metrics, _ = report.parse_build_log(
            self.written(
                "measured [Clock Monotonic Time, s] average: 1.234, "
                "relative standard deviation: 5.678%, values: [...]\n"
            )
        )
        self.assertEqual(metrics, {"Clock Monotonic Time, s": 1.234})
        self.assertEqual(
            measurements, ["Clock Monotonic Time, s — average 1.234, deviation 5.678%"]
        )

    def test_a_test_case_line_is_read_as_a_result(self):
        _, _, _, results = report.parse_build_log(
            self.written(
                "Test Case '-[PerformanceUITests testIdle]' passed (1.0 seconds).\n"
                "Test Case '-[PerformanceUITests testScrub]' failed (2.0 seconds).\n"
            )
        )
        self.assertEqual(results, ["testIdle: passed", "testScrub: failed"])

    def test_the_event_file_header_and_blank_lines_are_not_events(self):
        events = report.parse_events(
            self.written("# epoch_s\telapsed_s\tkind\tname\tvalue\tdetail\n\n")
        )
        self.assertEqual(events, [])

    # A line with fewer than five columns is a truncated write — the app was
    # killed mid-flush — and reading it positionally would put a name in the
    # value column.
    def test_a_short_line_is_dropped_rather_than_read_positionally(self):
        events = report.parse_events(self.written("1000.0\t1.0\tmark\tScenePhase\n"))
        self.assertEqual(events, [])

    def test_a_line_with_an_unparsable_number_is_dropped(self):
        events = report.parse_events(
            self.written("later\t1.0\tinterval\tModelContainerInit\t40.2\t\n")
        )
        self.assertEqual(events, [])

    def test_an_event_keeps_its_detail_and_an_absent_value_stays_absent(self):
        (mark,) = report.parse_events(
            self.written("1001.0\t1.0\tmark\tScenePhaseChanged\t\tbackground\n")
        )
        self.assertIsNone(mark.value)
        self.assertEqual(mark.detail, "background")
        self.assertEqual(mark.epoch, 1001.0)
        self.assertEqual(mark.elapsed, 1.0)

    # `value` is milliseconds and `elapsed` is seconds, and an interval is
    # stamped when it *finishes* — so its length is what says where it began.
    # A mark is a point however a caller filled the column in.
    def test_only_an_interval_has_a_duration(self):
        interval = report.Event(
            elapsed=2.2, epoch=1002.2, kind="interval", name="TileNetworkFetch",
            value=120.0, detail="",
        )
        mark = report.Event(
            elapsed=2.2, epoch=1002.2, kind="mark", name="ScenePhaseChanged",
            value=120.0, detail="active",
        )
        self.assertAlmostEqual(interval.duration, 0.12)
        self.assertEqual(mark.duration, 0.0)

    # The detail column started as one number and grew keys. Reading it
    # positionally is how a report silently reports the wrong column after the
    # next addition.
    def test_a_detail_is_read_by_key(self):
        self.assertEqual(
            report.detail_fields("cpu_s=12.5 lowPower=1 thermal=nominal"),
            {"cpu_s": "12.5", "lowPower": "1", "thermal": "nominal"},
        )

    def test_a_detail_token_with_no_key_is_ignored(self):
        self.assertEqual(report.detail_fields("background"), {})

    def test_a_percentile_of_nothing_is_zero_rather_than_an_error(self):
        self.assertEqual(report.percentile([], 0.5), 0.0)

    def test_a_percentile_lands_on_a_measured_value(self):
        values = [10.0, 20.0, 30.0, 40.0]
        self.assertEqual(report.percentile(values, 0.0), 10.0)
        self.assertEqual(report.percentile(values, 0.5), 30.0)
        self.assertEqual(report.percentile(values, 1.0), 40.0)

    # Never an index past the end, whatever fraction a caller passes.
    def test_a_percentile_above_one_stays_inside_the_samples(self):
        self.assertEqual(report.percentile([10.0, 20.0], 2.0), 20.0)


if __name__ == "__main__":
    unittest.main()
