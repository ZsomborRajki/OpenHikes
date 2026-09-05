"""The battery-shaped findings, and the two streams they must not confuse.

Energy regressions look like nothing in a frame count, so these are the only
rules that would catch a radio waking on a schedule or a filter throwing away
the fixes the GPS was kept awake to deliver. Both have reported confident
nonsense before, by dividing one `CLLocationManager`'s numbers by another's.
"""

from __future__ import annotations

import unittest

from loader import load

report = load("perf-report.py")


def mark(name: str, elapsed: float = 1.0, detail: str = "") -> object:
    return report.Event(
        elapsed=elapsed, epoch=1000 + elapsed, kind="mark",
        name=name, value=None, detail=detail,
    )


def marks(name: str, count: int) -> list:
    return [mark(name, elapsed=1.0 + index / 10) for index in range(count)]


def fetch(elapsed: float, milliseconds: float = 100.0) -> object:
    return report.Event(
        elapsed=elapsed, epoch=1000 + elapsed, kind="interval",
        name="TileNetworkFetch", value=milliseconds, detail="thread=off-main",
    )


def scenario(name: str, events) -> object:
    return report.Scenario(name, events=list(events))


class EnergyFindingTests(unittest.TestCase):
    def keys(self, subject) -> set:
        return {finding.key for finding in report.energy_findings(subject)}

    def test_a_scenario_claiming_to_be_offline_reports_every_connection(self):
        (finding,) = [
            found for found in report.energy_findings(scenario("offline-browse", [fetch(1.0)]))
            if found.key == ("offline-connection",)
        ]
        self.assertEqual(finding.measure, "1 connection(s)")

    def test_a_scenario_that_never_claimed_to_be_offline_may_fetch(self):
        self.assertNotIn(("offline-connection",), self.keys(scenario("map-browse", [fetch(1.0)])))

    # Deliberately not "requests per accepted fix": that ratio charged the
    # tiles a foreground map loads at launch against the three fixes a short
    # scenario accepts, and reported 52.2 for a recording that woke the radio
    # zero times once it was in a pocket.
    def test_a_foreground_fetch_is_not_a_battery_finding(self):
        subject = scenario("recording", [mark("ScenePhaseChanged", 1.0, "active"), fetch(1.5)])
        self.assertEqual(self.keys(subject), set())

    def test_a_fetch_inside_the_pocket_is_counted_once_each(self):
        subject = scenario(
            "background-recording",
            [mark("ScenePhaseChanged", 1.0, "background"), fetch(1.5), fetch(1.8),
             mark("ScenePhaseChanged", 2.0, "inactive")],
        )
        (finding,) = [
            found for found in report.energy_findings(subject)
            if found.key == ("radio-backgrounded",)
        ]
        self.assertEqual(finding.measure, "2 time(s)")

    # Both counts off the recorder's own manager. `LocationFixDelivered` is the
    # map's, and dividing one stream's rejections by another's deliveries read
    # 50% for a recording that in fact kept four of the five fixes it was
    # handed — and rose as the denominator shrank.
    def test_the_rejection_rate_is_read_off_the_recorders_own_stream(self):
        subject = scenario(
            "recording",
            marks("LocationFixDelivered", 2)
            + marks("RecordingFixReceived", 5)
            + marks("RecordingFixRejected", 1),
        )
        self.assertNotIn(("rejection-rate",), self.keys(subject))

    def test_throwing_away_most_of_the_fixes_is_a_finding(self):
        subject = scenario(
            "recording",
            marks("RecordingFixReceived", 5) + marks("RecordingFixRejected", 4),
        )
        (finding,) = [
            found for found in report.energy_findings(subject)
            if found.key == ("rejection-rate",)
        ]
        self.assertEqual(finding.measure, "80% rejected")

    # Half is the budget, not a violation of it.
    def test_rejecting_exactly_half_is_not_a_finding(self):
        subject = scenario(
            "recording",
            marks("RecordingFixReceived", 4) + marks("RecordingFixRejected", 2),
        )
        self.assertNotIn(("rejection-rate",), self.keys(subject))

    def test_a_recording_that_received_nothing_is_not_divided_by_zero(self):
        subject = scenario("recording", marks("RecordingFixRejected", 3))
        self.assertNotIn(("rejection-rate",), self.keys(subject))

    # A funnel can only narrow: every fix at a stage came through the one
    # before it. A report that widens is two managers being read as one stream,
    # which is how this report claimed five fixes reached the recorder out of
    # three CoreLocation ever delivered.
    def test_a_funnel_that_widened_says_so(self):
        subject = scenario(
            "recording",
            marks("RecordingFixDelivered", 3) + marks("RecordingFixReceived", 5),
        )
        (finding,) = report.widening_funnels(subject)
        self.assertEqual(
            finding.key, ("widening-funnel", "recording (`SystemRecordingLocationSource`)",
                          "RecordingFixReceived")
        )

    def test_a_funnel_that_narrows_is_not_a_finding(self):
        subject = scenario(
            "recording",
            marks("RecordingFixDelivered", 5)
            + marks("RecordingFixReceived", 5)
            + marks("LiveFixAccepted", 4),
        )
        self.assertEqual(report.widening_funnels(subject), [])

    # A rejected fix is the complement of an accepted one, not a narrowing of
    # it, so it is allowed to outnumber the stage above it.
    def test_a_branch_off_the_funnel_is_not_a_widening(self):
        subject = scenario(
            "recording",
            marks("RecordingFixDelivered", 5)
            + marks("RecordingFixReceived", 5)
            + marks("LiveFixAccepted", 1)
            + marks("RecordingFixRejected", 4),
        )
        self.assertEqual(report.widening_funnels(subject), [])

    # Each source narrows on its own; the map's numbers are not the recorder's.
    def test_two_managers_are_not_one_funnel(self):
        subject = scenario(
            "recording",
            marks("LocationFixDelivered", 1)
            + marks("LocationPublished", 1)
            + marks("RecordingFixDelivered", 5)
            + marks("RecordingFixReceived", 5),
        )
        self.assertEqual(report.widening_funnels(subject), [])


if __name__ == "__main__":
    unittest.main()
