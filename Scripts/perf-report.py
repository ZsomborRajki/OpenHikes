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
# What the sampler says about itself rather than about the app. `Process` is
# the 1 Hz resource sample's own event, emitted for the length of a scenario,
# so counting it as work the app did while idle flagged every scenario longer
# than two seconds, permanently, whatever the app was doing. `Footprint.MB` and
# `CPU.s` are worse than a miscount: they are gauges that ride along in the
# same tally, so their "count" is a number of megabytes and a number of
# seconds. `PerformanceCounters.isEquivalent(to:)` excludes the same three, for
# the same reason.
SAMPLER_COUNTERS = frozenset({"Process", "Footprint.MB", "CPU.s"})
# One frame at 60 Hz. An interval longer than this cost the app a frame it owed
# the screen — but only if it ran on the main thread, which is why the rule
# reads the thread `RenderSignpost` stamps on every interval it records.
FRAME_BUDGET_MS = 16.0
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

    @property
    def duration(self) -> float:
        """How long it ran, in the same seconds ``elapsed`` is stamped in.

        ``elapsed`` is when the event was *recorded*, which for an interval is
        when it finished — so `elapsed - duration` is where it started. A mark
        is a point and has no length, whatever a `value` on it happens to mean.
        """
        return (self.value or 0.0) / 1000 if self.kind == "interval" else 0.0


@dataclass
class Scenario:
    name: str
    events: list[Event] = field(default_factory=list)
    phases: list[Phase] = field(default_factory=list)
    counts: list[tuple[str, str, float, str]] = field(default_factory=list)


@dataclass(frozen=True)
class Finding:
    """One line of the findings list, and what it takes to say it once.

    Every finding is made about a scenario, and the suite runs nine of them
    against one app — so a launch cost the whole app pays was stated nine
    times, and twenty-seven lines of a thirty-eight-line list were three facts
    repeated. ``key`` is what lets two scenarios' identical finding collapse
    into one line, ``group`` is how that line reads with no scenario in it, and
    ``measure`` keeps the worst scenario's own number in it rather than
    averaging the scenarios into a figure none of them measured.
    """

    key: tuple[str, ...]
    scenario: str
    single: str
    group: str
    magnitude: float = 0.0
    measure: str = ""


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
#
# One funnel per `CLLocationManager`, because the app runs three of them and
# they neither share fixes nor cost the same. Counting them into a single
# funnel produced tables that *widened* — more fixes reaching the recorder than
# CoreLocation ever delivered — because the delivery was counted on the map's
# manager and the acceptance on the recorder's. A stage is only ever comparable
# against the stream it came from, so each source narrows on its own.
# Each step is ``(signpost, description, narrows)``. ``narrows`` marks the
# steps that must not exceed the step above them — the funnel proper. A step
# with ``False`` is a branch off the stage before it, not a stage of its own:
# a rejected fix is the complement of an accepted one, not a narrowing of it.
LOCATION_FUNNELS = (
    (
        "map (`LocationManager`)",
        (
            ("LocationFixDelivered", "CoreLocation delivered", True),
            ("LocationPublished", "published to the app", True),
        ),
    ),
    (
        "recording (`SystemRecordingLocationSource`)",
        (
            ("RecordingFixDelivered", "CoreLocation delivered", True),
            ("RecordingFixReceived", "reached a live recording", True),
            ("LiveFixAccepted", "accepted into the route", True),
            ("RecordingFixRejected", "rejected by policy", False),
        ),
    ),
    (
        "background (`BackgroundTrailTracker`)",
        (
            ("BackgroundFixDelivered", "CoreLocation delivered", True),
            ("BackgroundFixMatched", "matched against the trail", True),
        ),
    ),
)


