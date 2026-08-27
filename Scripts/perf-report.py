#!/usr/bin/env python3
"""Turns a performance UI-test run into a readable report.

Three inputs, because no single one of them sees the whole picture:

* the ``xcodebuild`` log, which carries the ``PERF-PHASE`` and ``PERF-COUNT``
  lines the test prints, plus XCTest's own ``measured […] average:`` metrics;
* the tab-separated event files the app wrote into its container, which are the
  only record of *when* each body ran rather than merely how often;
* the phase boundaries, which are what lets an event in the second be
  attributed to a gesture in the first.

Nothing here decides whether a number is acceptable — the UI test asserts that.
This produces the table a person reads afterwards, and flags the handful of
shapes that are worth a look regardless of whether an assertion tripped.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

MEASURED = re.compile(r"measured \[([^\]]+)\] average: ([0-9.]+), relative standard deviation: ([0-9.]+)%")
TEST_CASE = re.compile(r"Test Case '-\[(\S+) (\S+)\]' (passed|failed)")
# A body that runs at most this often during a phase is not what a report
# should lead with; the interesting entries are the ones that repeat.
NOISE_FLOOR = 2
# Deliberately tight. These counters are exact — an idle app with a map on
# screen evaluates zero bodies, and a chart scrub moves the map a specific
# number of times — so a wide band would let a real regression through while
# looking rigorous. A scenario that genuinely is noisy raises it in its own
# baseline file rather than everyone paying for it.
DEFAULT_TOLERANCE = 0.10


@dataclass
class Phase:
    scenario: str
    name: str
    start: float
    end: float

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)


@dataclass
class Event:
    elapsed: float
    epoch: float
    kind: str
    name: str
    value: float | None
    detail: str


@dataclass
class Scenario:
    name: str
    events: list[Event] = field(default_factory=list)
    phases: list[Phase] = field(default_factory=list)
    counts: list[tuple[str, str, float, str]] = field(default_factory=list)


def parse_build_log(
    path: Path,
) -> tuple[dict[str, Scenario], list[str], dict[str, float], list[str]]:
    scenarios: dict[str, Scenario] = {}
    measurements: list[str] = []
    metrics: dict[str, float] = {}
    results: list[str] = []
    for line in path.read_text(errors="replace").splitlines():
        stripped = line.strip()
        if stripped.startswith("PERF-PHASE\t"):
            _, scenario, name, start, end = stripped.split("\t")
            scenarios.setdefault(scenario, Scenario(scenario)).phases.append(
                Phase(scenario, name, float(start), float(end))
            )
        elif stripped.startswith("PERF-COUNT\t"):
            # A counter with no per-fix ratio ends in an empty field, which
            # `strip()` has already eaten — pad rather than require it.
            fields = (stripped.split("\t") + [""])[:6]
            _, scenario, phase, name, count, ratio = fields
            scenarios.setdefault(scenario, Scenario(scenario)).counts.append(
                (phase, name, float(count), ratio)
            )
        elif (match := MEASURED.search(stripped)) is not None:
            measurements.append(
                f"{match.group(1)} — average {match.group(2)}, deviation {match.group(3)}%"
            )
            metrics[match.group(1)] = float(match.group(2))
        elif (match := TEST_CASE.search(stripped)) is not None:
            results.append(f"{match.group(2)}: {match.group(3)}")
    return scenarios, measurements, metrics, results


def parse_events(path: Path) -> list[Event]:
    events: list[Event] = []
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        epoch, elapsed, kind, name, value = parts[:5]
        detail = parts[5] if len(parts) > 5 else ""
        try:
            events.append(
                Event(
                    elapsed=float(elapsed),
                    epoch=float(epoch),
                    kind=kind,
                    name=name,
                    value=float(value) if value else None,
                    detail=detail,
                )
            )
        except ValueError:
            continue
    return events


def detail_fields(detail: str) -> dict[str, str]:
    """Splits a ``key=value key=value`` detail string.

    The detail column started life as a single number and grew keys as the log
    learned to record more than one thing per sample. Parsing it positionally
    is how a report silently reads the wrong column after the next addition, so
    everything that reads a detail goes through here.
    """
    fields: dict[str, str] = {}
    for token in detail.split():
        key, separator, value = token.partition("=")
        if separator:
            fields[key] = value
    return fields


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))
    return ordered[index]


def markdown_table(header: list[str], rows: list[list[str]]) -> list[str]:
    if not rows:
        return ["_No data._", ""]
    lines = ["| " + " | ".join(header) + " |"]
    lines.append("|" + "|".join(["---"] * len(header)) + "|")
    for row in rows:
        lines.append("| " + " | ".join(row) + " |")
    lines.append("")
    return lines


def counter_section(scenario: Scenario) -> list[str]:
    grouped: dict[str, list[tuple[str, float, str]]] = defaultdict(list)
    for phase, name, count, ratio in scenario.counts:
        grouped[phase].append((name, count, ratio))
    lines: list[str] = []
    for phase, entries in grouped.items():
        lines.append(f"**Phase `{phase}` — counter deltas**")
        lines.append("")
        rows = [
            [name, f"{count:g}", ratio or "—"]
            for name, count, ratio in sorted(entries, key=lambda item: -item[1])
        ]
        lines.extend(markdown_table(["Signpost", "Count", "Per accepted fix"], rows))
    return lines


def timeline_section(scenario: Scenario) -> list[str]:
    marks: dict[str, list[Event]] = defaultdict(list)
    for event in scenario.events:
        if event.kind in ("mark", "interval"):
            marks[event.name].append(event)
    if not marks:
        return ["_No signpost events were recorded._", ""]

    span = max((event.elapsed for event in scenario.events), default=0.0) or 1.0
    rows = []
    for name, events in sorted(marks.items(), key=lambda item: -len(item[1])):
        durations = [event.value for event in events if event.value is not None]
        rows.append(
            [
                name,
                events[0].kind,
                str(len(events)),
                f"{len(events) / span:.2f}",
                f"{percentile(durations, 0.5):.2f}" if durations else "—",
                f"{max(durations):.2f}" if durations else "—",
            ]
        )
    return markdown_table(
        ["Signpost", "Kind", "Total", "Per second", "Median ms", "Max ms"], rows
    )


def resource_section(scenario: Scenario) -> list[str]:
    samples = [event for event in scenario.events if event.kind == "sample"]
    if not samples:
        return ["_No resource samples were recorded._", ""]
    footprints = [event.value for event in samples if event.value is not None]
    if not footprints:
        return ["_No resource samples were recorded._", ""]
    cpu = []
    for event in samples:
        seconds = detail_fields(event.detail).get("cpu_s")
        if seconds is not None:
            cpu.append(float(seconds))
    span = samples[-1].elapsed - samples[0].elapsed or 1.0
    burned = (cpu[-1] - cpu[0]) if len(cpu) > 1 else 0.0
    rows = [
        ["Footprint at start", f"{footprints[0]:.1f} MB"],
        ["Footprint at end", f"{footprints[-1]:.1f} MB"],
        ["Footprint peak", f"{max(footprints):.1f} MB"],
        ["CPU time consumed", f"{burned:.2f} s over {span:.1f} s"],
        ["Mean CPU utilisation", f"{100 * burned / span:.1f}% of one core"],
    ]
    return markdown_table(["Measure", "Value"], rows)


# The signposts that mean a radio woke up. Nothing else in the app opens a
# connection, so a scenario with none of these on the clock spent its whole run
# on cached bytes — which is the offline claim, stated as a number.
NETWORK_SIGNPOSTS = ("TileNetworkFetch", "WeatherFetch", "TrailGraphFetch")

# The path a GPS reading walks, in order. Each step is a place a fix can be
# dropped; reading them as a funnel is what distinguishes "CoreLocation is
# quiet" from "CoreLocation is loud and we are throwing the results away",
# which cost very different amounts of battery and need opposite fixes.
LOCATION_FUNNEL = (
    ("LocationFixDelivered", "CoreLocation delivered"),
    ("LocationPublished", "published to the app"),
    ("RecordingFixReceived", "reached the recorder"),
    ("LiveFixAccepted", "accepted into the route"),
    ("RecordingFixRejected", "rejected by policy"),
)


def backgrounded_windows(events: list[Event]) -> list[tuple[float, float]]:
    """The spans the app spent backgrounded, from its own scene-phase marks.

    Worth separating because a request is not equally expensive wherever it
    lands. A tile fetched while the walker is looking at the map is the app
    doing its job; the same fetch with the phone in a pocket is a radio woken
    for output nobody can see, and it is the second one that decides whether
    the battery lasts the walk.
    """
    windows: list[tuple[float, float]] = []
    opened: float | None = None
    for event in events:
        if event.name != "ScenePhaseChanged":
            continue
        phase = (event.detail or "").strip()
        if phase == "background" and opened is None:
            opened = event.elapsed
        elif phase == "active" and opened is not None:
            windows.append((opened, event.elapsed))
            opened = None
    if opened is not None:
        windows.append((opened, events[-1].elapsed))
    return windows


def count_within(windows: list[tuple[float, float]], events: list[Event]) -> int:
    return sum(
        1 for event in events if any(start <= event.elapsed <= end for start, end in windows)
    )


def energy_section(scenario: Scenario) -> list[str]:
    """What the scenario cost a battery, as opposed to a frame.

    Energy has no single counter. What it has are four proxies the app can see
    from inside itself — CPU seconds, radio wake-ups, GPS duty, and how often
    the screen was asked to redraw — and this puts them next to each other so
    the expensive one is obvious.
    """
    events = scenario.events
    if not events:
        return ["_No events were recorded._", ""]

    samples = [event for event in events if event.kind == "sample"]
    span = (samples[-1].elapsed - samples[0].elapsed) if len(samples) > 1 else 0.0
    cpu = [
        float(seconds)
        for event in samples
        if (seconds := detail_fields(event.detail).get("cpu_s")) is not None
    ]
    burned = (cpu[-1] - cpu[0]) if len(cpu) > 1 else 0.0

    lines: list[str] = []
    if span > 0:
        # Per hiking hour, because that is the unit the walker experiences.
        # A short scenario extrapolates badly, so the number is labelled as
        # what it is: an extrapolation, not a measurement.
        lines.extend(
            markdown_table(
                ["Energy proxy", "Value"],
                [
                    ["CPU burned", f"{burned:.2f} s over {span:.1f} s"],
                    ["Extrapolated", f"{burned * 3600 / span:.0f} CPU-s per hiking hour"],
                ],
            )
        )

    network = [
        event
        for event in events
        if event.name in NETWORK_SIGNPOSTS and event.kind == "interval"
    ]
    grouped: dict[str, list[float]] = defaultdict(list)
    for event in network:
        grouped[event.name].append(event.value or 0.0)
    lines.append("**Network**")
    lines.append("")
    if grouped:
        lines.extend(
            markdown_table(
                ["Request", "Count", "Total ms", "Max ms"],
                [
                    [name, str(len(values)), f"{sum(values):.0f}", f"{max(values):.0f}"]
                    for name, values in sorted(grouped.items())
                ],
            )
        )
    else:
        lines.extend(["No request left the device. Every byte came from cache.", ""])

    pocket = backgrounded_windows(events)
    if pocket and network:
        # The number that matters to a battery, as opposed to the total: a
        # foreground map load is the app doing what was asked of it, and the
        # same request with the screen off is not.
        woken = count_within(pocket, network)
        lines.extend(
            [
                f"{woken} of {len(network)} requests were made while backgrounded, "
                f"over {sum(end - start for start, end in pocket):.1f} s in a pocket.",
                "",
            ]
        )

    suppressed: dict[str, int] = defaultdict(int)
    for event in events:
        if event.name == "TileFetchSuppressed":
            reason = detail_fields(event.detail).get("reason", event.detail or "unknown")
            suppressed[reason] += 1
    if suppressed:
        lines.extend(["**Fetches the policy refused**", ""])
        lines.extend(
            markdown_table(
                ["Reason", "Count"],
                [[reason, str(count)] for reason, count in sorted(suppressed.items())],
            )
        )

    funnel = []
    for name, description in LOCATION_FUNNEL:
        count = sum(1 for event in events if event.name == name)
        if count:
            funnel.append([description, f"`{name}`", str(count)])
    if funnel:
        lines.extend(["**Location funnel**", ""])
        lines.extend(markdown_table(["Step", "Signpost", "Count"], funnel))

    profiles = [event for event in events if event.name == "RecordingEnergyProfileApplied"]
    if profiles:
        lines.extend(["**GPS reconfigurations**", ""])
        lines.extend(
            markdown_table(
                ["At", "Applied"],
                [[f"{event.elapsed:.2f} s", f"`{event.detail}`"] for event in profiles],
            )
        )

    states = {
        (
            fields.get("lowPower", "?"),
            fields.get("thermal", "?"),
        )
        for event in samples
        if (fields := detail_fields(event.detail))
    }
    if states:
        lines.extend(["**Power state seen during the run**", ""])
        lines.extend(
            markdown_table(
                ["Low Power Mode", "Thermal state"],
                [
                    ["yes" if low == "1" else "no", thermal]
                    for low, thermal in sorted(states)
                ],
            )
        )
    return lines


def stall_section(scenario: Scenario) -> list[str]:
    stalls = [event for event in scenario.events if event.kind == "stall"]
    if not stalls:
        return ["No main-thread stall exceeded the watchdog's 150 ms budget.", ""]
    rows = []
    for stall in stalls:
        phase = next(
            (
                phase.name
                for phase in scenario.phases
                if phase.start <= stall.epoch <= phase.end
            ),
            "outside a measured phase",
        )
        rows.append([f"{stall.elapsed:.2f} s", f"{stall.value:.0f} ms", phase])
    return markdown_table(["At", "Duration", "Phase"], rows)


def findings(scenarios: dict[str, Scenario]) -> list[str]:
    notes: list[str] = []
    for scenario in scenarios.values():
        for phase, name, count, ratio in scenario.counts:
            if phase == "idle" and count > NOISE_FLOOR:
                notes.append(
                    f"`{scenario.name}` ran `{name}` {count:g} times while idle."
                )
            if ratio and float(ratio) > 1.0 and name.endswith("Body"):
                notes.append(
                    f"`{scenario.name}` re-evaluated `{name}` {float(ratio):.2f}× per accepted fix."
                )
        for stall in (event for event in scenario.events if event.kind == "stall"):
            notes.append(
                f"`{scenario.name}` stalled the main thread for {stall.value:.0f} ms."
            )
        intervals: dict[str, list[float]] = defaultdict(list)
        for event in scenario.events:
            if event.kind == "interval" and event.value is not None:
                intervals[event.name].append(event.value)
        for name, values in intervals.items():
            frame_budget_ms = 16.0
            if max(values) > frame_budget_ms:
                notes.append(
                    f"`{scenario.name}` spent {max(values):.1f} ms in `{name}`, over one frame."
                )
        notes.extend(energy_findings(scenario))
    return notes or ["Nothing exceeded a reporting threshold."]


def energy_findings(scenario: Scenario) -> list[str]:
    """The battery-shaped regressions, which look like nothing in a frame count.

    A radio that wakes on a schedule and a GPS that never steps down cost a
    hike its afternoon without ever dropping a frame, so neither shows up in
    the counters above. These are the shapes worth a look.
    """
    notes: list[str] = []
    network = [
        event
        for event in scenario.events
        if event.name in NETWORK_SIGNPOSTS and event.kind == "interval"
    ]
    if "offline" in scenario.name and network:
        notes.append(
            f"`{scenario.name}` opened {len(network)} connection(s) in a scenario that claims to be offline."
        )
    # Deliberately not "requests per accepted fix". That ratio charges the
    # tiles a foreground map loads at launch against the handful of fixes a
    # short scenario accepts, and reported 52 requests per fix for a recording
    # that in fact woke the radio zero times once it was in a pocket. What is
    # worth flagging is the backgrounded case, because nobody is waiting for
    # any of it.
    pocket = backgrounded_windows(scenario.events)
    if woken := count_within(pocket, network):
        notes.append(
            f"`{scenario.name}` woke the radio {woken} time(s) while backgrounded — "
            "nothing it fetched could be seen."
        )
    delivered = sum(1 for event in scenario.events if event.name == "LocationFixDelivered")
    rejected = sum(1 for event in scenario.events if event.name == "RecordingFixRejected")
    if delivered and rejected / delivered > 0.5:
        # Fixes are the expensive part of a recording. Paying for them and
        # then discarding most is the worst of both: full GPS duty, half a
        # route. It means the filter is wrong, not that the walker is slow.
        notes.append(
            f"`{scenario.name}` rejected {rejected} of {delivered} delivered fixes — "
            "GPS duty paid for, route not recorded."
        )
    return notes


def baseline_snapshot(
    scenarios: dict[str, Scenario], metrics: dict[str, float]
) -> dict:
    """This run's numbers, in the shape ``--baseline`` reads back.

    Only the counters and the XCTest metrics: they are the two things that are
    exact, repeatable and already hand-copied into ``PERFORMANCE.md``. The
    timelines and resource samples are deliberately left out — a footprint
    reading taken under XCUITest is automation overhead rather than the app's,
    and comparing one across runs would produce confident nonsense.
    """
    counters: dict[str, dict[str, dict[str, float]]] = {}
    for name in sorted(scenarios):
        for phase, counter, count, _ in scenarios[name].counts:
            counters.setdefault(name, {}).setdefault(phase, {})[counter] = count
    return {
        "tolerance": DEFAULT_TOLERANCE,
        "counters": counters,
        "metrics": metrics,
    }


def compare_to_baseline(
    baseline: dict, scenarios: dict[str, Scenario], metrics: dict[str, float]
) -> list[str]:
    """Every way this run disagrees with the baseline, in both directions.

    Growth is the obvious regression. A *fall* is reported just as loudly,
    because a suite made entirely of upper bounds cannot notice work that has
    stopped: extracting the 1 Hz recording clock into a view that stored the
    recorder once made the view structurally identical on every tick, so
    SwiftUI skipped its body and the clock silently froze — scoring perfectly
    against every budget in the suite. A counter that reaches zero gets its own
    line, because that is what that failure looks like from here.

    Nothing in this function decides whether the run is acceptable; it decides
    what changed. ``--fail-on-regression`` is where a caller opts into an
    opinion.
    """
    tolerance = float(baseline.get("tolerance", DEFAULT_TOLERANCE))
    expected_counters = baseline.get("counters", {})
    notes: list[str] = []

    for name in sorted(scenarios):
        for phase, counter, count, _ in scenarios[name].counts:
            before = expected_counters.get(name, {}).get(phase, {}).get(counter)
            if before is None:
                notes.append(
                    f"`{name}` · `{phase}` · `{counter}` is new — {count:g}, no baseline."
                )
                continue
            where = f"`{name}` · `{phase}` · `{counter}`"
            if count > before * (1 + tolerance) and count > before:
                notes.append(f"{where} rose {before:g} → {count:g}.")
            elif before > 0 and count == 0:
                notes.append(
                    f"{where} fell {before:g} → 0 — the work stopped happening, "
                    "which no upper bound would catch."
                )
            elif count < before * (1 - tolerance):
                notes.append(f"{where} fell {before:g} → {count:g}.")

    measured = {(name, phase, counter) for name in scenarios
                for phase, counter, _, _ in scenarios[name].counts}
    for name, phases in sorted(expected_counters.items()):
        for phase, counters in sorted(phases.items()):
            for counter, before in sorted(counters.items()):
                if (name, phase, counter) not in measured:
                    notes.append(
                        f"`{name}` · `{phase}` · `{counter}` was not reported at all "
                        f"this run — baseline had {before:g}. A counter the runner "
                        "cannot find is a counter that passes."
                    )

    for metric, before in sorted(baseline.get("metrics", {}).items()):
        now = metrics.get(metric)
        if now is None:
            notes.append(f"`{metric}` was not measured this run — baseline {before:g}.")
        elif now > before * (1 + tolerance):
            notes.append(f"`{metric}` rose {before:g} → {now:g}.")
        elif now < before * (1 - tolerance):
            notes.append(f"`{metric}` fell {before:g} → {now:g}.")
    return notes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True, help="xcodebuild output")
    parser.add_argument("--events", type=Path, required=True, help="directory of .tsv event files")
    parser.add_argument("--out", type=Path, required=True, help="markdown report to write")
    parser.add_argument(
        "--baseline",
        type=Path,
        help="JSON of a previous run's counters to compare against",
    )
    parser.add_argument(
        "--write-baseline",
        type=Path,
        help="write this run's counters as a baseline and exit codes unchanged",
    )
    parser.add_argument(
        "--fail-on-regression",
        action="store_true",
        help="exit non-zero when the run disagrees with --baseline",
    )
    args = parser.parse_args()

    scenarios, measurements, metrics, results = parse_build_log(args.log)
    if args.events.is_dir():
        for tsv in sorted(args.events.glob("*.tsv")):
            scenario = scenarios.setdefault(tsv.stem, Scenario(tsv.stem))
            scenario.events = parse_events(tsv)

    lines = [
        "# OpenHikes performance run",
        "",
        "Generated by `Scripts/run-performance-tests.sh`. Counter deltas come from",
        "the app's live `RenderSignpost` tally read through the accessibility tree;",
        "timelines and resource samples come from `PerformanceLog`'s event file.",
        "",
        "## Test results",
        "",
    ]
    lines.extend(markdown_table(["Test", "Result"], [line.split(": ") for line in results]))

    if measurements:
        lines.extend(["## XCTest metrics", ""])
        lines.extend(markdown_table(["Metric", ""], [[m, ""] for m in measurements]))

    lines.extend(["## Findings", ""])
    lines.extend(f"- {note}" for note in findings(scenarios))
    lines.append("")

    drift: list[str] = []
    if args.baseline is not None:
        if args.baseline.is_file():
            drift = compare_to_baseline(
                json.loads(args.baseline.read_text()), scenarios, metrics
            )
            lines.extend([f"## Against `{args.baseline.name}`", ""])
            lines.extend(
                f"- {note}" for note in drift or ["Every counter matched the baseline."]
            )
            lines.append("")
        else:
            # Loud rather than silent. A baseline the runner cannot find would
            # otherwise read exactly like a run with nothing to report.
            print(f"No baseline at {args.baseline}; skipping comparison.")

    for name in sorted(scenarios):
        scenario = scenarios[name]
        lines.extend([f"## Scenario `{name}`", ""])
        lines.extend(counter_section(scenario))
        lines.extend(["**Whole-run signpost timeline**", ""])
        lines.extend(timeline_section(scenario))
        lines.extend(["**Process resources**", ""])
        lines.extend(resource_section(scenario))
        lines.extend(["**Energy**", ""])
        lines.extend(energy_section(scenario))
        lines.extend(["**Main-thread stalls**", ""])
        lines.extend(stall_section(scenario))

    args.out.write_text("\n".join(lines) + "\n")
    print(f"Wrote {args.out}")

    if args.write_baseline is not None:
        args.write_baseline.write_text(
            json.dumps(baseline_snapshot(scenarios, metrics), indent=2, sort_keys=True)
            + "\n"
        )
        print(f"Wrote {args.write_baseline}")

    if drift and args.fail_on_regression:
        for note in drift:
            print(note)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
