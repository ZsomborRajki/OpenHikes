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
import re
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

MEASURED = re.compile(r"measured \[([^\]]+)\] average: ([0-9.]+), relative standard deviation: ([0-9.]+)%")
TEST_CASE = re.compile(r"Test Case '-\[(\S+) (\S+)\]' (passed|failed)")
# A body that runs at most this often during a phase is not what a report
# should lead with; the interesting entries are the ones that repeat.
NOISE_FLOOR = 2


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


def parse_build_log(path: Path) -> tuple[dict[str, Scenario], list[str], list[str]]:
    scenarios: dict[str, Scenario] = {}
    measurements: list[str] = []
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
        elif (match := TEST_CASE.search(stripped)) is not None:
            results.append(f"{match.group(2)}: {match.group(3)}")
    return scenarios, measurements, results


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
    cpu = []
    for event in samples:
        if event.detail.startswith("cpu_s="):
            cpu.append(float(event.detail.removeprefix("cpu_s=")))
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
    return notes or ["Nothing exceeded a reporting threshold."]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True, help="xcodebuild output")
    parser.add_argument("--events", type=Path, required=True, help="directory of .tsv event files")
    parser.add_argument("--out", type=Path, required=True, help="markdown report to write")
    args = parser.parse_args()

    scenarios, measurements, results = parse_build_log(args.log)
    if args.events.is_dir():
        for tsv in sorted(args.events.glob("*.tsv")):
            scenario = scenarios.setdefault(tsv.stem, Scenario(tsv.stem))
            scenario.events = parse_events(tsv)

    lines = [
        "# OpenTrails performance run",
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

    for name in sorted(scenarios):
        scenario = scenarios[name]
        lines.extend([f"## Scenario `{name}`", ""])
        lines.extend(counter_section(scenario))
        lines.extend(["**Whole-run signpost timeline**", ""])
        lines.extend(timeline_section(scenario))
        lines.extend(["**Process resources**", ""])
        lines.extend(resource_section(scenario))
        lines.extend(["**Main-thread stalls**", ""])
        lines.extend(stall_section(scenario))

    args.out.write_text("\n".join(lines) + "\n")
    print(f"Wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
