#!/usr/bin/env python3
"""Regression tests for desktop update notification state handling."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "desktop_update_notify",
    REPO_ROOT / "manager/scripts/desktop-update-notify.py",
)
assert SPEC is not None and SPEC.loader is not None
NOTIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NOTIFY)

MESSAGES = {
    "managerUpdateTitle": "Manager update",
    "managerUpdateBody": "Manager {version}",
    "kernelUpdateTitle": "Kernel update",
    "kernelUpdateBody": "Kernel {version}",
    "viewUpdates": "View updates",
}


class FakeProcess:
    def __init__(self, action: str = "", returncode: int = 0) -> None:
        self.action = action
        self.returncode = returncode

    def communicate(self, timeout: int | None = None) -> tuple[str, str]:
        return self.action, ""

    def terminate(self) -> None:
        self.returncode = -15

    def kill(self) -> None:
        self.returncode = -9


class DesktopNotificationTests(unittest.TestCase):
    def test_candidates_include_manager_and_verified_kernel(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manager = root / "manager.json"
            kernel = root / "kernel.json"
            state = root / "state.json"
            manager.write_text(
                json.dumps({"status": "available", "latest_version": "1.0.0+47"}),
                encoding="utf-8",
            )
            kernel.write_text(
                json.dumps(
                    {
                        "status": "verified",
                        "kernel_release": "7.0.12-29-vmstat-hibernate",
                    }
                ),
                encoding="utf-8",
            )
            state.write_text("{}", encoding="utf-8")
            with (
                mock.patch.object(NOTIFY, "MANAGER_STATE", manager),
                mock.patch.object(NOTIFY, "KERNEL_CHECK_STATE", kernel),
                mock.patch.object(NOTIFY, "KERNEL_ROOT_STATE", state),
                mock.patch.object(NOTIFY, "translations", return_value=MESSAGES),
            ):
                candidates = NOTIFY.update_candidates()
        self.assertEqual([candidate[:2] for candidate in candidates], [
            ("manager", "1.0.0+47"),
            ("kernel", "7.0.12-29-vmstat-hibernate"),
        ])

    def test_same_version_is_not_notified_twice(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_dir = Path(directory)
            shown: list[str] = []

            def show(title: str, body: str, action_label: str) -> FakeProcess:
                shown.append(title)
                return FakeProcess()

            candidate = [("manager", "1.0.0+47", "Manager update", "Body")]
            with (
                mock.patch.object(NOTIFY, "state_directory", return_value=state_dir),
                mock.patch.object(NOTIFY, "show_notification", side_effect=show),
            ):
                NOTIFY.publish(candidate, "View updates")
                NOTIFY.publish(candidate, "View updates")
            self.assertEqual(shown, ["Manager update"])

    def test_failed_notification_is_retryable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_dir = Path(directory)
            attempts: list[bool] = []

            def show(title: str, body: str, action_label: str) -> FakeProcess:
                attempts.append(True)
                return FakeProcess(returncode=1)

            candidate = [("manager", "1.0.0+47", "Manager update", "Body")]
            with (
                mock.patch.object(NOTIFY, "state_directory", return_value=state_dir),
                mock.patch.object(NOTIFY, "show_notification", side_effect=show),
            ):
                self.assertEqual(NOTIFY.publish(candidate, "View updates"), 1)
                self.assertEqual(NOTIFY.publish(candidate, "View updates"), 1)
            self.assertEqual(len(attempts), 2)

    def test_default_action_invokes_activation_callback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_dir = Path(directory)
            activated: list[bool] = []
            with (
                mock.patch.object(NOTIFY, "state_directory", return_value=state_dir),
                mock.patch.object(
                    NOTIFY,
                    "show_notification",
                    return_value=FakeProcess("default\n"),
                ),
            ):
                NOTIFY.publish(
                    [("kernel", "7.0.12-29-hibernate", "Kernel update", "Body")],
                    "View updates",
                    on_activate=lambda: activated.append(True),
                )
            self.assertEqual(activated, [True])


if __name__ == "__main__":
    unittest.main()
