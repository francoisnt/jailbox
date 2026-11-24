#!/usr/bin/env python3
"""Rules for dependency updates."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/lib"))
import dependency_updates as rules  # noqa: E402
SHA = "a" * 40
PINS = {"CODE_VERSION": "1.0.0", "CODIUM_VERSION": "1.0.1", "CODIUM_COMMIT": "c" * 40,
        "REMOTE_SSH_VERSION": "0.1.0", "OPEN_REMOTE_SSH_VERSION": "0.2.0",
        "BASE_IMAGE_DEBIAN": "debian:12", "BASE_IMAGE_ALPINE": "alpine:3.24",
        "BASE_IMAGE_FEDORA": "fedora:41", "GO_SERIES": "1.27"}


class UpdateFormatTests(unittest.TestCase):
    def test_accepts_each_key_in_its_format_and_orders_pairs(self):
        text = "GO_SERIES=1.28 BASE_IMAGE_ALPINE=alpine:3.25 CODE_VERSION=1.2.3"
        self.assertEqual(rules.format_update(rules.parse_update(text)),
                         "CODE_VERSION=1.2.3 BASE_IMAGE_ALPINE=alpine:3.25 GO_SERIES=1.28")
        rules.parse_update(f"CODIUM_VERSION=1.143.17232 CODIUM_COMMIT={SHA}")
        rules.parse_update("CODIUM_VERSION=1.135.06055", partial=True)

    def test_refuses_malformed_or_unsafe_text(self):
        for text in ("", " CODE_VERSION=1.2", "CODE_VERSION=1.2  GO_SERIES=1.28", "UNKNOWN=1",
                     "CODE_VERSION=1.2;rm", "CODE_VERSION=latest", "CODE_VERSION=1.2 CODE_VERSION=1.3",
                     "BASE_IMAGE_DEBIAN=ubuntu:24", "BASE_IMAGE_ALPINE=alpine:3", "BASE_IMAGE_FEDORA=fedora:045",
                     "GO_SERIES=1.28.1", "GO_SERIES=2.0", "CODIUM_COMMIT=" + SHA, "CODIUM_VERSION=1.2.3",
                     "CODIUM_VERSION=1.2.3 CODIUM_COMMIT=xyz", "CODE_VERSION=$(id)"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                rules.parse_update(text)


class SelectionTests(unittest.TestCase):
    def newest(self, **changes):
        return {**PINS, **changes}

    def test_pending_lists_only_newer_versions(self):
        newest = self.newest(CODE_VERSION="1.1.0", CODIUM_VERSION="1.0.0", BASE_IMAGE_DEBIAN="debian:13",
                             BASE_IMAGE_ALPINE="alpine:3.23", GO_SERIES="1.28")
        self.assertEqual(rules.pending_updates(newest, PINS),
                         ["CODE_VERSION=1.1.0", "BASE_IMAGE_DEBIAN=debian:13", "GO_SERIES=1.28"])
        # A version with leading zeros compares by number.
        self.assertEqual(rules.pending_updates(self.newest(CODIUM_VERSION="1.0.010"), PINS),
                         ["CODIUM_VERSION=1.0.010"])
        with self.assertRaises(ValueError):
            rules.pending_updates(self.newest(CODE_VERSION="latest"), PINS)


if __name__ == "__main__":
    unittest.main()
