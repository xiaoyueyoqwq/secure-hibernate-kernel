#!/usr/bin/env python3
"""Regression tests for the isolated Flutter Manager release chain."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import tempfile
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
TOOL = REPO_ROOT / "scripts" / "manager-release.py"
PUBSPEC = REPO_ROOT / "manager" / "pubspec.yaml"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "manager-release.yml"
VERSION = re.search(
    r"(?m)^version:[ \t]*([^#\s]+)[ \t]*$",
    PUBSPEC.read_text(encoding="utf-8"),
).group(1)
TAG = f"manager-v{VERSION}"
COMMIT = "a" * 40
DEB_NAME = f"secure-hibernate-manager_{VERSION}_amd64.deb"
BUNDLE_NAME = f"{DEB_NAME}.intoto.jsonl"


class ManagerReleaseTests(unittest.TestCase):
    def run_tool(self, *arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(TOOL), *arguments],
            check=check,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def create_package(
        self, directory: Path, *, version: str = VERSION, architecture: str = "amd64"
    ) -> Path:
        root = directory / "package-root"
        (root / "DEBIAN").mkdir(parents=True)
        (root / "DEBIAN" / "control").write_text(
            "\n".join(
                (
                    "Package: secure-hibernate-manager",
                    f"Version: {version}",
                    "Section: admin",
                    "Priority: optional",
                    f"Architecture: {architecture}",
                    "Maintainer: Test <test@example.invalid>",
                    "Description: Manager release fixture",
                    "",
                )
            ),
            encoding="utf-8",
        )
        output = directory / DEB_NAME
        subprocess.run(
            ["dpkg-deb", "--build", "--root-owner-group", str(root), str(output)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        shutil.rmtree(root)
        return output

    def prepare(self, directory: Path) -> None:
        self.create_package(directory)
        self.run_tool(
            "prepare",
            str(directory),
            "--pubspec",
            str(PUBSPEC),
            "--git-commit",
            COMMIT,
        )

    def verify(self, directory: Path, *extra: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return self.run_tool(
            "verify",
            str(directory),
            "--pubspec",
            str(PUBSPEC),
            "--expected-release-tag",
            TAG,
            "--expected-git-commit",
            COMMIT,
            *extra,
            check=check,
        )

    def test_exact_tag_enables_publish(self) -> None:
        result = self.run_tool(
            "metadata",
            "--pubspec",
            str(PUBSPEC),
            "--event-name",
            "push",
            "--ref-type",
            "tag",
            "--ref-name",
            TAG,
        )
        outputs = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(outputs["version"], VERSION)
        self.assertEqual(outputs["release_tag"], TAG)
        self.assertEqual(outputs["deb_name"], DEB_NAME)
        self.assertEqual(outputs["publish"], "true")

    def test_wrong_or_kernel_tag_is_rejected(self) -> None:
        for tag in ("manager-v0.1.0+23", "ubuntu-7.0.0-28.28"):
            with self.subTest(tag=tag):
                result = self.run_tool(
                    "metadata",
                    "--pubspec",
                    str(PUBSPEC),
                    "--event-name",
                    "push",
                    "--ref-type",
                    "tag",
                    "--ref-name",
                    tag,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)

    def test_dispatch_never_enables_publish(self) -> None:
        result = self.run_tool(
            "metadata",
            "--pubspec",
            str(PUBSPEC),
            "--event-name",
            "workflow_dispatch",
            "--ref-type",
            "tag",
            "--ref-name",
            TAG,
        )
        self.assertIn("publish=false\n", result.stdout)

    def test_prepare_and_verify_exact_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.prepare(directory)
            self.verify(directory)
            package = directory / DEB_NAME
            digest = hashlib.sha256(package.read_bytes()).hexdigest()
            self.assertEqual(
                (directory / "SHA256SUMS").read_text(encoding="ascii"),
                f"{digest}  {DEB_NAME}\n",
            )
            descriptor = json.loads(
                (directory / "manager-release.json").read_text(encoding="utf-8")
            )
            self.assertEqual(descriptor["release_tag"], TAG)
            self.assertEqual(descriptor["git_commit"], COMMIT)
            self.assertEqual(descriptor["artifact"]["sha256"], digest)

    def test_wrong_package_metadata_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.create_package(directory, architecture="arm64")
            result = self.run_tool(
                "prepare",
                str(directory),
                "--pubspec",
                str(PUBSPEC),
                "--git-commit",
                COMMIT,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)

    def test_tampering_and_extra_kernel_asset_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.prepare(directory)
            (directory / DEB_NAME).write_bytes(b"tampered")
            self.assertNotEqual(self.verify(directory, check=False).returncode, 0)

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.prepare(directory)
            (directory / "linux-image-forbidden.deb").write_bytes(b"kernel")
            self.assertNotEqual(self.verify(directory, check=False).returncode, 0)

    def test_attestation_is_required_for_published_shape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.prepare(directory)
            result = self.verify(directory, "--require-attestation", check=False)
            self.assertNotEqual(result.returncode, 0)
            (directory / BUNDLE_NAME).write_text("{}\n", encoding="ascii")
            self.verify(directory, "--require-attestation")

    def test_workflow_separates_manual_build_and_tag_publish(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        triggers = workflow.split("\npermissions:\n", 1)[0]
        self.assertIn('      - "manager-v*"\n', triggers)
        self.assertNotIn("ubuntu-", triggers)
        self.assertNotIn("schedule:", triggers)
        self.assertIn("flutter-version: 3.44.8", workflow)
        self.assertIn("manager/.metadata", workflow)
        self.assertIn('get("frameworkRevision")', workflow)
        self.assertNotIn("cache: true", workflow)
        self.assertIn("github.event_name == 'push'", workflow)
        self.assertIn("needs.build.outputs.publish == 'true'", workflow)
        self.assertIn("git merge-base --is-ancestor", workflow)
        self.assertIn("attestations: write", workflow)
        self.assertIn("id-token: write", workflow)
        self.assertIn("contents: write", workflow)
        self.assertIn("environment: manager-release", workflow)
        self.assertIn("--verify-tag", workflow)
        self.assertIn("--latest=false", workflow)
        self.assertIn("--require-attestation", workflow)
        self.assertIn("--signer-workflow", workflow)
        self.assertIn("--source-ref", workflow)
        self.assertIn("--source-digest", workflow)
        self.assertNotIn("PROJECT_MOK_PRIVATE_KEY", workflow)
        self.assertNotIn("release-signing", workflow)
        checks = (REPO_ROOT / ".github" / "workflows" / "checks.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("python3 tests/manager-release.py", checks)
        kernel_workflow = (
            REPO_ROOT / ".github" / "workflows" / "build.yml"
        ).read_text(encoding="utf-8")
        self.assertNotIn("manager-release.yml", kernel_workflow)
        self.assertNotIn("scripts/build-deb.sh", kernel_workflow)


if __name__ == "__main__":
    unittest.main()
