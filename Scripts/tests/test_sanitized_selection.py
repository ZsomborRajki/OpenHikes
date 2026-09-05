"""The gate that notices a sanitized suite which silently did not run.

`xcodebuild` never validates an `-only-testing:` identifier: one that resolves
to nothing is dropped without a warning and the run still exits 0. The exit
status cannot see that, so `Scripts/check-sanitized-selection.py` counts what
the result bundle says actually ran — and this asserts it counts the right
things and fails in both directions.
"""

from __future__ import annotations

import unittest

from loader import load

gate = load("check-sanitized-selection.py")


def node(kind: str, name: str, children=()) -> dict:
    return {"nodeType": kind, "name": name, "children": list(children)}


def bundle(*nodes) -> dict:
    return {"testNodes": list(nodes)}


class SanitizedSelectionTests(unittest.TestCase):
    def test_suites_and_tests_are_counted_wherever_they_are_nested(self):
        suites, tests = gate.walk(
            bundle(
                node("Test Plan", "OpenHikes", [
                    node("Unit test bundle", "OpenHikesTests.xctest", [
                        node("Test Suite", "TileCacheTests", [
                            node("Test Case", "testTrimKeepsClaimedTiles()"),
                            node("Test Case", "testTrimRemovesOrphans()"),
                        ]),
                        node("Test Suite", "HikeStoreTests", [
                            node("Test Case", "testSaveIsAtomic()"),
                        ]),
                    ]),
                ])
            )
        )
        self.assertEqual(len(suites), 2)
        self.assertEqual(len(tests), 3)

    # Two suites in different bundles are allowed to share a name, and counting
    # them as one would hide exactly the disappearance this gate is for.
    def test_two_suites_sharing_a_name_are_two_suites(self):
        suites, _ = gate.walk(
            bundle(
                node(
                    "Unit test bundle",
                    "OpenHikesTests.xctest",
                    [node("Test Suite", "StoreTests")],
                ),
                node(
                    "Unit test bundle",
                    "OpenWidgetTests.xctest",
                    [node("Test Suite", "StoreTests")],
                ),
            )
        )
        self.assertEqual(len(set(suites)), 2)

    def test_a_selection_that_ran_as_pinned_passes(self):
        line, failures = gate.verdict(["a", "b"], ["one", "two", "three"], 2, 3)
        self.assertEqual(failures, [])
        self.assertIn("**3 tests**", line)
        self.assertIn("**2 suites**", line)

    # A fall means an identifier stopped matching and its suite was skipped
    # without a word.
    def test_a_suite_that_stopped_resolving_fails_as_a_fall(self):
        _, (failure,) = gate.verdict(["a"], ["one", "two", "three"], 2, 3)
        self.assertIn("fell to 1", failure)

    # A rise means the list grew and the pin did not, and the next fall would
    # be measured against a stale number.
    def test_a_suite_added_without_the_pin_fails_as_a_rise(self):
        _, (failure,) = gate.verdict(["a", "b", "c"], ["one", "two", "three"], 2, 3)
        self.assertIn("rose to 3", failure)

    # Tests are a floor: a suite gaining one must not turn the build red.
    def test_more_tests_than_the_floor_is_not_a_failure(self):
        _, failures = gate.verdict(["a", "b"], ["one", "two", "three", "four"], 2, 3)
        self.assertEqual(failures, [])

    def test_a_suite_emptied_out_under_a_name_that_resolves_fails_on_the_floor(self):
        _, (failure,) = gate.verdict(["a", "b"], ["one"], 2, 3)
        self.assertIn("Only 1 tests ran", failure)

    # Both, when both are wrong: a run that lost a suite and its tests should
    # not have to be fixed twice to find out.
    def test_a_run_that_broke_both_pins_reports_both(self):
        _, failures = gate.verdict([], [], 2, 3)
        self.assertEqual(len(failures), 2)


if __name__ == "__main__":
    unittest.main()
