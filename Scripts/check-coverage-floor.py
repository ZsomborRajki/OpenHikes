#!/usr/bin/env python3
"""Decides whether a run's line coverage cleared the floor CI holds it to.

Reads the JSON `xcrun xccov view --report --json` writes, publishes one line
saying what was measured over which selection, and fails the step when the
number fell under the floor.

The floor, the target and the selection are environment variables rather than
constants here, because the argument for each of them is a comment in
`.github/workflows/ci.yml` next to the value it justifies, and a number that
lives in two places drifts in one of them.

This is a file rather than a heredoc inside that workflow because a program
embedded in YAML is a program no parser ever reads: nothing type-checks it,
nothing lints it, and a syntax error in it surfaces as a failed job on the
pull request that had nothing to do with it. Every other program this
repository runs is checked by `Scripts/run-script-tests.sh` or by the parse
checks in the `quality` job, and this one can fail a merge.

Exit status:
  0  at or above the floor
  1  under the floor, or the report has no such target
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


class GateFailure(Exception):
    """Why the step should fail, phrased for a GitHub annotation."""


def measured_target(report: dict, wanted: str) -> dict:
    """The one target the floor is about.

    A report with no such target is not zero coverage — it is a report about
    something else, which is what a renamed target or an uninstrumented build
    produces. Saying which targets were in it is what makes that difference
    visible from the log alone.
    """
    targets = report.get("targets", [])
    target = next((entry for entry in targets if entry.get("name") == wanted), None)
    if target is None:
        seen = ", ".join(entry.get("name", "?") for entry in targets) or "nothing"
        raise GateFailure(
            f"No {wanted} in the coverage report — saw {seen}. "
            "Either the target was renamed or the build was not instrumented."
        )
    return target


def verdict(
    report: dict, wanted: str, floor: float, selection: str
) -> tuple[str, str | None]:
    """The line to publish, and the failure to report if there is one.

    Both, rather than one or the other: the measured number is worth reading on
    a run that passed, and a failure that swallowed it would leave the log
    saying only that something was too low.
    """
    target = measured_target(report, wanted)
    measured = target["lineCoverage"] * 100
    line = (
        f"`{wanted}` line coverage **{measured:.2f}%**, "
        f"{'below' if measured < floor else 'at or above'} the {floor:.2f}% floor "
        f"({target['coveredLines']}/{target['executableLines']} lines), "
        f"measured over `{selection}`."
    )
    if measured < floor:
        return line, (
            f"Coverage fell to {measured:.2f}%, under the "
            f"{floor:.2f}% floor set in .github/workflows/ci.yml."
        )
    return line, None


def publish(line: str) -> None:
    """Puts the line on the job summary as well as in the log, when there is one."""
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check line coverage against its floor")
    parser.add_argument("report", type=Path, help="xccov --json report")
    args = parser.parse_args()

    try:
        line, failure = verdict(
            json.loads(args.report.read_text()),
            os.environ["COVERAGE_TARGET"],
            float(os.environ["COVERAGE_FLOOR"]),
            os.environ["COVERAGE_SELECTION"],
        )
    except GateFailure as error:
        print(f"::error::{error}")
        return 1

    print(line)
    publish(line)
    if failure is not None:
        print(f"::error::{failure}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
