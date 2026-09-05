"""The tables, and the rates in them that are not simply counts.

Everything here divides something by something else — bodies by the seconds
they ran over, CPU seconds by the wall clock, a scenario's cost by an hour of
hiking that was never measured — and a rate is where this generator has been
wrong before. The extrapolation is labelled as one for the same reason.
"""

from __future__ import annotations

import unittest

from loader import load

report = load("perf-report.py")


def sample(elapsed: float, footprint: float, detail: str) -> object:
    return report.Event(
        elapsed=elapsed, epoch=1000 + elapsed, kind="sample",
        name="Process", value=footprint, detail=detail,
    )


def scenario(name: str, events=(), counts=(), phases=()) -> object:
    return report.Scenario(name, events=list(events), counts=list(counts), phases=list(phases))


def rendered(lines) -> str:
    return "\n".join(lines)


class SectionTests(unittest.TestCase):
    def test_a_table_with_no_rows_says_so_rather_than_printing_a_header(self):
        self.assertEqual(report.markdown_table(["Signpost", "Count"], []), ["_No data._", ""])

    # Loudest first: a table sorted by name buries the counter worth reading.
    def test_counters_are_listed_worst_first_and_a_missing_ratio_is_a_dash(self):
        section = rendered(
            report.counter_section(
                scenario(
                    "map",
                    counts=[
                        ("scrub", "MapSheetBody", 4.0, "1.0"),
                        ("scrub", "MapSheetHikesBody", 9.0, ""),
                    ],
                )
            )
        )
        self.assertLess(section.index("MapSheetHikesBody"), section.index("MapSheetBody"))
        self.assertIn("| MapSheetHikesBody | 9 | — |", section)

    # Events per second, over the span the scenario actually ran.
    def test_the_timeline_reports_a_rate_over_the_run(self):
        events = [
            report.Event(elapsed=elapsed, epoch=1000 + elapsed, kind="interval",
                         name="MapSheetBody", value=milliseconds, detail="")
            for elapsed, milliseconds in ((0.5, 1.0), (1.0, 3.0), (1.5, 2.0), (2.0, 10.0))
        ]
        section = rendered(report.timeline_section(scenario("map", events)))
        self.assertIn("| MapSheetBody | interval | 4 | 2.00 | 3.00 | 10.00 |", section)

    def test_a_scenario_with_no_events_has_no_timeline(self):
        self.assertEqual(
            report.timeline_section(scenario("map")), ["_No signpost events were recorded._", ""]
        )

    # CPU is a counter that only goes up, so what a scenario burned is the
    # difference between its first and last sample — not the last reading.
    def test_cpu_is_the_difference_between_the_first_and_last_sample(self):
        section = rendered(
            report.resource_section(
                scenario(
                    "idle",
                    [
                        sample(0.0, 100.0, "cpu_s=4.0"),
                        sample(5.0, 150.0, "cpu_s=4.5"),
                        sample(10.0, 120.0, "cpu_s=5.0"),
                    ],
                )
            )
        )
        self.assertIn("| CPU time consumed | 1.00 s over 10.0 s |", section)
        self.assertIn("| Mean CPU utilisation | 10.0% of one core |", section)
        self.assertIn("| Footprint at start | 100.0 MB |", section)
        self.assertIn("| Footprint at end | 120.0 MB |", section)
        self.assertIn("| Footprint peak | 150.0 MB |", section)

    # One sample is no span at all, and a span of zero seconds must not be a
    # denominator.
    def test_a_single_sample_is_not_divided_by_a_span_of_zero(self):
        section = rendered(
            report.resource_section(scenario("idle", [sample(3.0, 100.0, "cpu_s=4.0")]))
        )
        self.assertIn("| CPU time consumed | 0.00 s over 1.0 s |", section)

    def test_a_scenario_with_no_samples_reports_no_resources(self):
        self.assertEqual(
            report.resource_section(scenario("idle")), ["_No resource samples were recorded._", ""]
        )

    # Per hiking hour, because that is the unit the walker experiences — and
    # labelled as an extrapolation, because a fifty-second scenario has not
    # measured an hour of anything.
    def test_the_hourly_cost_is_labelled_as_an_extrapolation(self):
        section = rendered(
            report.energy_section(
                scenario(
                    "idle",
                    [sample(0.0, 100.0, "cpu_s=4.0"), sample(10.0, 100.0, "cpu_s=5.0")],
                )
            )
        )
        self.assertIn("| Extrapolated | 360 CPU-s per hiking hour |", section)

    # The offline claim, stated as a number rather than as an absence.
    def test_a_scenario_that_opened_no_connection_says_so(self):
        section = rendered(report.energy_section(scenario("offline", [sample(0.0, 100.0, "")])))
        self.assertIn("No request left the device. Every byte came from cache.", section)

    def test_the_pocket_is_reported_as_a_share_of_the_requests(self):
        events = [
            report.Event(elapsed=1.0, epoch=1001.0, kind="mark",
                         name="ScenePhaseChanged", value=None, detail="background"),
            report.Event(elapsed=1.5, epoch=1001.5, kind="interval",
                         name="TileNetworkFetch", value=100.0, detail="thread=off-main"),
            report.Event(elapsed=2.0, epoch=1002.0, kind="mark",
                         name="ScenePhaseChanged", value=None, detail="inactive"),
            report.Event(elapsed=2.2, epoch=1002.2, kind="interval",
                         name="TileNetworkFetch", value=120.0, detail="thread=off-main"),
        ]
        section = rendered(report.energy_section(scenario("recording", events)))
        self.assertIn(
            "1 of 2 requests were made while backgrounded, over 1.0 s in a pocket.", section
        )

    # A stall is placed by the phase it landed in, which is what makes it
    # answerable for a gesture rather than for the run.
    def test_a_stall_is_attributed_to_the_phase_it_landed_in(self):
        subject = scenario(
            "recording",
            events=[
                report.Event(elapsed=3.0, epoch=1003.0, kind="stall",
                             name="MainThreadStall", value=212.0, detail=""),
                report.Event(elapsed=9.0, epoch=1009.0, kind="stall",
                             name="MainThreadStall", value=180.0, detail=""),
            ],
            phases=[report.Phase("recording", "scrub", 1002.0, 1004.0)],
        )
        section = rendered(report.stall_section(subject))
        self.assertIn("| 3.00 s | 212 ms | scrub |", section)
        self.assertIn("| 9.00 s | 180 ms | outside a measured phase |", section)

    def test_a_run_with_no_stall_says_what_the_budget_was(self):
        self.assertEqual(
            report.stall_section(scenario("idle")),
            ["No main-thread stall exceeded the watchdog's 150 ms budget.", ""],
        )


if __name__ == "__main__":
    unittest.main()