def backgrounded_windows(events: list[Event]) -> list[tuple[float, float]]:
    """The spans the app spent backgrounded, from its own scene-phase marks.

    Worth separating because a request is not equally expensive wherever it
    lands. A tile fetched while the walker is looking at the map is the app
    doing its job; the same fetch with the phone in a pocket is a radio woken
    for output nobody can see, and it is the second one that decides whether
    the battery lasts the walk.

    The window closes on the **first phase mark that is not `background`**,
    which is `inactive` and not `active`: a scene coming back runs
    `background → inactive → active`, and it is already on its way onto the
    screen for the whole of that middle leg. Closing on `active` charged the
    return to the pocket, which is how a run reported eighteen radio wake-ups
    "nothing could see" for eighteen tiles fetched as the app came forward —
    every one of them after the app had left `.background`, and none at all
    inside it.
    """
    windows: list[tuple[float, float]] = []
    opened: float | None = None
    for event in events:
        if event.name != "ScenePhaseChanged":
            continue
        phase = (event.detail or "").strip()
        if phase == "background":
            if opened is None:
                opened = event.elapsed
        elif opened is not None:
            windows.append((opened, event.elapsed))
            opened = None
    if opened is not None:
        windows.append((opened, events[-1].elapsed))
    return windows


def count_within(windows: list[tuple[float, float]], events: list[Event]) -> int:
    """How many of `events` overlapped a window, by span rather than by end.

    ``PerformanceLog`` stamps an interval when it *finishes*, so comparing that
    one timestamp against a window asks "did it end in a pocket?" when the
    question is "was the radio on in one". A 122 ms fetch begun in the
    foreground and landing 20 ms after the screen went dark counted as wholly
    backgrounded; one begun in a pocket and answered after the walker looked
    again counted as nothing at all. A mark has no duration and is unaffected.
    """
    return sum(
        1
        for event in events
        if any(
            start <= event.elapsed and event.elapsed - event.duration <= end
            for start, end in windows
        )
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

    for source, steps in LOCATION_FUNNELS:
        funnel = []
        for name, description, _ in steps:
            count = sum(1 for event in events if event.name == name)
            if count:
                funnel.append([description, f"`{name}`", str(count)])
        if funnel:
            lines.extend([f"**Location funnel — {source}**", ""])
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
    """Everything worth a look, said once each.

    Two rules shaped this list after a run produced thirty-eight lines of which
    three were news. A finding has to be about the app rather than about the
    instrument that recorded it — the sampler's own event, the scene transition
    a phase pays at its edges, and a decode deliberately kept off the main
    thread are all things this list used to report as regressions. And a fact
    the whole app shares gets one line however many scenarios observed it,
    because a list nobody finishes reading is a list that flags nothing.
    """
    collected: list[Finding] = []
    for scenario in scenarios.values():
        collected.extend(scenario_findings(scenario))
    return collapse(collected) or ["Nothing exceeded a reporting threshold."]


def collapse(collected: list[Finding]) -> list[str]:
    """One line per distinct finding, naming the scenarios that saw it."""
    grouped: dict[tuple[str, ...], list[Finding]] = defaultdict(list)
    for finding in collected:
        grouped[finding.key].append(finding)

    lines: list[str] = []
    for items in grouped.values():
        if len(items) == 1:
            lines.append(items[0].single)
            continue
        scenarios = list(dict.fromkeys(item.scenario for item in items))
        where = (
            f"{len(scenarios)} scenarios" if len(scenarios) > 1 else f"`{scenarios[0]}`"
        )
        # Only when a scenario saw it more than once, so the common case reads
        # "in 9 scenarios" rather than "9 times in 9 scenarios".
        repeats = "" if len(items) == len(scenarios) else f" {len(items)} times"
        worst = max(items, key=lambda item: item.magnitude)
        tail = ""
        if worst.measure:
            tail = f" — worst {worst.measure}"
            if len(scenarios) > 1:
                tail += f" in `{worst.scenario}`"
        lines.append(f"{items[0].group}{repeats} in {where}{tail}.")
    return lines


def scenario_findings(scenario: Scenario) -> list[Finding]:
    collected: list[Finding] = []
    transitions = {
        phase: count
        for phase, name, count, _ in scenario.counts
        if name == "ScenePhaseChanged"
    }
    for phase, name, count, ratio in scenario.counts:
        if name in SAMPLER_COUNTERS:
            continue
        if phase == "idle" and count > NOISE_FLOOR:
            collected.append(
                Finding(
                    key=("idle", name),
                    scenario=scenario.name,
                    single=f"`{scenario.name}` ran `{name}` {count:g} times while idle.",
                    group=f"`{name}` ran while idle",
                    magnitude=count,
                    measure=f"{count:g} times",
                )
            )
        if (
            finding := body_ratio_finding(
                scenario, phase, name, count, ratio, transitions.get(phase, 0.0)
            )
        ) is not None:
            collected.append(finding)

    for stall in (event for event in scenario.events if event.kind == "stall"):
        collected.append(
            Finding(
                key=("stall",),
                scenario=scenario.name,
                single=(
                    f"`{scenario.name}` stalled the main thread for {stall.value:.0f} ms."
                ),
                group="the main thread stalled",
                magnitude=stall.value or 0.0,
                measure=f"{stall.value:.0f} ms",
            )
        )

    # Only the intervals that ran on the main thread: a frame budget is a claim
    # about the frame, and work moved off it deliberately cannot miss one.
    # `PhotoImageDecoded` (a `@concurrent` function) and `TileUnclaimedSweep`
    # (below an `assertOffMainThread` that would crash this very build) were
    # reported here for months, in the same undifferentiated list as
    # `ModelContainerInit` and `AppModelInit` — which are on the main thread,
    # are the app's largest documented cost, and are the reason this rule
    # exists. An interval with no stamp is read as main: an event file written
    # by a build older than the stamp should keep flagging what it used to.
    intervals: dict[str, list[float]] = defaultdict(list)
    for event in scenario.events:
        if event.kind != "interval" or event.value is None:
            continue
        if detail_fields(event.detail).get("thread", "main") != "main":
            continue
        intervals[event.name].append(event.value)
    for name, values in intervals.items():
        if max(values) > FRAME_BUDGET_MS:
            collected.append(
                Finding(
                    key=("over-frame", name),
                    scenario=scenario.name,
                    single=(
                        f"`{scenario.name}` spent {max(values):.1f} ms in `{name}`, "
                        "over one frame."
                    ),
                    group=f"`{name}` held the main thread over one frame",
                    magnitude=max(values),
                    measure=f"{max(values):.1f} ms",
                )
            )

    collected.extend(energy_findings(scenario))
    return collected


def body_ratio_finding(
    scenario: Scenario,
    phase: str,
    name: str,
    count: float,
    ratio: str,
    transitions: float,
) -> Finding | None:
    """The body evaluations the accepted fixes are actually answerable for.

    Dividing a phase's whole body count by the fixes it accepted charges the
    scene-phase transitions at the phase's *edges* against the fixes inside it.
    Backgrounding and re-foregrounding redraw the tree once each and always
    will, so `background-recording` — which ran zero bodies of any kind between
    its three fixes, which is exactly the behaviour the scenario exists to
    defend — reported 1.33 evaluations per fix for four separate views. That is
    the same error the network side already deprecated as "requests per
    accepted fix" (see ``energy_findings``), with the same cause.

    What is left after the transitions is the part a fix paid for, which is
    also what `testBackgroundRecordingCostsNothingPerFix` asserts. The fix
    count is not in the counter line, but it divides out of it: the ratio the
    suite printed is this count over it.
    """
    if not name.endswith("Body") or not ratio:
        return None
    try:
        per_fix = float(ratio)
    except ValueError:
        return None
    fixes = count / per_fix if per_fix > 0 else 0.0
    attributable = count - transitions
    if fixes <= 0 or attributable <= 0:
        return None
    adjusted = attributable / fixes
    if adjusted <= 1.0:
        return None
    # A phase named after its scenario would otherwise say so twice.
    where = "" if phase == scenario.name else f" in `{phase}`"
    return Finding(
        key=("body-per-fix", name),
        scenario=scenario.name,
        single=(
            f"`{scenario.name}` re-evaluated `{name}` {adjusted:.2f}× per accepted fix"
            f"{where}, beyond the {transitions:g} scene transition(s) it paid at "
            "the edges."
        ),
        group=f"`{name}` re-evaluated more than once per accepted fix",
        magnitude=adjusted,
        measure=f"{adjusted:.2f}×",
    )


def widening_funnels(scenario: Scenario) -> list[Finding]:
    """Funnels where a stage counted more fixes than the stage above it.

    A funnel can only narrow: every fix at a stage came through the one before
    it. A report that widens is therefore never news about the GPS — it is two
    `CLLocationManager`s being read as one stream, which is exactly how this
    report spent months claiming five fixes reached the recorder out of three
    CoreLocation ever delivered. Said out loud here rather than left for a
    reader to notice, because nobody did.
    """
    collected: list[Finding] = []
    for source, steps in LOCATION_FUNNELS:
        previous: tuple[str, int] | None = None
        for name, _, narrows in steps:
            count = sum(1 for event in scenario.events if event.name == name)
            if not narrows:
                continue
            if previous and count > previous[1]:
                collected.append(
                    Finding(
                        key=("widening-funnel", source, name),
                        scenario=scenario.name,
                        single=(
                            f"`{scenario.name}`'s {source} funnel widened: "
                            f"`{name}` counted {count} against `{previous[0]}`'s "
                            f"{previous[1]} — a stage is being counted on a stream it "
                            "did not come from."
                        ),
                        group=(
                            f"the {source} funnel widened at `{name}` — a stage is "
                            "being counted on a stream it did not come from"
                        ),
                    )
                )
            previous = (name, count)
    return collected


def energy_findings(scenario: Scenario) -> list[Finding]:
    """The battery-shaped regressions, which look like nothing in a frame count.

    A radio that wakes on a schedule and a GPS that never steps down cost a
    hike its afternoon without ever dropping a frame, so neither shows up in
    the counters above. These are the shapes worth a look.
    """
    collected: list[Finding] = []
    network = [
        event
        for event in scenario.events
        if event.name in NETWORK_SIGNPOSTS and event.kind == "interval"
    ]
    if "offline" in scenario.name and network:
        collected.append(
            Finding(
                key=("offline-connection",),
                scenario=scenario.name,
                single=(
                    f"`{scenario.name}` opened {len(network)} connection(s) in a "
                    "scenario that claims to be offline."
                ),
                group="a scenario that claims to be offline opened a connection",
                magnitude=len(network),
                measure=f"{len(network)} connection(s)",
            )
        )
    # Deliberately not "requests per accepted fix". That ratio charges the
    # tiles a foreground map loads at launch against the handful of fixes a
    # short scenario accepts, and reported 52 requests per fix for a recording
    # that in fact woke the radio zero times once it was in a pocket. What is
    # worth flagging is the backgrounded case, because nobody is waiting for
    # any of it.
    pocket = backgrounded_windows(scenario.events)
    if woken := count_within(pocket, network):
        collected.append(
            Finding(
                key=("radio-backgrounded",),
                scenario=scenario.name,
                single=(
                    f"`{scenario.name}` woke the radio {woken} time(s) while "
                    "backgrounded — nothing it fetched could be seen."
                ),
                group="the radio woke while backgrounded — nothing it fetched could be seen",
                magnitude=woken,
                measure=f"{woken} time(s)",
            )
        )
    collected.extend(widening_funnels(scenario))
    # Both counts off the recorder's own manager. `LocationFixDelivered` is the
    # map's, and dividing one stream's rejections by another's deliveries is a
    # rate about nothing: it read 50% for a recording that in fact kept 4 of
    # the 5 fixes it was handed, and rose as the denominator shrank.
    received = sum(1 for event in scenario.events if event.name == "RecordingFixReceived")
    rejected = sum(1 for event in scenario.events if event.name == "RecordingFixRejected")
    if received and rejected / received > 0.5:
        # Fixes are the expensive part of a recording. Paying for them and
        # then discarding most is the worst of both: full GPS duty, half a
        # route. It means the filter is wrong, not that the walker is slow.
        collected.append(
            Finding(
                key=("rejection-rate",),
                scenario=scenario.name,
                single=(
                    f"`{scenario.name}` rejected {rejected} of {received} fixes that "
                    "reached the recorder — GPS duty paid for, route not recorded."
                ),
                group=(
                    "more than half the fixes that reached the recorder were rejected "
                    "— GPS duty paid for, route not recorded"
                ),
                magnitude=rejected / received,
                measure=f"{100 * rejected / received:.0f}% rejected",
            )
        )
    return collected


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
