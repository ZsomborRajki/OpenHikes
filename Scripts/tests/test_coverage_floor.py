"""The gate that can fail a merge on a number nothing else checks.

`Scripts/check-coverage-floor.py` reads a report produced by a tool this suite
cannot run, so what is asserted here is the decision it makes about that
report: which target it measured, what it publishes, and when it says no.
"""

from __future__ import annotations

import unittest

from loader import load

gate = load("check-coverage-floor.py")


def report(targets) -> dict:
    return {"targets": list(targets)}


def target(name: str, coverage: float, covered: int = 100, executable: int = 200) -> dict:
    return {
        "name": name,
        "lineCoverage": coverage,
        "coveredLines": covered,
        "executableLines": executable,
    }


class CoverageFloorTests(unittest.TestCase):
    def verdict(self, targets, floor=55.0):
        return gate.verdict(report(targets), "OpenHikes.app", floor, "OpenHikesTests")

    def test_coverage_above_the_floor_passes_and_publishes_what_it_measured(self):
        line, failure = self.verdict([target("OpenHikes.app", 0.5742, 5742, 10000)])
        self.assertIsNone(failure)
        self.assertEqual(
            line,
            "`OpenHikes.app` line coverage **57.42%**, at or above the 55.00% floor "
            "(5742/10000 lines), measured over `OpenHikesTests`.",
        )

    # The floor is a floor. Equal to it is not under it.
    def test_coverage_exactly_at_the_floor_passes(self):
        line, failure = self.verdict([target("OpenHikes.app", 0.55)])
        self.assertIsNone(failure)
        self.assertIn("at or above", line)

    # The measured number is worth reading on a failing run too, which is why
    # the line comes back beside the failure rather than instead of it.
    def test_coverage_under_the_floor_fails_and_still_says_what_it_measured(self):
        line, failure = self.verdict([target("OpenHikes.app", 0.4999)])
        self.assertIn("below the 55.00% floor", line)
        self.assertIsNotNone(failure)
        self.assertIn("Coverage fell to 49.99%", failure)
        self.assertIn(".github/workflows/ci.yml", failure)

    # A report with no such target is not zero coverage — it is a report about
    # something else, and the names it did carry are what say which.
    def test_a_renamed_target_is_not_read_as_a_fall(self):
        with self.assertRaises(gate.GateFailure) as raised:
            self.verdict([target("OpenHikesShared", 0.9)])
        self.assertIn("saw OpenHikesShared", str(raised.exception))

    def test_an_uninstrumented_build_says_it_saw_nothing(self):
        with self.assertRaises(gate.GateFailure) as raised:
            self.verdict([])
        self.assertIn("saw nothing", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
