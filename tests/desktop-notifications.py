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

            def deliver(
                pending: list[tuple[str, str, str, str]],
                action_label: str,
                on_activate: object,
            ) -> tuple[set[tuple[str, str]], bool, bool]:
                shown.extend(item[2] for item in pending)
                return {(item[0], item[1]) for item in pending}, False, False

            candidate = [("manager", "1.0.0+47", "Manager update", "Body")]
            with (
                mock.patch.object(NOTIFY, "state_directory", return_value=state_dir),
                mock.patch.object(
                    NOTIFY,
                    "deliver_notifications",
                    side_effect=deliver,
                ),
            ):
                NOTIFY.publish(candidate, "View updates")
                NOTIFY.publish(candidate, "View updates")
            self.assertEqual(shown, ["Manager update"])

    def test_failed_notification_is_retryable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_dir = Path(directory)
            attempts: list[bool] = []

            def deliver(
                pending: list[tuple[str, str, str, str]],
                action_label: str,
                on_activate: object,
            ) -> tuple[set[tuple[str, str]], bool, bool]:
                attempts.append(True)
                return set(), False, True

            candidate = [("manager", "1.0.0+47", "Manager update", "Body")]
            with (
                mock.patch.object(NOTIFY, "state_directory", return_value=state_dir),
                mock.patch.object(
                    NOTIFY,
                    "deliver_notifications",
                    side_effect=deliver,
                ),
            ):
                self.assertEqual(NOTIFY.publish(candidate, "View updates"), 1)
                self.assertEqual(NOTIFY.publish(candidate, "View updates"), 1)
            self.assertEqual(len(attempts), 2)

    def test_default_action_invokes_activation_callback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_dir = Path(directory)
            activated: list[bool] = []

            def deliver(
                pending: list[tuple[str, str, str, str]],
                action_label: str,
                on_activate: object,
            ) -> tuple[set[tuple[str, str]], bool, bool]:
                assert callable(on_activate)
                on_activate()
                return {(item[0], item[1]) for item in pending}, True, False

            with (
                mock.patch.object(NOTIFY, "state_directory", return_value=state_dir),
                mock.patch.object(
                    NOTIFY,
                    "deliver_notifications",
                    side_effect=deliver,
                ),
            ):
                NOTIFY.publish(
                    [("kernel", "7.0.12-29-hibernate", "Kernel update", "Body")],
                    "View updates",
                    on_activate=lambda: activated.append(True),
                )
            self.assertEqual(activated, [True])

    def test_native_notification_uses_system_icon_and_desktop_entry(self) -> None:
        notification = mock.Mock()
        notification.show.return_value = True
        notify = mock.Mock()
        notify.init.return_value = True
        notify.get_server_caps.return_value = ["actions", "icon-static"]
        notify.Notification.new.return_value = notification
        notify.Urgency.NORMAL = 1
        loop = mock.Mock()
        glib = mock.Mock()
        glib.MainLoop.return_value = loop
        glib.timeout_add_seconds.return_value = 7
        glib.SOURCE_REMOVE = False

        with (
            mock.patch.object(NOTIFY, "Notify", notify),
            mock.patch.object(NOTIFY, "GLib", glib),
        ):
            successful, activated, failed = NOTIFY.deliver_notifications(
                [("manager", "1.0.0+47", "Manager update", "Body")],
                "View updates",
                None,
            )

        self.assertEqual(successful, {("manager", "1.0.0+47")})
        self.assertFalse(activated)
        self.assertFalse(failed)
        notify.Notification.new.assert_called_once_with(
            "Manager update",
            "Body",
            "software-update-available",
        )
        notification.set_hint.assert_called_once_with(
            "desktop-entry",
            glib.Variant.return_value,
        )
        glib.Variant.assert_called_once_with("s", NOTIFY.APP_ID)
        notification.add_action.assert_called_once()
        notify.uninit.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
