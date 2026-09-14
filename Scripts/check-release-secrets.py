#!/usr/bin/env python3
"""Decides whether this tree is fit to archive, as far as bundled keys go.

`OpenHikes/Secrets.plist` is gitignored, is the only place the Stadia and
Thunderforest keys live, and exists on exactly one laptop. A Release archive
cut without it builds, signs, uploads and passes CI's archive job, and ships an
app in which **OpenHikes Pro cannot be bought at all**: `Secrets.canLoadTiles`
is false for both paid sources, so both provider rows are drawn at
`disabledOpacity` and refuse the tap, and those rows are the app's only route
to the paywall. Restore Purchases lives on the same screen, so an existing
subscriber reinstalling has no way back either.

Two changes answer that, and they answer different halves. `AboutSection` now
carries an *OpenHikes Pro* row that reads no key, so the paywall is reachable
whatever this program says. This one is about the *map styles*, which a keyless
archive still cannot draw: a build that reaches the App Store with two locked,
unusable sources is selling a subscription whose headline features are absent.

Not a CI check, and it must not become one. The `archive` job builds without
keys deliberately, and its *Verify what the archive does and does not carry*
step is the right place for everything it can assert; a missing `Secrets.plist`
is the one thing it cannot, because in that job it is correct. Not a Run Script
build phase either: conditioning one on `$(CONFIGURATION)` == Release would
fail the Release *simulator* build the `builds` job runs on every pull request.

So it is a thing a person runs before pressing Archive, and it is named in
*Build and test* beside the tag convention for the same reason — the archive
checklist was one step long and this is the second.

The placeholder case is the likelier mistake than the missing file: copying
`Secrets.example.plist` into place and not filling it in leaves a file that
parses, resolves to nothing, and reads exactly like a working one.

Exit status:
  0  every key-gated provider has a real key
  1  the file is missing, unreadable, or a key is absent, empty or a placeholder
"""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path

# The keys `TileProvider.apiKeyPlistKey` names, and the source each one is for.
# Kept here rather than read out of the Swift, because this program has to run
# against a tree it cannot compile and a name it could not resolve would make it
# pass rather than fail.
REQUIRED_KEYS = {
    "StadiaAPIKey": "Stadia Outdoors",
    "ThunderforestAPIKey": "Thunderforest Outdoors",
}

# `Secrets.values` drops anything starting with this, so a placeholder is
# indistinguishable from a missing key at runtime — and silently so.
PLACEHOLDER_PREFIX = "YOUR_"

DEFAULT_PLIST = Path("OpenHikes/Secrets.plist")


class GateFailure(Exception):
    """Why the archive should not be cut, phrased for a person about to cut it."""


def load(path: Path) -> dict:
    """The plist as a dictionary, or a failure that says what to do about it."""
    if not path.exists():
        raise GateFailure(
            f"{path} does not exist.\n"
            f"  Copy Secrets.example.plist to {path} and fill in both keys.\n"
            "  It is gitignored, so a fresh clone never has one."
        )
    try:
        with path.open("rb") as file:
            plist = plistlib.load(file)
    except (OSError, plistlib.InvalidFileException) as error:
        raise GateFailure(f"{path} could not be read: {error}") from error
    if not isinstance(plist, dict):
        raise GateFailure(f"{path} is not a dictionary at its root.")
    return plist


def unusable(plist: dict) -> list[str]:
    """Every required key this build would resolve to nothing, and why.

    The three cases are separated because they are three different mistakes:
    a key that was never added, one whose value was emptied, and the template
    copied and not filled in. `Secrets.values` treats all three the same, which
    is exactly what makes them hard to notice.
    """
    problems = []
    for key, provider in sorted(REQUIRED_KEYS.items()):
        value = plist.get(key)
        if value is None:
            problems.append(f"{key} is missing ({provider} cannot load tiles)")
        elif not isinstance(value, str) or not value:
            problems.append(f"{key} is empty ({provider} cannot load tiles)")
        elif value.startswith(PLACEHOLDER_PREFIX):
            problems.append(
                f"{key} is still the template placeholder "
                f"({provider} cannot load tiles)"
            )
    return problems


def check(path: Path) -> str:
    """The one line printed on success, or a `GateFailure` saying what is wrong."""
    problems = unusable(load(path))
    if problems:
        raise GateFailure(
            f"{path} would not unlock the paid map styles:\n"
            + "\n".join(f"  - {problem}" for problem in problems)
        )
    return f"{path}: {len(REQUIRED_KEYS)} keys resolve. Safe to archive."


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--plist",
        type=Path,
        default=DEFAULT_PLIST,
        help=f"the bundled secrets file to check (default: {DEFAULT_PLIST})",
    )
    arguments = parser.parse_args(argv)
    try:
        print(check(arguments.plist))
    except GateFailure as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
