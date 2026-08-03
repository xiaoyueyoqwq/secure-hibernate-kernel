#!/usr/bin/env python3
"""Regression tests for the fixed privileged Manager helper."""

from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, call, patch


REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "manager_helper", REPO_ROOT / "scripts" / "manager-helper.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load manager-helper.py")
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


def completed(stdout: bytes = b"", stderr: bytes = b"", returncode: int = 0):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class ManagerHelperTests(unittest.TestCase):
    def test_password_stdin_is_bounded_and_cleared_after_dispatch(self) -> None:
        captured = None

        def verify(password):
            nonlocal captured
            captured = password
            self.assertEqual(password, bytearray(b"disk-secret"))
            return {"passwordRecovery": "verified"}

        arguments = SimpleNamespace(
            action="verify-recovery",
            password_stdin=True,
        )
        standard_input = SimpleNamespace(buffer=io.BytesIO(b"disk-secret"))
        with patch.object(helper.sys, "stdin", standard_input), patch.object(
            helper, "action_verify_recovery", side_effect=verify
        ):
            result = helper.dispatch(arguments)

        self.assertEqual(result, {"passwordRecovery": "verified"})
        self.assertIsNotNone(captured)
        self.assertEqual(captured, bytearray(len(b"disk-secret")))

        oversized = SimpleNamespace(
            buffer=io.BytesIO(b"x" * (helper.MAX_PASSWORD_BYTES + 1))
        )
        with patch.object(helper.sys, "stdin", oversized):
            with self.assertRaisesRegex(helper.HelperError, "exceeds 4096"):
                helper.read_password_stdin()

    def test_password_memfd_uses_supplied_bytes_without_ask_password(self) -> None:
        password = bytearray(b"disk-secret")
        with patch.object(helper, "run") as runner:
            descriptor = helper.password_memfd("unused", password)
        try:
            helper.os.lseek(descriptor, 0, helper.os.SEEK_SET)
            self.assertEqual(helper.os.read(descriptor, 64), b"disk-secret")
        finally:
            helper.os.close(descriptor)
        runner.assert_not_called()

    def test_password_verification_cannot_fall_back_to_tpm_tokens(self) -> None:
        runner = Mock()
        with patch.object(helper.os, "lseek"), patch.object(helper, "run", runner):
            helper.test_password(Path("/dev/mock-root"), 44)
        runner.assert_called_once_with([
            helper.EXECUTABLES["cryptsetup"], "open", "--test-passphrase",
            "--disable-external-tokens", "--key-file", "/proc/self/fd/44",
            Path("/dev/mock-root"),
        ], pass_fds=[44], timeout=120)

    def test_bad_recovery_password_has_no_enrollment_side_effects(self) -> None:
        device = Path("/dev/mock-root")
        password_error = helper.CommandError(
            [str(helper.EXECUTABLES["cryptsetup"])],
            2,
            "No key available with this passphrase.",
        )
        with patch.object(helper.os, "lseek"), patch.object(
            helper, "run", side_effect=password_error
        ):
            with self.assertRaisesRegex(
                helper.HelperError, "LUKS recovery password is incorrect"
            ):
                helper.test_password(device, 44)

        backup = Mock()
        configure = Mock()
        command = Mock(side_effect=AssertionError("no mutation command may run"))
        with patch.multiple(
            helper,
            require_project_boot=Mock(return_value="7.0.12-ubuntu28-s4lockdown"),
            root_luks_entry=Mock(return_value=("cryptroot", device)),
            luks_metadata=Mock(return_value={"tokens": {}}),
            inspect_tpm_tokens=Mock(return_value=[]),
            password_memfd=Mock(return_value=44),
            test_password=Mock(
                side_effect=helper.HelperError("The LUKS recovery password is incorrect")
            ),
            backup_luks_header=backup,
            configure_tpm_boot=configure,
            run=command,
        ), patch.object(helper.os, "close"):
            with self.assertRaisesRegex(
                helper.HelperError, "LUKS recovery password is incorrect"
            ):
                helper.action_enroll_tpm()
        backup.assert_not_called()
        configure.assert_not_called()
        command.assert_not_called()

    def test_bad_recovery_password_does_not_rebuild_existing_tpm_configuration(self) -> None:
        device = Path("/dev/mock-root")
        configure = Mock()
        with patch.multiple(
            helper,
            require_project_boot=Mock(return_value="7.0.12-ubuntu28-s4lockdown"),
            root_luks_entry=Mock(return_value=("cryptroot", device)),
            luks_metadata=Mock(return_value={"tokens": {"0": {"type": "systemd-tpm2"}}}),
            inspect_tpm_tokens=Mock(return_value=[{"tokenId": "0", "passed": True}]),
            password_memfd=Mock(return_value=44),
            test_password=Mock(
                side_effect=helper.HelperError("The LUKS recovery password is incorrect")
            ),
            configure_tpm_boot=configure,
        ), patch.object(helper.os, "close"):
            with self.assertRaisesRegex(
                helper.HelperError, "LUKS recovery password is incorrect"
            ):
                helper.action_enroll_tpm()
        configure.assert_not_called()

    def test_recovery_progress_merges_download_and_signature_phases(self) -> None:
        self.assertEqual(
            helper.recovery_progress({
                "status": "downloading",
                "downloaded_bytes": 50,
                "total_bytes": 100,
            }),
            ("downloading-release", 32),
        )
        self.assertEqual(
            helper.recovery_progress({"status": "verifying-manifest"}),
            ("verifying-manifest", 58),
        )
        self.assertEqual(
            helper.recovery_progress({"status": "verifying-packages"}),
            ("verifying-download-packages", 62),
        )
        self.assertEqual(
            helper.recovery_progress({"status": "verified"}),
            ("authorizing-version", 64),
        )

    def test_missing_release_recovery_starts_the_fixed_check_service(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            check_state = Path(directory) / "check-state.json"
            staged = Path(directory) / "staged"
            check_state.write_text('{"status":"verified"}\n', encoding="utf-8")

            def read_state(path):
                if path == check_state:
                    staged.mkdir()
                    return {"status": "verified"}
                if not path.exists():
                    return {}
                return json.loads(path.read_text(encoding="utf-8"))

            runner = Mock(return_value=completed())
            with patch.object(helper, "ROOT_STATE_PATH", state), patch.object(
                helper, "CHECK_STATE_PATH", check_state
            ), patch.object(
                helper, "STAGED_RELEASE_PATH", staged
            ), patch.object(
                helper, "state_file_identity", side_effect=[(1, 1), (2, 2)]
            ), patch.object(
                helper, "read_json", side_effect=read_state
            ), patch.object(helper, "run", runner):
                helper.recover_verified_release()

            self.assertEqual(runner.call_args_list, [
                call(
                    [helper.EXECUTABLES["systemctl"], "reset-failed", helper.CHECK_UNIT],
                    check=False,
                ),
                call([
                    helper.EXECUTABLES["systemctl"], "start", "--no-block",
                    helper.CHECK_UNIT,
                ]),
            ])
            progress = json.loads(state.read_text(encoding="utf-8"))
            self.assertEqual(progress["install_phase"], "authorizing-version")
            self.assertEqual(progress["install_progress"], 64)

    def test_recovery_tolerates_inactive_during_service_startup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            check_state = Path(directory) / "check-state.json"
            staged = Path(directory) / "staged"
            check_state.write_text('{"status":"verified"}\n', encoding="utf-8")
            check_states = iter([
                {"status": "indexing"},
                {"status": "verified"},
            ])

            def read_state(path):
                if path == check_state:
                    current = next(check_states)
                    if current["status"] == "verified":
                        staged.mkdir()
                    return current
                if not path.exists():
                    return {}
                return json.loads(path.read_text(encoding="utf-8"))

            runner = Mock(side_effect=[
                completed(),
                completed(),
                completed(returncode=3),
            ])
            with patch.object(helper, "ROOT_STATE_PATH", state), patch.object(
                helper, "CHECK_STATE_PATH", check_state
            ), patch.object(
                helper, "STAGED_RELEASE_PATH", staged
            ), patch.object(
                helper,
                "state_file_identity",
                side_effect=[(1, 1), (2, 2), (2, 3)],
            ), patch.object(
                helper, "read_json", side_effect=read_state
            ), patch.object(
                helper.time, "sleep"
            ) as sleep, patch.object(helper, "run", runner):
                helper.recover_verified_release()

            sleep.assert_called_once_with(0.5)
            self.assertEqual(runner.call_args_list[-1], call(
                [helper.EXECUTABLES["systemctl"], "is-active", "--quiet", helper.CHECK_UNIT],
                check=False,
            ))
            progress = json.loads(state.read_text(encoding="utf-8"))
            self.assertEqual(progress["install_phase"], "authorizing-version")
            self.assertEqual(progress["install_progress"], 64)

    def test_new_mok_password_uses_memorable_unambiguous_format(self) -> None:
        for _ in range(100):
            password = helper.generate_mok_password()
            self.assertRegex(password, r"^[a-z]{3}[0-9]{5}$")
            self.assertFalse(set(password) & set("ilo01"))
            self.assertIsNotNone(helper.MOK_PASSWORD_PATTERN.fullmatch(password))
        self.assertIsNone(helper.MOK_PASSWORD_PATTERN.fullmatch("Sensitive123"))
        self.assertIsNotNone(
            helper.LEGACY_MOK_PASSWORD_PATTERN.fullmatch("Sensitive123")
        )
        self.assertIsNotNone(
            helper.STORED_MOK_PASSWORD_PATTERN.fullmatch("Sensitive123")
        )

    def test_prepare_mok_replaces_legacy_pending_password(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "mok-state.json"
            state.write_text(
                json.dumps({
                    "schema_version": 1,
                    "fingerprint_sha256": helper.PROJECT_FINGERPRINT,
                    "one_time_password": "Sensitive123",
                }),
                encoding="utf-8",
            )

            def runner(arguments, **_kwargs):
                if arguments[:3] == [helper.EXECUTABLES["openssl"], "passwd", "-6"]:
                    return completed(stdout=b"$6$replacement-hash\n")
                return completed()

            with patch.object(helper, "MOK_STATE_PATH", state), patch.object(
                helper, "certificate_fingerprint", return_value=helper.PROJECT_FINGERPRINT
            ), patch.object(
                helper, "project_mok_enrolled", return_value=False
            ), patch.object(
                helper, "require_only_project_mok_pending", return_value=True
            ), patch.object(
                helper, "pending_mok_fingerprints", side_effect=[set(), {"PROJECT"}]
            ), patch.object(
                helper, "project_mok_sha1", return_value="PROJECT"
            ), patch.object(
                helper, "generate_mok_password", return_value="abc23456"
            ), patch.object(
                helper, "run", side_effect=runner
            ) as mocked_run:
                result = helper.action_prepare_mok()

            self.assertEqual(result["oneTimePassword"], "abc23456")
            self.assertIn(
                call([helper.EXECUTABLES["mokutil"], "--revoke-import"]),
                mocked_run.call_args_list,
            )
            stored = json.loads(state.read_text(encoding="utf-8"))
            self.assertEqual(stored["one_time_password"], "abc23456")

    def test_mok_enrollment_requires_exact_enrolled_fingerprint(self) -> None:
        runner = Mock(return_value=completed(
            stdout=b"[key 1]\nSHA1 Fingerprint: AA:BB:CC\n"
        ))
        with patch.object(
            helper, "certificate_fingerprint",
            side_effect=[helper.PROJECT_FINGERPRINT, "AA:BB:CC"],
        ), patch.object(helper, "require_trusted_file"), patch.object(
            helper, "run", runner
        ):
            self.assertTrue(helper.project_mok_enrolled())
        runner.assert_called_once_with([
            helper.EXECUTABLES["mokutil"], "--list-enrolled"
        ])

    def test_mok_enrollment_rejects_missing_project_fingerprint(self) -> None:
        runner = Mock(return_value=completed(
            stdout=b"[key 1]\nSHA1 Fingerprint: 11:22:33\n"
        ))
        with patch.object(
            helper, "certificate_fingerprint",
            side_effect=[helper.PROJECT_FINGERPRINT, "AA:BB:CC"],
        ), patch.object(helper, "require_trusted_file"), patch.object(
            helper, "run", runner
        ):
            self.assertFalse(helper.project_mok_enrolled())
        runner.assert_called_once_with([
            helper.EXECUTABLES["mokutil"], "--list-enrolled"
        ])

    def test_policy_change_controls_timer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "s4lockdown-update.conf"
            config.write_text("POLICY=check-and-notify\n", encoding="ascii")
            runner = Mock(return_value=completed())
            with patch.object(helper, "CONFIG_PATH", config), patch.object(
                helper, "require_trusted_file"
            ), patch.object(helper, "run", runner):
                result = helper.action_set_policy("manual")

            self.assertEqual(
                config.read_text(encoding="ascii"),
                "POLICY=manual\nPROJECT_KERNEL_HISTORY=2\n",
            )
            self.assertEqual(result["policy"], "manual")
            runner.assert_called_once_with([
                helper.EXECUTABLES["systemctl"], "disable", "--now",
                "s4lockdown-update.timer",
            ])

    def test_kernel_retention_change_preserves_policy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "s4lockdown-update.conf"
            config.write_text(
                "POLICY=automatic-install\nPROJECT_KERNEL_HISTORY=2\n",
                encoding="ascii",
            )
            with patch.object(helper, "CONFIG_PATH", config), patch.object(
                helper, "require_trusted_file"
            ):
                result = helper.action_set_kernel_retention(3)

            self.assertEqual(result, {"projectKernelHistory": 3})
            self.assertEqual(
                config.read_text(encoding="ascii"),
                "POLICY=automatic-install\nPROJECT_KERNEL_HISTORY=3\n",
            )

    def test_kernel_retention_rejects_values_outside_supported_range(self) -> None:
        with self.assertRaisesRegex(helper.HelperError, "must be 1, 2, or 3"):
            helper.action_set_kernel_retention(4)

    def test_configuration_rejects_non_ascii_text_explicitly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "s4lockdown-update.conf"
            config.write_bytes(b"POLICY=manual\n# \xff\n")
            with patch.object(helper, "CONFIG_PATH", config), patch.object(
                helper, "require_trusted_file"
            ), self.assertRaisesRegex(helper.HelperError, "must contain ASCII text"):
                helper.read_update_configuration()

    def test_install_update_applies_system_configuration_after_kernel(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            staged = Path(directory) / "staged"
            staged.mkdir()
            state.write_text(
                '{"last_check_status":"installed-reboot-required",'
                '"installed_source_version":"7.0.0-28.28",'
                '"installed_kernel_release":"7.0.12-ubuntu28-s4lockdown"}\n',
                encoding="utf-8",
            )
            release = "7.0.12-ubuntu28-s4lockdown"
            runner = Mock(side_effect=[completed(), completed()])
            with patch.object(helper, "ROOT_STATE_PATH", state), patch.object(
                helper, "STAGED_RELEASE_PATH", staged
            ), patch.object(
                helper, "require_trusted_file"
            ), patch.object(helper, "project_mok_enrolled", return_value=True), patch.object(
                helper, "installed_kernel_packages",
                return_value={
                    release: [f"linux-image-{release}", f"linux-headers-{release}"],
                },
            ), patch.object(helper, "run", runner):
                result = helper.action_install_update()
            self.assertEqual(result, {
                "installedSourceVersion": "7.0.0-28.28",
                "installedKernelRelease": release,
            })
            self.assertEqual(runner.call_args_list, [
                call([helper.UPDATE_TOOL, "install", "--force"], timeout=2 * 60 * 60),
                call([helper.SYSTEM_CONFIG_TOOL], timeout=30 * 60),
            ])
            progress = json.loads(state.read_text(encoding="utf-8"))
            self.assertEqual(progress["install_phase"], "complete")
            self.assertEqual(progress["install_progress"], 100)

    def test_install_update_recovers_a_missing_staged_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            staged = Path(directory) / "staged"
            available = Path(directory) / "available"
            release = "7.0.12-ubuntu28-s4lockdown"

            def recover() -> None:
                staged.mkdir()

            def runner(command, **_kwargs):
                if command[0] == helper.UPDATE_TOOL:
                    state.write_text(
                        '{"last_check_status":"installed-reboot-required",'
                        '"installed_source_version":"7.0.0-28.28",'
                        f'"installed_kernel_release":"{release}"}}\n',
                        encoding="utf-8",
                    )
                return completed()

            with patch.object(helper, "ROOT_STATE_PATH", state), patch.object(
                helper, "STAGED_RELEASE_PATH", staged
            ), patch.object(
                helper, "AVAILABLE_RELEASE_PATH", available
            ), patch.object(
                helper, "recover_verified_release", side_effect=recover
            ) as recovery, patch.object(
                helper, "require_trusted_file"
            ), patch.object(
                helper, "project_mok_enrolled", return_value=True
            ), patch.object(
                helper,
                "installed_kernel_packages",
                return_value={
                    release: [f"linux-image-{release}", f"linux-headers-{release}"],
                },
            ), patch.object(helper, "run", side_effect=runner):
                result = helper.action_install_update()

            recovery.assert_called_once_with()
            self.assertEqual(result["installedKernelRelease"], release)

    def test_install_update_stops_when_package_manager_is_busy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            staged = Path(directory) / "staged"
            staged.mkdir()
            state.write_text('{"last_check_status":"package-manager-busy"}\n', encoding="utf-8")
            with patch.object(helper, "ROOT_STATE_PATH", state), patch.object(
                helper, "STAGED_RELEASE_PATH", staged
            ), patch.object(
                helper, "require_trusted_file"
            ), patch.object(helper, "project_mok_enrolled", return_value=True), patch.object(
                helper, "run", return_value=completed()
            ):
                with self.assertRaisesRegex(helper.HelperError, "dpkg or APT"):
                    helper.action_install_update()
            progress = json.loads(state.read_text(encoding="utf-8"))
            self.assertEqual(progress["install_phase"], "failed")
            self.assertEqual(progress["install_progress"], 5)

    def test_policy_change_restores_config_on_systemd_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "s4lockdown-update.conf"
            original = b"POLICY=manual\n"
            config.write_bytes(original)
            with patch.object(helper, "CONFIG_PATH", config), patch.object(
                helper, "require_trusted_file"
            ), patch.object(
                helper, "run", side_effect=helper.HelperError("systemd failed")
            ):
                with self.assertRaisesRegex(helper.HelperError, "systemd failed"):
                    helper.action_set_policy("automatic-install")
            self.assertEqual(config.read_bytes(), original)

    def test_swap_repair_replaces_managed_file_and_updates_fstab(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            managed_swap = root / "swap.img"
            fstab = root / "fstab"
            meminfo = root / "meminfo"
            swaps = root / "swaps"
            managed_swap.write_bytes(b"old swap")
            managed_swap.chmod(0o600)
            fstab.write_text(
                f"# existing\n{managed_swap} none swap sw 0 0\n",
                encoding="utf-8",
            )
            meminfo.write_text("MemTotal:        7512612 kB\n", encoding="ascii")
            swaps.write_text(
                "Filename Type Size Used Priority\n"
                f"{managed_swap} file 4194300 0 -1\n",
                encoding="utf-8",
            )

            def run_command(command, **_kwargs):
                if command[0] == helper.EXECUTABLES["findmnt"]:
                    return completed(stdout=b"ext4\n")
                return completed()

            runner = Mock(side_effect=run_command)
            filesystem = SimpleNamespace(f_bavail=16 * helper.GIB, f_frsize=1)
            with patch.multiple(
                helper,
                MANAGED_SWAP_PATH=managed_swap,
                FSTAB_PATH=fstab,
                MEMINFO_PATH=meminfo,
                SWAPS_PATH=swaps,
            ), patch.object(
                helper, "require_trusted_file"
            ), patch.object(
                helper, "validate_existing_managed_swap"
            ), patch.object(
                helper.os, "statvfs", return_value=filesystem
            ), patch.object(
                helper, "run", runner
            ):
                result = helper.action_repair_swap()

            self.assertEqual(result, {
                "swapPath": str(managed_swap),
                "swapSizeBytes": 8 * helper.GIB,
            })
            self.assertTrue(managed_swap.exists())
            self.assertEqual(
                fstab.read_text(encoding="utf-8"),
                f"# existing\n{managed_swap} none swap sw,pri=100 0 0\n",
            )
            commands = [item.args[0] for item in runner.call_args_list]
            self.assertEqual(commands[0], [
                helper.EXECUTABLES["findmnt"], "--noheadings", "--output",
                "FSTYPE", "--target", "/",
            ])
            self.assertEqual(commands[-2:], [
                [helper.EXECUTABLES["swapoff"], managed_swap],
                [helper.EXECUTABLES["swapon"], "--priority", "100", managed_swap],
            ])
            self.assertEqual(list(root.glob(".swap.img.s4lockdown-*")), [])

    def test_swap_repair_rolls_back_when_replacement_cannot_be_enabled(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            managed_swap = root / "swap.img"
            fstab = root / "fstab"
            meminfo = root / "meminfo"
            swaps = root / "swaps"
            original_swap = b"original swap contents"
            original_fstab = f"{managed_swap} none swap sw 0 0\n".encode()
            managed_swap.write_bytes(original_swap)
            managed_swap.chmod(0o600)
            fstab.write_bytes(original_fstab)
            meminfo.write_text("MemTotal: 8388608 kB\n", encoding="ascii")
            swaps.write_text(
                "Filename Type Size Used Priority\n"
                f"{managed_swap} file 4194300 0 -1\n",
                encoding="utf-8",
            )

            def run_command(command, **_kwargs):
                if command[0] == helper.EXECUTABLES["findmnt"]:
                    return completed(stdout=b"ext4\n")
                if (command[0] == helper.EXECUTABLES["swapon"]
                        and command[2] == "100"):
                    raise helper.HelperError("replacement swapon failed")
                return completed()

            runner = Mock(side_effect=run_command)
            filesystem = SimpleNamespace(f_bavail=16 * helper.GIB, f_frsize=1)
            with patch.multiple(
                helper,
                MANAGED_SWAP_PATH=managed_swap,
                FSTAB_PATH=fstab,
                MEMINFO_PATH=meminfo,
                SWAPS_PATH=swaps,
            ), patch.object(
                helper, "require_trusted_file"
            ), patch.object(
                helper, "validate_existing_managed_swap"
            ), patch.object(
                helper.os, "statvfs", return_value=filesystem
            ), patch.object(
                helper, "run", runner
            ):
                with self.assertRaisesRegex(
                    helper.HelperError, "replacement swapon failed"
                ):
                    helper.action_repair_swap()

            self.assertEqual(managed_swap.read_bytes(), original_swap)
            self.assertEqual(fstab.read_bytes(), original_fstab)
            self.assertEqual(list(root.glob(".swap.img.s4lockdown-*")), [])
            self.assertEqual(
                [item.args[0] for item in runner.call_args_list][-1],
                [helper.EXECUTABLES["swapon"], "--priority", "-1", managed_swap],
            )

    def test_existing_working_tpm_token_prevents_duplicate_enrollment(self) -> None:
        device = Path("/dev/mock-root")
        metadata = {"tokens": {"0": {"type": "systemd-tpm2"}}}
        configuration = Mock(return_value=False)
        with patch.multiple(
            helper,
            require_project_boot=Mock(return_value="7.0.12-ubuntu28-s4lockdown"),
            root_luks_entry=Mock(return_value=("cryptroot", device)),
            luks_metadata=Mock(return_value=metadata),
            inspect_tpm_tokens=Mock(return_value=[{"tokenId": "0", "passed": True}]),
            configure_tpm_boot=configuration,
            password_memfd=Mock(return_value=44),
            test_password=Mock(),
        ):
            with patch.object(helper.os, "close"):
                result = helper.action_enroll_tpm()
        self.assertTrue(result["alreadyConfigured"])
        self.assertEqual(result["addedTokenIds"], [])
        self.assertIsNone(result["headerBackup"])
        self.assertEqual(result["passwordRecovery"], "verified")
        configuration.assert_called_once_with(
            "7.0.12-ubuntu28-s4lockdown", "cryptroot", device,
        )

    def test_new_tpm_enrollment_rechecks_password_after_token_change(self) -> None:
        device = Path("/dev/mock-root")
        release = "7.0.12-ubuntu28-s4lockdown"
        before = {"tokens": {}}
        after = {"tokens": {"4": {"type": "systemd-tpm2"}}}
        password_test = Mock()
        configuration = Mock(return_value=True)
        with tempfile.TemporaryDirectory() as directory:
            crypttab = Path(directory) / "crypttab"
            crypttab.write_text("cryptroot UUID=1111 none luks,tpm2-device=auto\n")
            with patch.multiple(
                helper,
                CRYPTTAB_PATH=crypttab,
                require_project_boot=Mock(return_value=release),
                root_luks_entry=Mock(return_value=("cryptroot", device)),
                luks_metadata=Mock(side_effect=[before, after]),
                inspect_tpm_tokens=Mock(return_value=[]),
                verify_tpm_tokens=Mock(return_value={
                    "tokens": [{"tokenId": "4", "passed": True}],
                }),
                password_memfd=Mock(return_value=44),
                test_password=password_test,
                backup_luks_header=Mock(return_value=Path(directory) / "header.img"),
                configure_tpm_boot=configuration,
                run=Mock(return_value=completed()),
            ), patch.object(helper.os, "close"), patch.object(helper.os, "lseek"):
                result = helper.action_enroll_tpm()

        self.assertEqual(password_test.call_count, 2)
        self.assertEqual(result["addedTokenIds"], ["4"])
        self.assertEqual(result["passwordRecovery"], "verified")
        configuration.assert_called_once_with(release, "cryptroot", device)

    def test_enrolled_mok_inspection_removes_one_time_password(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "mok-state.json"
            state.write_text('{"one_time_password":"Sensitive123"}\n', encoding="utf-8")
            with patch.object(helper, "MOK_STATE_PATH", state), patch.object(
                helper, "certificate_fingerprint", return_value=helper.PROJECT_FINGERPRINT
            ), patch.object(helper, "project_mok_enrolled", return_value=True):
                result = helper.action_inspect_mok()
            self.assertEqual(result["mokStatus"], "enrolled")
            self.assertFalse(state.exists())

    def test_mok_cancel_refuses_unrelated_pending_request(self) -> None:
        with patch.object(
            helper,
            "pending_mok_fingerprints",
            return_value={"PROJECT", "UNRELATED"},
        ), patch.object(helper, "project_mok_sha1", return_value="PROJECT"), patch.object(
            helper, "run", side_effect=AssertionError("mokutil must not be called")
        ):
            with self.assertRaisesRegex(helper.HelperError, "Unrelated MOK"):
                helper.action_cancel_mok()

    def test_mok_cancel_verifies_pending_request_was_removed(self) -> None:
        with patch.object(
            helper,
            "pending_mok_fingerprints",
            side_effect=[{"PROJECT"}, {"PROJECT"}],
        ), patch.object(helper, "project_mok_sha1", return_value="PROJECT"), patch.object(
            helper, "run", return_value=completed()
        ):
            with self.assertRaisesRegex(helper.HelperError, "did not remove"):
                helper.action_cancel_mok()

    def test_tpm_verification_uses_token_only_mode(self) -> None:
        runner = Mock(side_effect=[completed(returncode=1), completed()])
        with patch.object(helper, "run", runner):
            results = helper.inspect_tpm_tokens(Path("/dev/mock"), ["2", "7"])
        self.assertEqual(results, [
            {"tokenId": "2", "passed": False},
            {"tokenId": "7", "passed": True},
        ])
        self.assertEqual(runner.call_args_list, [
            call([
                helper.EXECUTABLES["cryptsetup"], "open", "--test-passphrase",
                "--token-only", "--token-id", "2", Path("/dev/mock"),
            ], timeout=120, check=False),
            call([
                helper.EXECUTABLES["cryptsetup"], "open", "--test-passphrase",
                "--token-only", "--token-id", "7", Path("/dev/mock"),
            ], timeout=120, check=False),
        ])

    def test_tpm_inspection_reports_missing_token_without_error(self) -> None:
        device = Path("/dev/mock-root")
        with patch.multiple(
            helper,
            root_luks_entry=Mock(return_value=("cryptroot", device)),
            luks_uuid=Mock(return_value="11111111-2222-3333-4444-555555555555"),
            inspect_tpm_tokens=Mock(return_value=[]),
        ):
            result = helper.action_verify_tpm()
        self.assertFalse(result["alreadyConfigured"])
        self.assertEqual(result["tokens"], [])

    def test_tpm_inspection_reports_unusable_and_working_tokens(self) -> None:
        device = Path("/dev/mock-root")
        tokens = [
            {"tokenId": "0", "passed": False},
            {"tokenId": "2", "passed": True},
        ]
        with patch.multiple(
            helper,
            root_luks_entry=Mock(return_value=("cryptroot", device)),
            luks_uuid=Mock(return_value="11111111-2222-3333-4444-555555555555"),
            inspect_tpm_tokens=Mock(return_value=tokens),
        ):
            result = helper.action_verify_tpm()
        self.assertTrue(result["alreadyConfigured"])
        self.assertEqual(result["tokens"], tokens)

    def test_crypttab_update_changes_only_root_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            crypttab = Path(directory) / "crypttab"
            crypttab.write_text(
                "# keep this comment\n"
                "cryptroot UUID=1111 none luks,discard\n"
                "other UUID=2222 none luks\n",
                encoding="utf-8",
            )
            with patch.object(helper, "CRYPTTAB_PATH", crypttab), patch.object(
                helper, "require_trusted_file"
            ):
                self.assertTrue(helper.ensure_tpm_crypttab("cryptroot"))
                self.assertFalse(helper.ensure_tpm_crypttab("cryptroot"))
            self.assertEqual(
                crypttab.read_text(encoding="utf-8"),
                "# keep this comment\n"
                "cryptroot UUID=1111 none luks,discard,tpm2-device=auto\n"
                "other UUID=2222 none luks\n",
            )

    def test_encrypted_root_initramfs_is_verified_before_atomic_replacement(self) -> None:
        release = "7.0.12-ubuntu28-s4lockdown"
        root_uuid = "c140e7ae-32b5-4ef9-bd82-e42083ba5f15"
        device_uuid = "cca9e414-f9c8-41e5-8ad0-7263789016d9"
        device = Path("/dev/mock-root")
        with tempfile.TemporaryDirectory() as directory:
            boot = Path(directory) / "boot"
            boot.mkdir()
            target = boot / f"initrd.img-{release}"
            target.write_bytes(b"old-initramfs")
            crypttab = Path(directory) / "crypttab"
            crypttab.write_text(
                f"cryptroot UUID={device_uuid} none luks,tpm2-device=auto\n",
                encoding="utf-8",
            )

            def execute(command, **_kwargs):
                arguments = list(command)
                if arguments[0] == helper.EXECUTABLES["dracut"]:
                    Path(arguments[-2]).write_bytes(b"verified-initramfs")
                    return completed()
                if arguments[:3] == [
                    helper.EXECUTABLES["lsinitrd"], "--file", "/etc/crypttab",
                ]:
                    return completed(
                        f"cryptroot UUID={device_uuid} none luks,tpm2-device=auto\n".encode()
                    )
                if arguments[0] == helper.EXECUTABLES["lsinitrd"]:
                    return completed((
                        "dracut cmdline:\n"
                        f"root=UUID={root_uuid} rd.luks.uuid=luks-{device_uuid} rw\n"
                        "-rw-r--r-- etc/crypttab\n"
                        "-rwxr-xr-x usr/sbin/cryptsetup\n"
                        "-rwxr-xr-x usr/bin/tpm2\n"
                        "-rw-r--r-- usr/lib/x86_64-linux-gnu/cryptsetup/"
                        "libcryptsetup-token-systemd-tpm2.so\n"
                        "-rw-r--r-- usr/lib/x86_64-linux-gnu/"
                        "libtss2-tcti-device.so.0\n"
                        "-rw-r--r-- usr/lib/udev/rules.d/60-tpm-udev.rules\n"
                    ).encode())
                raise AssertionError(f"Unexpected command: {arguments}")

            runner = Mock(side_effect=execute)
            with patch.multiple(
                helper,
                BOOT_DIRECTORY=boot,
                CRYPTTAB_PATH=crypttab,
                require_trusted_file=Mock(),
                require_trusted_directory=Mock(),
                root_filesystem_uuid=Mock(return_value=root_uuid),
                luks_uuid=Mock(return_value=device_uuid),
                run=runner,
            ):
                helper.rebuild_encrypted_root_initramfs(
                    release, "cryptroot", device,
                )

            self.assertEqual(target.read_bytes(), b"verified-initramfs")
            dracut_arguments = list(runner.call_args_list[0].args[0])
            candidate = dracut_arguments[-2]
            self.assertEqual(dracut_arguments, [
                helper.EXECUTABLES["dracut"], "--force", "--no-hostonly",
                "--add", "crypt dm rootfs-block systemd-cryptsetup tpm2-tss",
                "--include", crypttab, "/etc/crypttab",
                "--kernel-cmdline",
                f"root=UUID={root_uuid} rd.luks.uuid=luks-{device_uuid} rw",
                candidate, release,
            ])
            self.assertEqual(list(boot.glob(".*.candidate")), [])
            self.assertEqual(list(boot.glob(".*.previous")), [])

    def test_failed_initramfs_verification_preserves_installed_image(self) -> None:
        release = "7.0.12-ubuntu28-s4lockdown"
        root_uuid = "c140e7ae-32b5-4ef9-bd82-e42083ba5f15"
        device_uuid = "cca9e414-f9c8-41e5-8ad0-7263789016d9"
        with tempfile.TemporaryDirectory() as directory:
            boot = Path(directory) / "boot"
            boot.mkdir()
            target = boot / f"initrd.img-{release}"
            target.write_bytes(b"old-initramfs")

            def execute(command, **_kwargs):
                arguments = list(command)
                if arguments[0] == helper.EXECUTABLES["dracut"]:
                    Path(arguments[-2]).write_bytes(b"incomplete-initramfs")
                    return completed()
                return completed((
                    "dracut cmdline:\n"
                    f"root=UUID={root_uuid} rd.luks.uuid=luks-{device_uuid} rw\n"
                    "-rw-r--r-- etc/crypttab\n"
                    "-rwxr-xr-x usr/lib/systemd/systemd-cryptsetup\n"
                ).encode())

            with patch.multiple(
                helper,
                BOOT_DIRECTORY=boot,
                CRYPTTAB_PATH=Path(directory) / "crypttab",
                require_trusted_file=Mock(),
                require_trusted_directory=Mock(),
                root_filesystem_uuid=Mock(return_value=root_uuid),
                luks_uuid=Mock(return_value=device_uuid),
                run=Mock(side_effect=execute),
            ):
                with self.assertRaisesRegex(helper.HelperError, "TPM utility"):
                    helper.rebuild_encrypted_root_initramfs(
                        release, "cryptroot", Path("/dev/mock-root"),
                    )

            self.assertEqual(target.read_bytes(), b"old-initramfs")
            self.assertEqual(list(boot.glob(".*.candidate")), [])
            self.assertEqual(list(boot.glob(".*.previous")), [])

    def test_failed_rebuild_restores_crypttab_without_second_dracut(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            crypttab = Path(directory) / "crypttab"
            original = b"cryptroot UUID=1111 none luks\n"
            crypttab.write_bytes(original)

            def update(_mapper):
                crypttab.write_bytes(
                    b"cryptroot UUID=1111 none luks,tpm2-device=auto\n"
                )
                return True

            rebuild = Mock(side_effect=helper.HelperError("candidate is incomplete"))
            with patch.multiple(
                helper,
                CRYPTTAB_PATH=crypttab,
                ensure_tpm_crypttab=Mock(side_effect=update),
                rebuild_encrypted_root_initramfs=rebuild,
            ):
                with self.assertRaisesRegex(helper.HelperError, "candidate is incomplete"):
                    helper.configure_tpm_boot(
                        "7.0.12-ubuntu28-s4lockdown",
                        "cryptroot",
                        Path("/dev/mock-root"),
                    )

            self.assertEqual(crypttab.read_bytes(), original)
            self.assertEqual(rebuild.call_count, 1)

    def test_existing_crypttab_still_rebuilds_initramfs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            crypttab = Path(directory) / "crypttab"
            crypttab.write_bytes(b"cryptroot UUID=1111 none luks,tpm2-device=auto\n")
            rebuild = Mock()
            with patch.multiple(
                helper,
                CRYPTTAB_PATH=crypttab,
                ensure_tpm_crypttab=Mock(return_value=False),
                rebuild_encrypted_root_initramfs=rebuild,
            ):
                changed = helper.configure_tpm_boot(
                    "7.0.12-ubuntu28-s4lockdown", "cryptroot", Path("/dev/mock-root"),
                )
        self.assertFalse(changed)
        rebuild.assert_called_once_with(
            "7.0.12-ubuntu28-s4lockdown", "cryptroot", Path("/dev/mock-root"),
        )

    def test_kernel_removal_requires_another_project_image(self) -> None:
        release = "7.0.12-ubuntu28-s4lockdown"
        packages = {
            release: [f"linux-image-{release}", f"linux-headers-{release}"],
            "7.0.0-28-generic": ["linux-image-7.0.0-28-generic"],
        }
        with patch.object(helper.os, "uname", return_value=SimpleNamespace(release="other")), patch.object(
            helper, "installed_kernel_packages", return_value=packages
        ):
            with self.assertRaisesRegex(helper.HelperError, "other project kernel"):
                helper.action_remove_kernel(release)

    def test_kernel_removal_never_counts_headers_as_official_fallback(self) -> None:
        release = "7.0.12-ubuntu28-s4lockdown"
        packages = {
            release: [f"linux-image-{release}"],
            "7.0.11-ubuntu27-s4lockdown": ["linux-image-7.0.11-ubuntu27-s4lockdown"],
            "7.0.0-28-generic": ["linux-headers-7.0.0-28-generic"],
        }
        with patch.object(helper.os, "uname", return_value=SimpleNamespace(release="other")), patch.object(
            helper, "installed_kernel_packages", return_value=packages
        ):
            with self.assertRaisesRegex(helper.HelperError, "official Ubuntu fallback"):
                helper.action_remove_kernel(release)


if __name__ == "__main__":
    unittest.main()
