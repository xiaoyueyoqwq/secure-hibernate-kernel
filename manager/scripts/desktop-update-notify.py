#!/usr/bin/env python3
"""Publish deduplicated desktop notifications for verified update state."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable

import gi

gi.require_version("Notify", "0.7")
from gi.repository import GLib, Notify


APP_ID = "io.github.xiaoyueyoqwq.secure-hibernate-manager"
APP_NAME = "Secure Hibernate"
MANAGER_STATE = Path("/var/cache/s4lockdown-update/manager-check-state.json")
KERNEL_CHECK_STATE = Path("/var/cache/s4lockdown-update/check-state.json")
KERNEL_ROOT_STATE = Path("/var/lib/s4lockdown-update/state.json")
MANAGER_VERSION = re.compile(
    r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9]+)?$"
)
KERNEL_RELEASE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_~-]*$")
NOTIFICATION_ICON = "software-update-available"
MANAGER_EXECUTABLE = "/usr/bin/secure-hibernate-manager"
NOTIFICATION_WAIT_SECONDS = 20


def regular_json(path: Path) -> dict[str, Any]:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return {}
    if not stat.S_ISREG(metadata.st_mode):
        return {}
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return document if isinstance(document, dict) else {}


def translations() -> dict[str, str]:
    locale = os.environ.get("LC_MESSAGES") or os.environ.get("LANG", "")
    normalized = locale.lower().replace("-", "_")
    language = "zh-TW" if any(
        marker in normalized for marker in ("zh_tw", "zh_hk", "zh_mo", "hant")
    ) else "zh-CN" if "zh" in normalized else "en-US"
    app_root = Path(__file__).resolve().parents[1]
    catalog_path = app_root / "data/flutter_assets/assets/i18n" / f"{language}.json"
    catalog = regular_json(catalog_path)
    values = catalog.get("notifications")
    if not isinstance(values, dict) or not all(
        isinstance(values.get(key), str)
        for key in (
            "managerUpdateTitle",
            "managerUpdateBody",
            "kernelUpdateTitle",
            "kernelUpdateBody",
            "viewUpdates",
        )
    ):
        raise RuntimeError(f"Notification translations are invalid: {catalog_path}")
    return values


def state_directory() -> Path:
    configured = os.environ.get("XDG_STATE_HOME")
    directory = (
        Path(configured)
        if configured and Path(configured).is_absolute()
        else Path.home() / ".local/state"
    ) / "secure-hibernate-manager"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not stat.S_ISDIR(directory.lstat().st_mode):
        raise RuntimeError(f"Notification state path is not a directory: {directory}")
    os.chmod(directory, 0o700)
    return directory


def write_state(path: Path, document: dict[str, str]) -> None:
    if path.exists() and not stat.S_ISREG(path.lstat().st_mode):
        raise RuntimeError(f"Notification state is not a regular file: {path}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(document, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def update_candidates() -> list[tuple[str, str, str, str]]:
    messages = translations()
    candidates: list[tuple[str, str, str, str]] = []
    manager = regular_json(MANAGER_STATE)
    manager_version = manager.get("latest_version")
    if manager.get("status") == "available" and (
        isinstance(manager_version, str) and MANAGER_VERSION.fullmatch(manager_version)
    ):
        candidates.append((
            "manager",
            manager_version,
            messages["managerUpdateTitle"],
            messages["managerUpdateBody"].replace("{version}", manager_version),
        ))

    check = regular_json(KERNEL_CHECK_STATE)
    root = regular_json(KERNEL_ROOT_STATE)
    kernel_release: object | None = None
    check_status = check.get("status")
    available_check = check_status in {"verified", "already-staged"}
    if available_check:
        kernel_release = check.get("kernel_release")
    if (
        kernel_release is None
        and (not check or available_check)
        and root.get("last_check_status") == "update-available"
    ):
        kernel_release = root.get("available_kernel_release")
    if (
        kernel_release is not None
        and kernel_release == root.get("installed_kernel_release")
        and kernel_release != root.get("available_kernel_release")
    ):
        kernel_release = None
    if (
        isinstance(kernel_release, str)
        and KERNEL_RELEASE.fullmatch(kernel_release)
        and kernel_release.endswith(("-hibernate", "-s4lockdown"))
    ):
        candidates.append((
            "kernel",
            kernel_release,
            messages["kernelUpdateTitle"],
            messages["kernelUpdateBody"].replace("{version}", kernel_release),
        ))
    return candidates


def deliver_notifications(
    pending: list[tuple[str, str, str, str]],
    action_label: str,
    on_activate: Callable[[], None] | None,
) -> tuple[set[tuple[str, str]], bool, bool]:
    successful: set[tuple[str, str]] = set()
    activated = False
    failed = False
    loop = GLib.MainLoop()
    timed_out = False

    def activate(
        _notification: Notify.Notification,
        action: str,
        _user_data: object,
    ) -> None:
        nonlocal activated
        if action != "default" or activated:
            return
        activated = True
        if on_activate is not None:
            try:
                on_activate()
            except OSError as error:
                print(
                    f"Could not activate Secure Hibernate Manager: {error}",
                    file=sys.stderr,
                )
        loop.quit()

    def stop_waiting() -> bool:
        nonlocal timed_out
        timed_out = True
        loop.quit()
        return GLib.SOURCE_REMOVE

    if not pending:
        return successful, activated, failed
    if not Notify.init(APP_NAME):
        print("Could not initialize the desktop notification service", file=sys.stderr)
        return successful, activated, True

    notifications: list[Notify.Notification] = []
    try:
        capabilities = set(Notify.get_server_caps() or ())
        if "actions" not in capabilities:
            print("Desktop notification actions are not supported", file=sys.stderr)
            return successful, activated, True

        for kind, version, title, body in pending:
            notification = Notify.Notification.new(
                title,
                body,
                NOTIFICATION_ICON,
            )
            notification.set_hint(
                "desktop-entry",
                GLib.Variant("s", APP_ID),
            )
            notification.set_urgency(Notify.Urgency.NORMAL)
            notification.set_timeout(15000)
            notification.add_action("default", action_label, activate, None)
            try:
                shown = notification.show()
            except GLib.Error as error:
                failed = True
                print(f"Could not show desktop notification: {error}", file=sys.stderr)
                continue
            if not shown:
                failed = True
                print("Could not show desktop notification", file=sys.stderr)
                continue
            notifications.append(notification)
            successful.add((kind, version))

        if successful:
            timeout_source = GLib.timeout_add_seconds(
                NOTIFICATION_WAIT_SECONDS,
                stop_waiting,
            )
            loop.run()
            if not timed_out:
                GLib.source_remove(timeout_source)
    except GLib.Error as error:
        failed = True
        print(f"Desktop notification service failed: {error}", file=sys.stderr)
    finally:
        notifications.clear()
        Notify.uninit()
    return successful, activated, failed


def publish(
    candidates: list[tuple[str, str, str, str]],
    action_label: str,
    on_activate: Callable[[], None] | None = None,
) -> int:
    directory = state_directory()
    state_path = directory / "notifications.json"
    lock_path = directory / "notifications.lock"
    descriptor = os.open(
        lock_path,
        os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    pending: list[tuple[str, str, str, str]] = []
    activated = False
    failed = False
    successful: set[tuple[str, str]] = set()

    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise RuntimeError(f"Notification lock is not a regular file: {lock_path}")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        notified = {
            key: value
            for key, value in regular_json(state_path).items()
            if key in {"manager", "kernel"} and isinstance(value, str)
        }
        for kind, version, title, body in candidates:
            if notified.get(kind) == version:
                continue
            pending.append((kind, version, title, body))

        successful, activated, failed = deliver_notifications(
            pending,
            action_label,
            on_activate,
        )

        for kind, version in successful:
            notified[kind] = version
        if successful:
            write_state(state_path, notified)
    finally:
        os.close(descriptor)
    if failed:
        return 1
    return 10 if activated else 0


def launch_manager() -> None:
    subprocess.Popen(
        [MANAGER_EXECUTABLE, "--updates"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command")
    show = subparsers.add_parser("show")
    show.add_argument("--kind", required=True, choices=("manager", "kernel"))
    show.add_argument("--version", required=True)
    show.add_argument("--title", required=True)
    show.add_argument("--body", required=True)
    show.add_argument("--action-label", required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.command == "show":
        pattern = MANAGER_VERSION if arguments.kind == "manager" else KERNEL_RELEASE
        if pattern.fullmatch(arguments.version) is None:
            print("Invalid update version", file=sys.stderr)
            return 2
        result = publish(
            [(arguments.kind, arguments.version, arguments.title, arguments.body)],
            arguments.action_label,
        )
        if result == 10:
            print("default")
        return 1 if result == 1 else 0

    messages = translations()
    result = publish(
        update_candidates(),
        messages["viewUpdates"],
        on_activate=launch_manager,
    )
    return 1 if result == 1 else 0


if __name__ == "__main__":
    raise SystemExit(main())
