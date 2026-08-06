#!/usr/bin/env python3
"""Regression tests for scheduled Manager Release checks."""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "update_local", REPO_ROOT / "scripts/update-local.py"
)
assert SPEC is not None and SPEC.loader is not None
UPDATE_LOCAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATE_LOCAL)


def release(version: str, *, url: str | None = None) -> dict[str, object]:
    tag = f"manager-v{version}"
    return {
        "tag_name": tag,
        "draft": False,
        "prerelease": False,
        "html_url": url
        or "https://github.com/xiaoyueyoqwq/secure-hibernate-kernel/"
        f"releases/tag/{tag}",
    }


class ManagerUpdateCheckTests(unittest.TestCase):
    def run_check(
        self,
        current: str,
        releases: list[dict[str, object]],
    ) -> dict[str, object]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / "releases.json"
            fixture.write_text(json.dumps(releases), encoding="utf-8")
            with mock.patch.dict(
                os.environ,
                {
                    "S4LOCKDOWN_TEST_MANAGER_VERSION": current,
                    "S4LOCKDOWN_TEST_MANAGER_RELEASES": str(fixture),
                },
                clear=False,
            ):
                UPDATE_LOCAL.check_manager_release(root, True)
            return json.loads(
                (root / "manager-check-state.json").read_text(encoding="utf-8")
            )

    def test_newer_release_is_available(self) -> None:
        state = self.run_check(
            "1.0.0+46",
            [release("1.0.0+45"), release("1.0.0+47")],
        )
        self.assertEqual(state["status"], "available")
        self.assertEqual(state["latest_version"], "1.0.0+47")

    def test_current_release_is_not_offered(self) -> None:
        state = self.run_check("1.0.0+46", [release("1.0.0+46")])
        self.assertEqual(state["status"], "current")

    def test_untrusted_release_url_fails_closed(self) -> None:
        state = self.run_check(
            "1.0.0+46",
            [release("1.0.0+47", url="https://example.com/manager-v1.0.0+47")],
        )
        self.assertEqual(state["status"], "check-failed")


if __name__ == "__main__":
    unittest.main()
