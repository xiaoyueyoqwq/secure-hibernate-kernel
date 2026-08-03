#!/usr/bin/env python3
"""HTTP resume regression tests for the local updater."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "update_local", REPO_ROOT / "scripts" / "update-local.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load update-local.py")
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)


class FakeResponse:
    def __init__(self, status: int, content: bytes, headers: dict[str, str] | None = None):
        self.status = status
        self.content = content
        self.offset = 0
        self.headers = headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def getcode(self) -> int:
        return self.status

    def read(self, size: int) -> bytes:
        block = self.content[self.offset:self.offset + size]
        self.offset += len(block)
        return block


class UpdateDownloadTests(unittest.TestCase):
    def test_configuration_accepts_bounded_project_kernel_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "update.conf"
            config.write_text(
                "POLICY=automatic-install\nPROJECT_KERNEL_HISTORY=3\n",
                encoding="ascii",
            )
            self.assertEqual(
                updater.read_configuration(config),
                ("automatic-install", 3),
            )
            config.write_text(
                "POLICY=automatic-install\nPROJECT_KERNEL_HISTORY=4\n",
                encoding="ascii",
            )
            with self.assertRaisesRegex(updater.UpdateError, "kernel history"):
                updater.read_configuration(config)

    def test_pruning_preserves_target_running_and_requested_history(self) -> None:
        releases = {
            "7.0.15-ubuntu31-s4lockdown": [
                "linux-image-7.0.15-ubuntu31-s4lockdown",
                "linux-headers-7.0.15-ubuntu31-s4lockdown",
            ],
            "7.0.14-ubuntu30-s4lockdown": [
                "linux-image-7.0.14-ubuntu30-s4lockdown",
                "linux-headers-7.0.14-ubuntu30-s4lockdown",
            ],
            "7.0.13-ubuntu29-s4lockdown": [
                "linux-image-7.0.13-ubuntu29-s4lockdown",
                "linux-headers-7.0.13-ubuntu29-s4lockdown",
            ],
            "7.0.12-ubuntu28-s4lockdown": [
                "linux-image-7.0.12-ubuntu28-s4lockdown",
                "linux-headers-7.0.12-ubuntu28-s4lockdown",
            ],
        }
        commands = []

        def compare(left: str, right: str) -> int:
            left_abi = int(left.split("ubuntu", 1)[1].split("-", 1)[0])
            right_abi = int(right.split("ubuntu", 1)[1].split("-", 1)[0])
            return -1 if left_abi > right_abi else 1 if left_abi < right_abi else 0

        with patch.object(
            updater, "installed_project_kernel_packages", return_value=releases
        ), patch.object(
            updater, "compare_kernel_releases", side_effect=compare
        ), patch.object(
            updater, "run", side_effect=lambda command, **_kwargs: commands.append(command)
        ):
            removed = updater.prune_project_kernels(
                "7.0.15-ubuntu31-s4lockdown",
                1,
                "7.0.12-ubuntu28-s4lockdown",
                testing=False,
            )

        self.assertEqual(removed, ["7.0.13-ubuntu29-s4lockdown"])
        self.assertEqual(commands[-1], ["/usr/sbin/update-grub"])
        self.assertEqual(commands[0][0:2], ["dpkg", "--remove"])
        self.assertIn("linux-image-7.0.13-ubuntu29-s4lockdown", commands[0])
        self.assertNotIn("linux-image-7.0.12-ubuntu28-s4lockdown", commands[0])
        self.assertNotIn("linux-image-7.0.14-ubuntu30-s4lockdown", commands[0])

    def legacy_api_document(self) -> dict[str, object]:
        assets = []
        for name, (size, digest) in updater.LEGACY_RELEASE_ASSETS.items():
            encoded_name = updater.urllib.parse.quote(name, safe="")
            assets.append(
                {
                    "name": name,
                    "size": size,
                    "digest": f"sha256:{digest}",
                    "browser_download_url": (
                        "https://github.com/"
                        f"{updater.PROJECT_REPOSITORY}/releases/download/"
                        f"{updater.LEGACY_RELEASE_TAG}/{encoded_name}"
                    ),
                }
            )
        return {
            "tag_name": updater.LEGACY_RELEASE_TAG,
            "target_commitish": updater.LEGACY_RELEASE_COMMIT,
            "draft": False,
            "prerelease": False,
            "assets": assets,
        }

    def test_production_lock_uses_root_owned_state_directory(self) -> None:
        cache = Path("/var/cache/s4lockdown-update")
        state = Path("/var/lib/s4lockdown-update")
        self.assertEqual(
            updater.runtime_lock_path(cache, state, False),
            state / "update.lock",
        )
        self.assertEqual(
            updater.runtime_lock_path(cache, state, True),
            cache / "update.lock",
        )

    def test_update_lock_rejects_symbolic_link_without_touching_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.lock"
            target.write_text("unchanged", encoding="ascii")
            link = root / "update.lock"
            link.symlink_to(target)

            with self.assertRaises(OSError):
                with updater.update_lock(link):
                    self.fail("symbolic-link lock unexpectedly acquired")

            self.assertEqual(target.read_text(encoding="ascii"), "unchanged")

    def test_release_verification_reports_real_phase_order(self) -> None:
        phases = []
        manifest = {
            "ubuntu_source_package_version": "7.0.0-29.29",
            "kernel_release": "7.0.12-ubuntu29-s4lockdown",
        }
        with patch.object(updater, "run"), patch.object(
            updater, "read_json", return_value=manifest
        ):
            result = updater.verify_release(
                Path("/verified"),
                Path("/manifest-tool"),
                Path("/package-tool"),
                Path("/certificate"),
                "ubuntu-7.0.0-29.29",
                None,
                None,
                phases.append,
            )
        self.assertIs(result, manifest)
        self.assertEqual(
            phases,
            ["verifying-manifest", "verifying-packages", "authorizing-version"],
        )

    def test_check_failure_records_the_exact_verification_phase(self) -> None:
        for failed_phase in (
            "verifying-manifest",
            "verifying-packages",
            "authorizing-version",
        ):
            with self.subTest(failed_phase=failed_phase), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                cache = root / "var/cache/s4lockdown-update"
                state = root / "var/lib/s4lockdown-update"
                config = root / "etc/s4lockdown-update.conf"
                cache.mkdir(parents=True)
                state.mkdir(parents=True)
                config.parent.mkdir(parents=True)
                config.write_text("POLICY=check-and-notify\n", encoding="ascii")

                def fail_verification(*arguments):
                    phase = arguments[-1]
                    phase("verifying-manifest")
                    if failed_phase in {"verifying-packages", "authorizing-version"}:
                        phase("verifying-packages")
                    if failed_phase == "authorizing-version":
                        phase("authorizing-version")
                    raise updater.UpdateError("verification failed")

                with patch.object(
                    updater,
                    "runtime_paths",
                    return_value=(
                        cache,
                        state,
                        config,
                        root / "run/reboot-required",
                        root / "run/reboot-required.pkgs",
                        True,
                    ),
                ), patch.object(
                    updater,
                    "tool_paths",
                    return_value=(
                        Path("/resolver"),
                        Path("/manifest-tool"),
                        Path("/package-tool"),
                        Path("/certificate"),
                    ),
                ), patch.object(
                    updater, "package_tool_path", return_value=Path("/package-tool")
                ), patch.object(
                    updater,
                    "resolve_version",
                    return_value={
                        "source_package_version": "7.0.0-29.29",
                        "marker_tag": "ubuntu-7.0.0-29.29",
                    },
                ), patch.object(
                    updater, "detected_installed_versions", return_value=[]
                ), patch.object(
                    updater,
                    "download_github_release",
                    return_value=(True, "1" * 40),
                ), patch.object(
                    updater, "verify_release", side_effect=fail_verification
                ):
                    result = updater.check_command(
                        SimpleNamespace(
                            force=True,
                            source_version="7.0.0-29.29",
                            installed_source_version=None,
                            source_dir=None,
                        )
                    )

                self.assertEqual(result, 1)
                check_state = json.loads(
                    (cache / "check-state.json").read_text(encoding="utf-8")
                )
                self.assertEqual(check_state["status"], "check-failed")
                self.assertEqual(check_state["failed_phase"], failed_phase)
                self.assertEqual(check_state["error"], "verification failed")
                self.assertEqual(
                    check_state["candidate_source_version"], "7.0.0-29.29"
                )

    def test_legacy_release_uses_exact_pinned_api_snapshot(self) -> None:
        document = self.legacy_api_document()
        downloads = []
        with tempfile.TemporaryDirectory() as directory, patch.object(
            updater,
            "download_json",
            return_value=(200, json.dumps(document).encode("utf-8")),
        ), patch.object(
            updater,
            "download_asset",
            side_effect=lambda *arguments: downloads.append(arguments),
        ):
            available, commit = updater.download_github_release(
                updater.PROJECT_REPOSITORY,
                updater.LEGACY_RELEASE_TAG,
                Path(directory),
            )

        self.assertTrue(available)
        self.assertEqual(commit, updater.LEGACY_RELEASE_COMMIT)
        self.assertEqual(len(downloads), len(updater.LEGACY_RELEASE_ASSETS))
        self.assertEqual(
            {arguments[1].name for arguments in downloads},
            set(updater.LEGACY_RELEASE_ASSETS),
        )

    def test_legacy_release_rejects_changed_api_metadata(self) -> None:
        document = self.legacy_api_document()
        assets = document["assets"]
        self.assertIsInstance(assets, list)
        assets[0]["digest"] = "sha256:" + "0" * 64
        with tempfile.TemporaryDirectory() as directory, patch.object(
            updater,
            "download_json",
            return_value=(200, json.dumps(document).encode("utf-8")),
        ), patch.object(updater, "download_asset") as download:
            with self.assertRaisesRegex(
                updater.UpdateError, "differs from the pinned asset"
            ):
                updater.download_github_release(
                    updater.PROJECT_REPOSITORY,
                    updater.LEGACY_RELEASE_TAG,
                    Path(directory),
                )
        download.assert_not_called()

    def test_other_manifestless_release_remains_unavailable(self) -> None:
        tag = "ubuntu-7.0.0-30.30"
        document = {
            "tag_name": tag,
            "target_commitish": "1" * 40,
            "draft": False,
            "prerelease": False,
            "assets": [],
        }
        with tempfile.TemporaryDirectory() as directory, patch.object(
            updater,
            "download_json",
            return_value=(200, json.dumps(document).encode("utf-8")),
        ), patch.object(updater, "download_asset") as download:
            available, commit = updater.download_github_release(
                updater.PROJECT_REPOSITORY,
                tag,
                Path(directory),
            )
        self.assertFalse(available)
        self.assertIsNone(commit)
        download.assert_not_called()

    def test_legacy_release_rechecks_pinned_files_and_package_signatures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory)
            first = release / "first.asset"
            second = release / "second.asset"
            first.write_bytes(b"first")
            second.write_bytes(b"second")
            pinned = {
                first.name: (first.stat().st_size, hashlib.sha256(b"first").hexdigest()),
                second.name: (
                    second.stat().st_size,
                    hashlib.sha256(b"second").hexdigest(),
                ),
            }
            phases = []
            with patch.object(updater, "LEGACY_RELEASE_ASSETS", pinned), patch.object(
                updater, "run"
            ) as run:
                manifest = updater.verify_release(
                    release,
                    Path("/manifest-tool"),
                    Path("/package-tool"),
                    Path("/certificate"),
                    updater.LEGACY_RELEASE_TAG,
                    None,
                    updater.LEGACY_RELEASE_COMMIT,
                    phases.append,
                )

        self.assertEqual(
            manifest["ubuntu_source_package_version"],
            updater.LEGACY_RELEASE_SOURCE_VERSION,
        )
        self.assertEqual(
            phases,
            ["verifying-manifest", "verifying-packages", "authorizing-version"],
        )
        run.assert_called_once_with(
            [
                "/package-tool",
                "--check-only",
                str(release),
                "/certificate",
            ]
        )

    def test_legacy_release_rejects_tampered_download_before_package_check(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory)
            asset = release / "asset"
            asset.write_bytes(b"tampered")
            pinned = {
                asset.name: (
                    asset.stat().st_size,
                    hashlib.sha256(b"original").hexdigest(),
                )
            }
            with patch.object(updater, "LEGACY_RELEASE_ASSETS", pinned), patch.object(
                updater, "run"
            ) as run:
                with self.assertRaisesRegex(updater.UpdateError, "digest differs"):
                    updater.verify_release(
                        release,
                        Path("/manifest-tool"),
                        Path("/package-tool"),
                        Path("/certificate"),
                        updater.LEGACY_RELEASE_TAG,
                        None,
                        None,
                    )
        run.assert_not_called()

    def test_resume_uses_http_range_and_appends(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "kernel.deb"
            partial = destination.with_name(".kernel.deb.part")
            partial.write_bytes(b"abcd")
            response = FakeResponse(206, b"efghij", {"Content-Range": "bytes 4-9/10"})
            requests = []

            def open_request(request, timeout):
                self.assertEqual(timeout, 120)
                requests.append(request)
                return response

            progress = []
            with patch.object(updater.urllib.request, "urlopen", side_effect=open_request):
                updater.download_asset(
                    "https://github.com/example/project/releases/download/v1/kernel.deb",
                    destination,
                    10,
                    7,
                    17,
                    lambda current, total, asset: progress.append((current, total, asset)),
                )

            self.assertEqual(requests[0].get_header("Range"), "bytes=4-")
            self.assertEqual(destination.read_bytes(), b"abcdefghij")
            self.assertFalse(partial.exists())
            self.assertEqual(progress[-1], (17, 17, "kernel.deb"))

    def test_server_ignoring_range_restarts_download(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "kernel.deb"
            partial = destination.with_name(".kernel.deb.part")
            partial.write_bytes(b"old")
            responses = iter([FakeResponse(200, b"ignored"), FakeResponse(200, b"new-data")])
            requests = []

            def open_request(request, timeout):
                self.assertEqual(timeout, 120)
                requests.append(request)
                return next(responses)

            with patch.object(updater.urllib.request, "urlopen", side_effect=open_request):
                updater.download_asset(
                    "https://github.com/example/project/releases/download/v1/kernel.deb",
                    destination,
                    8,
                    0,
                    8,
                    None,
                )

            self.assertEqual(requests[0].get_header("Range"), "bytes=3-")
            self.assertIsNone(requests[1].get_header("Range"))
            self.assertEqual(destination.read_bytes(), b"new-data")


if __name__ == "__main__":
    unittest.main()
