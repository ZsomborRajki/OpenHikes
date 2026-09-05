"""When the phone was in a pocket, and what ran while it was.

A request is not equally expensive wherever it lands: a tile fetched while the
walker is looking at the map is the app doing its job, and the same fetch with
the screen dark is a radio woken for output nobody can see. Both edges of that
window have already been wrong once — the window closed too late, and the
events inside it were matched by the wrong timestamp — and each mistake
reported wake-ups that never happened.
"""

from __future__ import annotations

import unittest

from loader import load

report = load("perf-report.py")


def phase_mark(elapsed: float, phase: str) -> object:
    return report.Event(
        elapsed=elapsed, epoch=1000 + elapsed, kind="mark",
        name="ScenePhaseChanged", value=None, detail=phase,
    )


def fetch(elapsed: float, milliseconds: float) -> object:
    return report.Event(
        elapsed=elapsed, epoch=1000 + elapsed, kind="interval",
        name="TileNetworkFetch", value=milliseconds, detail="thread=off-main",
    )


class WindowTests(unittest.TestCase):
    # A scene comes back through `background → inactive → active`, and it is
    # already on its way onto the screen for the whole of that middle leg.
    # Closing on `active` charged the return to the pocket: eighteen wake-ups
    # "nothing could see" for eighteen tiles fetched as the app came forward.
    def test_a_window_closes_on_the_first_mark_that_is_not_background(self):
        windows = report.backgrounded_windows(
            [
                phase_mark(1.0, "background"),
                phase_mark(2.0, "inactive"),
                phase_mark(2.5, "active"),
            ]
        )
        self.assertEqual(windows, [(1.0, 2.0)])

    def test_a_second_background_mark_does_not_open_a_second_window(self):
        windows = report.backgrounded_windows(
            [
                phase_mark(1.0, "background"),
                phase_mark(1.5, "background"),
                phase_mark(2.0, "active"),
            ]
        )
        self.assertEqual(windows, [(1.0, 2.0)])

    # A run that ended with the app still backgrounded has a window that never
    # closed; it lasted as long as the recording did.
    def test_a_window_still_open_at_the_end_runs_to_the_last_event(self):
        windows = report.backgrounded_windows([phase_mark(1.0, "background"), fetch(4.0, 100.0)])
        self.assertEqual(windows, [(1.0, 4.0)])

    def test_a_scenario_that_never_backgrounded_has_no_window(self):
        self.assertEqual(report.backgrounded_windows([phase_mark(1.0, "active")]), [])

    # An interval is stamped when it *finishes*, so its one timestamp asks "did
    # it end in a pocket?" when the question is "was the radio on in one".
    def test_a_fetch_that_began_before_the_dark_and_landed_inside_it_counts(self):
        # Began at 1.88, landed at 2.0, and the screen went dark at 1.9.
        self.assertEqual(report.count_within([(1.9, 3.0)], [fetch(2.0, 120.0)]), 1)

    def test_a_fetch_begun_in_the_pocket_and_answered_after_it_counts(self):
        # Began at 2.9, answered at 3.5, and the walker looked again at 3.0.
        self.assertEqual(report.count_within([(1.9, 3.0)], [fetch(3.5, 600.0)]), 1)

    # The returning-scene case: began at 2.08, landed at 2.2, and the window
    # closed at 2.0. Nothing about it happened in the dark.
    def test_a_fetch_wholly_after_the_window_counts_for_nothing(self):
        self.assertEqual(report.count_within([(1.0, 2.0)], [fetch(2.2, 120.0)]), 0)

    def test_a_fetch_wholly_before_the_window_counts_for_nothing(self):
        self.assertEqual(report.count_within([(2.0, 3.0)], [fetch(1.5, 100.0)]), 0)

    def test_a_mark_counts_where_it_was_stamped(self):
        self.assertEqual(report.count_within([(1.0, 2.0)], [phase_mark(1.5, "background")]), 1)
        self.assertEqual(report.count_within([(1.0, 2.0)], [phase_mark(2.5, "active")]), 0)

    def test_an_event_is_counted_once_however_many_windows_it_touches(self):
        self.assertEqual(
            report.count_within([(1.0, 2.0), (1.5, 2.5)], [fetch(1.8, 400.0)]), 1
        )

    def test_nothing_is_inside_no_window(self):
        self.assertEqual(report.count_within([], [fetch(1.5, 100.0)]), 0)


if __name__ == "__main__":
    unittest.main()
