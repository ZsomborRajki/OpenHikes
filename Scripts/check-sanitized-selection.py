#!/usr/bin/env python3
"""Asserts that the ThreadSanitizer job ran the suites it claims to run.

The job passes `xcodebuild` a list of `-only-testing:` identifiers, and
`xcodebuild` never validates them: one that resolves to nothing is dropped
without a warning and the run still exits 0. That is a green job with less
sanitizer coverage than it advertises, and the exit status cannot see it. The
result bundle can, so this counts what actually ran and holds it against the
pins in `.github/workflows/ci.yml`, which is also where the pins are argued
for.

Suites are exact in both directions. A fall means an identifier stopped
matching — renamed, moved into an `extension`, misspelt. A rise means the list
grew without the pin growing with it, and the next fall would then be measured
against a stale number. Tests are a floor, because a suite gaining a test
should not turn a build red.

This is a file rather than a heredoc inside the workflow for the reason
`Scripts/check-coverage-floor.py` gives.

Exit status:
  0  the selection ran as pinned
  1  the suite count moved, or too few tests ran
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def walk(report: dict) -> tuple[list[str], list[str]]:
    """Every suite and every test in the bundle, by their full path.

    Named by path rather than by leaf, because two suites in different bundles
    are allowed to share a name and counting them as one would hide exactly the
    disappearance this gate exists to catch.
    """
    suites: list[str] = []
    tests: list[str] = []

    def visit(node: dict, trail: list[str]) -> None:
        kind = node.get("nodeType")
        name = node.get("name", "?")
        if kind == "Test Suite":
            suites.append("/".join(trail + [name]))
        elif kind == "Test Case":
            tests.append("/".join(trail + [name]))
        for child in node.get("children", []):
            visit(child, trail + [name])

    for node in report.get("testNodes", []):
        visit(node, [])
    return suites, tests


def verdict(
    suites: list[str], tests: list[str], expected_suites: int, test_floor: int
) -> tuple[str, list[str]]:
    """The line to publish, and every reason the step should fail."""
    line = (
        f"ThreadSanitizer ran **{len(tests)} tests** in "
        f"**{len(suites)} suites** "
        f"(pinned at {expected_suites} suites, floor {test_floor} tests)."
    )
    failures: list[str] = []
    if len(suites) != expected_suites:
        direction = "fell to" if len(suites) < expected_suites else "rose to"
        failures.append(
            f"The sanitized suite count {direction} {len(suites)}, "
            f"against the {expected_suites} pinned in "
            ".github/workflows/ci.yml. A fall means an -only-testing: "
            "identifier no longer resolves and its suite was silently "
            "skipped; a rise means the list grew and the pin did not."
        )
    if len(tests) < test_floor:
        failures.append(
            f"Only {len(tests)} tests ran under ThreadSanitizer, "
            f"under the {test_floor} floor set in "
            ".github/workflows/ci.yml."
        )
    return line, failures


def publish(line: str) -> None:
    """Puts the line on the job summary as well as in the log, when there is one."""
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check the sanitized selection ran")
    parser.add_argument("results", type=Path, help="xcresulttool test-results JSON")
    args = parser.parse_args()

    suites, tests = walk(json.loads(args.results.read_text()))
    line, failures = verdict(
        suites,
        tests,
        int(os.environ["EXPECTED_SUITES"]),
        int(os.environ["TEST_FLOOR"]),
    )

    print(line)
    for suite in sorted(suites):
        print(f"  {suite}")
    publish(line)

    for failure in failures:
        print(f"::error::{failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
