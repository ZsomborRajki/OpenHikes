"""The arithmetic behind every line a person reads first after a run.

A finding is not a measurement; it is a claim made *about* measurements, and
every rule here exists because a previous version of that claim was wrong in a
way that read exactly like a regression. The generator has shipped an invented
finding before — "52.2 network requests per accepted fix" for a recording that
woke the radio zero times — so the ratios are asserted here against input small
enough to check by hand.
"""

from __future__ import annotations

import unittest

from loader import load

report = load("perf-report.py")


def scenario(name: str, counts=(), events=()) -> object:
    return report.Scenario(name, events=list(events), counts=list(counts))


def interval(name: str, value: float, detail: str = "", elapsed: float = 1.0) -> object:
    return report.Event(
        elapsed=elapsed, epoch=1000 + elapsed, kind="interval",
        name=name, value=value, detail=detail,
    )


class FindingTests(unittest.TestCase):
    def ratio(self, count, ratio, transitions, name="MapSheetBody", phase="scrub"):
        return report.body_ratio_finding(
            scenario("map"), phase, name, count, ratio, transitions
        )

    # The shape the harness's own note is about. `background-recording` ran
    # four bodies for four scene transitions and accepted three fixes; the
    # fixes paid for none of it, and the raw ratio said 1.33 per fix for four
    # separate views.
    def test_a_body_that_only_ran_for_scene_transitions_is_not_a_finding(self):
        self.assertIsNone(self.ratio(4.0, "1.3333333333333333", 4.0))

    # What is left after the transitions is the part a fix is answerable for:
    # nine bodies, four of them the phase's edges, three fixes — 1.67, not 3.
    def test_the_bodies_left_over_are_charged_to_the_fixes(self):
        finding = self.ratio(9.0, "3.0", 4.0)
        self.assertIsNotNone(finding)
        self.assertAlmostEqual(finding.magnitude, 5 / 3)
        self.assertEqual(finding.measure, "1.67×")
        self.assertIn("beyond the 4 scene transition(s)", finding.single)

    def test_a_phase_with_no_transitions_charges_every_body_to_the_fixes(self):
        finding = self.ratio(9.0, "3.0", 0.0)
        self.assertEqual(finding.measure, "3.00×")

    # One evaluation per fix is the budget, not a violation of it.
    def test_a_body_evaluated_once_per_fix_is_not_a_finding(self):
        self.assertIsNone(self.ratio(3.0, "1.0", 0.0))

    def test_a_counter_that_is_not_a_body_is_left_to_the_counter_table(self):
        self.assertIsNone(self.ratio(9.0, "3.0", 0.0, name="LiveFixAccepted"))

    # A counter printed with no ratio has no fix count to divide by; inventing
    # one is how a ratio becomes a finding about nothing.
    def test_a_counter_with_no_ratio_is_not_a_finding(self):
        self.assertIsNone(self.ratio(9.0, "", 0.0))

    def test_a_ratio_that_is_not_a_number_is_not_a_finding(self):
        self.assertIsNone(self.ratio(9.0, "—", 0.0))

    def test_a_scenario_that_accepted_no_fixes_is_not_divided_by_zero(self):
        self.assertIsNone(self.ratio(9.0, "0.0", 0.0))

    # A phase named after its scenario would otherwise say so twice.
    def test_a_phase_named_after_its_scenario_is_not_named_twice(self):
        finding = self.ratio(9.0, "3.0", 0.0, phase="map")
        self.assertNotIn(" in `map`,", finding.single)
        finding = self.ratio(9.0, "3.0", 0.0, phase="scrub")
        self.assertIn(" in `scrub`", finding.single)

    # End to end: the transitions come off the scenario's own counters, so a
    # phase that reported them is charged for them.
    def test_the_transition_count_comes_from_the_scenarios_own_counter(self):
        subject = scenario(
            "background-recording",
            counts=[
                ("background-recording", "ScenePhaseChanged", 4.0, "1.3333333333333333"),
                ("background-recording", "MapSheetBody", 4.0, "1.3333333333333333"),
                ("background-recording", "MapSheetHikesBody", 9.0, "3.0"),
            ],
        )
        found = {finding.key for finding in report.scenario_findings(subject)}
        self.assertNotIn(("body-per-fix", "MapSheetBody"), found)
        self.assertIn(("body-per-fix", "MapSheetHikesBody"), found)

    # `Process` ticks every second for the length of a scenario, and
    # `Footprint.MB` and `CPU.s` are gauges riding in the same tally — so
    # counting them as work flagged every scenario longer than two seconds,
    # permanently, whatever the app was doing.
    def test_the_samplers_own_counters_are_not_idle_findings(self):
        subject = scenario(
            "idle",
            counts=[
                ("idle", "Process", 51.0, ""),
                ("idle", "Footprint.MB", 128.0, ""),
                ("idle", "CPU.s", 3.0, ""),
            ],
        )
        self.assertEqual(report.scenario_findings(subject), [])

    def test_a_body_that_repeats_while_idle_is_a_finding(self):
        subject = scenario("idle", counts=[("idle", "MapSheetBody", 3.0, "")])
        (finding,) = report.scenario_findings(subject)
        self.assertEqual(finding.key, ("idle", "MapSheetBody"))
        self.assertEqual(finding.measure, "3 times")

    # The floor is what stops the list leading with a body that ran twice.
    def test_a_body_at_the_noise_floor_is_not_a_finding(self):
        subject = scenario(
            "idle", counts=[("idle", "MapSheetBody", float(report.NOISE_FLOOR), "")]
        )
        self.assertEqual(report.scenario_findings(subject), [])

    # A frame budget is a claim about a frame. `PhotoImageDecoded` is
    # `@concurrent` and `TileUnclaimedSweep` sits below an `assertOffMainThread`
    # that would crash this very build; both were reported for months.
    def test_only_main_thread_intervals_can_miss_a_frame(self):
        subject = scenario(
            "photo-gallery",
            events=[
                interval("PhotoImageDecoded", 67.0, "thread=off-main"),
                interval("TileUnclaimedSweep", 43.8, "thread=off-main"),
                interval("ModelContainerInit", 40.2, "thread=main"),
            ],
        )
        over = {
            finding.key for finding in report.scenario_findings(subject)
            if finding.key[0] == "over-frame"
        }
        self.assertEqual(over, {("over-frame", "ModelContainerInit")})

    # An event file written by a build older than the thread stamp should keep
    # flagging what it used to.
    def test_an_interval_with_no_thread_stamp_is_read_as_main(self):
        subject = scenario("legacy", events=[interval("AppModelInit", 40.0)])
        (finding,) = report.scenario_findings(subject)
        self.assertEqual(finding.key, ("over-frame", "AppModelInit"))
        self.assertEqual(finding.measure, "40.0 ms")

    def test_an_interval_inside_the_frame_budget_is_not_a_finding(self):
        subject = scenario(
            "map", events=[interval("MapOverlayApply", report.FRAME_BUDGET_MS)]
        )
        self.assertEqual(report.scenario_findings(subject), [])

    # The worst of a name's intervals is the one worth reporting, not the last.
    def test_the_longest_interval_of_a_name_is_the_one_reported(self):
        subject = scenario(
            "map",
            events=[
                interval("MapOverlayApply", 40.0, elapsed=1.0),
                interval("MapOverlayApply", 18.0, elapsed=2.0),
            ],
        )
        (finding,) = report.scenario_findings(subject)
        self.assertEqual(finding.measure, "40.0 ms")

    def test_a_stall_is_reported_with_the_time_it_held(self):
        subject = scenario(
            "recording",
            events=[
                report.Event(
                    elapsed=3.0, epoch=1003.0, kind="stall",
                    name="MainThreadStall", value=212.0, detail="",
                )
            ],
        )
        (finding,) = report.scenario_findings(subject)
        self.assertEqual(finding.key, ("stall",))
        self.assertEqual(finding.measure, "212 ms")

    def test_a_run_with_nothing_to_report_says_so(self):
        self.assertEqual(
            report.findings({"idle": scenario("idle")}),
            ["Nothing exceeded a reporting threshold."],
        )


if __name__ == "__main__":
    unittest.main()
