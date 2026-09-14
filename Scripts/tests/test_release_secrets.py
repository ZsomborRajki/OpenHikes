"""The gate a person runs before pressing Archive.

`Scripts/check-release-secrets.py` decides whether a tree would ship an app
whose paid map styles cannot draw a tile. Every case here is a real plist
written to a temporary directory, because the failure this guards against is
one where a file exists and is wrong rather than one where it is absent: a
placeholder copied from the template parses, resolves to nothing, and reads
exactly like a working key.
"""

from __future__ import annotations

import plistlib
import tempfile
import unittest
from pathlib import Path

from loader import load

gate = load("check-release-secrets.py")


def written(values: dict | list) -> Path:
    """A plist on disk holding `values`, in a directory the test owns."""
    directory = Path(tempfile.mkdtemp())
    path = directory / "Secrets.plist"
    with path.open("wb") as file:
        plistlib.dump(values, file)
    return path


def real() -> dict:
    return {"StadiaAPIKey": "abc123", "ThunderforestAPIKey": "def456"}


class CheckTests(unittest.TestCase):
    def test_real_keys_pass(self):
        message = gate.check(written(real()))
        self.assertIn("2 keys resolve", message)
        self.assertIn("Safe to archive", message)

    def test_a_missing_file_names_the_template(self):
        missing = Path(tempfile.mkdtemp()) / "Secrets.plist"
        with self.assertRaises(gate.GateFailure) as raised:
            gate.check(missing)
        self.assertIn("Secrets.example.plist", str(raised.exception))

    def test_a_missing_key_is_named_with_its_provider(self):
        values = real()
        del values["ThunderforestAPIKey"]
        with self.assertRaises(gate.GateFailure) as raised:
            gate.check(written(values))
        message = str(raised.exception)
        self.assertIn("ThunderforestAPIKey is missing", message)
        self.assertIn("Thunderforest Outdoors", message)
        self.assertNotIn("StadiaAPIKey", message)

    def test_an_empty_key_is_refused(self):
        values = real()
        values["StadiaAPIKey"] = ""
        with self.assertRaises(gate.GateFailure) as raised:
            gate.check(written(values))
        self.assertIn("StadiaAPIKey is empty", str(raised.exception))

    def test_the_template_placeholder_is_refused(self):
        """The likelier mistake than a missing file, and the silent one.

        `Secrets.values` drops anything starting with `YOUR_`, so a copied and
        unfilled template is indistinguishable at runtime from no file at all.
        """
        values = real()
        values["StadiaAPIKey"] = "YOUR_STADIA_API_KEY_HERE"
        with self.assertRaises(gate.GateFailure) as raised:
            gate.check(written(values))
        self.assertIn("template placeholder", str(raised.exception))

    def test_the_checked_in_template_fails_every_key(self):
        """Read from the repository rather than restated.

        A template whose placeholders were reworded would otherwise leave this
        program passing a file that unlocks nothing.
        """
        template = Path(__file__).resolve().parents[2] / "Secrets.example.plist"
        with self.assertRaises(gate.GateFailure) as raised:
            gate.check(template)
        message = str(raised.exception)
        for key in gate.REQUIRED_KEYS:
            self.assertIn(key, message)

    def test_both_problems_are_reported_at_once(self):
        """One run, one list. Fixing one key and re-running to find the other
        is the shape of a check somebody stops running."""
        with self.assertRaises(gate.GateFailure) as raised:
            gate.check(written({"StadiaAPIKey": "", "ThunderforestAPIKey": "YOUR_X"}))
        message = str(raised.exception)
        self.assertIn("StadiaAPIKey", message)
        self.assertIn("ThunderforestAPIKey", message)

    def test_a_plist_that_is_not_a_dictionary_is_refused(self):
        with self.assertRaises(gate.GateFailure) as raised:
            gate.check(written(["StadiaAPIKey"]))
        self.assertIn("not a dictionary", str(raised.exception))


class MainTests(unittest.TestCase):
    def test_exit_status_says_which(self):
        self.assertEqual(gate.main(["--plist", str(written(real()))]), 0)
        values = real()
        values["StadiaAPIKey"] = "YOUR_STADIA_API_KEY_HERE"
        self.assertEqual(gate.main(["--plist", str(written(values))]), 1)


if __name__ == "__main__":
    unittest.main()
