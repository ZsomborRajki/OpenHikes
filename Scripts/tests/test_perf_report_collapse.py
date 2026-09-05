"""One line per distinct finding, however many scenarios saw it.

The suite runs nine scenarios against one app, so a launch cost the whole app
pays was stated nine times and twenty-seven of a thirty-eight-line list were
three facts repeated. A list nobody finishes reading is a list that flags
nothing, which is why this collapse exists and why it has to keep the worst
scenario's own number rather than an average none of them measured.
"""

from __future__ import annotations

import unittest

from loader import load

report = load("perf-report.py")


def finding(scenario: str, magnitude: float, measure: str = "", key=("over-frame", "AppModelInit")):
    return report.Finding(
        key=key,
        scenario=scenario,
        single=f"`{scenario}` spent {magnitude:.1f} ms in `AppModelInit`, over one frame.",
        group="`AppModelInit` held the main thread over one frame",
        magnitude=magnitude,
        measure=measure,
    )


class CollapseTests(unittest.TestCase):
    # A finding one scenario saw reads as a sentence about that scenario, not
    # as a group of one.
    def test_a_finding_only_one_scenario_saw_is_stated_as_itself(self):
        self.assertEqual(
            report.collapse([finding("settings", 40.2, "40.2 ms")]),
            ["`settings` spent 40.2 ms in `AppModelInit`, over one frame."],
        )

    def test_a_finding_two_scenarios_share_is_stated_once(self):
        lines = report.collapse(
            [finding("photo-gallery", 40.2, "40.2 ms"), finding("settings", 43.8, "43.8 ms")]
        )
        self.assertEqual(
            lines,
            [
                (
                    "`AppModelInit` held the main thread over one frame in 2 scenarios "
                    "— worst 43.8 ms in `settings`."
                )
            ],
        )

    # Only when a scenario saw it more than once, so the common case reads "in
    # 9 scenarios" rather than "9 times in 9 scenarios".
    def test_one_sighting_per_scenario_is_not_counted_out_loud(self):
        (line,) = report.collapse([finding("photo-gallery", 40.2), finding("settings", 43.8)])
        self.assertNotIn("2 times", line)

    def test_a_scenario_that_saw_it_twice_says_how_often(self):
        (line,) = report.collapse([finding("settings", 40.2), finding("settings", 43.8)])
        self.assertIn(" 2 times in `settings`", line)

    # Naming the scenario twice is what "in `settings` … in `settings`" would
    # do, so the worst-scenario tail is only for a group of scenarios.
    def test_one_scenario_is_not_named_twice(self):
        (line,) = report.collapse(
            [finding("settings", 40.2, "40.2 ms"), finding("settings", 43.8, "43.8 ms")]
        )
        self.assertEqual(line.count("`settings`"), 1)
        self.assertIn("— worst 43.8 ms.", line)

    def test_a_finding_with_no_measure_ends_at_the_scenarios(self):
        (line,) = report.collapse([finding("a", 1.0), finding("b", 2.0)])
        self.assertTrue(line.endswith("in 2 scenarios."), line)

    def test_two_different_findings_stay_two_lines(self):
        lines = report.collapse(
            [
                finding("settings", 40.2, "40.2 ms"),
                finding("settings", 212.0, "212 ms", key=("stall",)),
            ]
        )
        self.assertEqual(len(lines), 2)


if __name__ == "__main__":
    unittest.main()
