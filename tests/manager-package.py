#!/usr/bin/env python3
"""Static checks for the Flutter Manager Debian package contract."""

from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
MANAGER_ROOT = REPO_ROOT / "manager"
BUILD_SCRIPT = MANAGER_ROOT / "scripts" / "build-deb.sh"
APP_ID = "io.github.xiaoyueyoqwq.secure-hibernate-manager"


class ManagerPackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build_script = BUILD_SCRIPT.read_text(encoding="utf-8")

    def test_manager_is_the_flutter_project_root(self) -> None:
        self.assertTrue((MANAGER_ROOT / "pubspec.yaml").is_file())
        self.assertTrue((MANAGER_ROOT / "pubspec.lock").is_file())
        self.assertTrue((MANAGER_ROOT / "lib" / "main.dart").is_file())
        self.assertIn(
            "url_launcher:",
            (MANAGER_ROOT / "pubspec.yaml").read_text(encoding="utf-8"),
        )
        self.assertFalse((MANAGER_ROOT / "flutter_prototype").exists())
        for obsolete in (
            "electron-builder.yml",
            "package.json",
            "pnpm-lock.yaml",
            "vite.config.ts",
        ):
            with self.subTest(obsolete=obsolete):
                self.assertFalse((MANAGER_ROOT / obsolete).exists())

    def test_desktop_identity_is_consistent(self) -> None:
        desktop = (
            MANAGER_ROOT / "linux" / "resources" / f"{APP_ID}.desktop"
        ).read_text(encoding="utf-8")
        cmake = (MANAGER_ROOT / "linux" / "CMakeLists.txt").read_text(
            encoding="utf-8"
        )

        self.assertIn(f'set(APPLICATION_ID "{APP_ID}")\n', cmake)
        self.assertIn("Exec=secure-hibernate-manager\n", desktop)
        self.assertIn(f"Icon={APP_ID}\n", desktop)
        self.assertIn(f"StartupWMClass={APP_ID}\n", desktop)
        self.assertIn(
            'application_id=io.github.xiaoyueyoqwq.secure-hibernate-manager\n',
            self.build_script,
        )

    def test_backend_resource_manifest_is_complete(self) -> None:
        scripts = [
            "extract-module-signature.pl",
            "install-signed-packages.sh",
            "install-system-config.sh",
            "install-update-controller.sh",
            "manager-helper.py",
            "patch-tags.sh",
            "release-manifest.py",
            "resolve-version.sh",
            "set-default-kernel.sh",
            "update-local.py",
            "update-local.sh",
            "verify-module-signatures.sh",
        ]
        for name in scripts:
            with self.subTest(script=name):
                self.assertTrue((REPO_ROOT / "scripts" / name).is_file())
                self.assertRegex(
                    self.build_script,
                    rf"(?m)^\s*{re.escape(name)}$",
                )

        for certificate in (
            "secure-hibernate-project.pem",
            "secure-hibernate-project.der",
        ):
            with self.subTest(certificate=certificate):
                self.assertTrue((REPO_ROOT / "certs" / certificate).is_file())
                self.assertIn(certificate, self.build_script)

        for directory in ("dracut", "grub", "logind", "polkit", "systemd"):
            with self.subTest(config=directory):
                source = REPO_ROOT / "config" / directory
                self.assertTrue(source.is_dir())
                self.assertTrue(any(source.iterdir()))

        self.assertIn(
            'cp -a "$repo_root/config/." '
            '"$package_root$app_root/resources/backend/config/"',
            self.build_script,
        )
        self.assertIn("Refusing symbolic links", self.build_script)

    def test_redistribution_licenses_are_packaged(self) -> None:
        resources = (
            (
                REPO_ROOT / "LICENSE",
                "project-GPL-2.0.txt",
            ),
            (
                MANAGER_ROOT / "assets" / "fonts" / "UFL.txt",
                "Ubuntu-Font-Licence.txt",
            ),
            (
                MANAGER_ROOT / "assets" / "licenses" / "Linux-Icon-CC0.txt",
                "Linux-Icon-CC0.txt",
            ),
            (
                MANAGER_ROOT / "assets" / "licenses" / "App-Icon-CC0.txt",
                "App-Icon-CC0.txt",
            ),
        )
        for source, packaged_name in resources:
            with self.subTest(source=source):
                self.assertTrue(source.is_file())
                self.assertIn(source.name, self.build_script)
                self.assertIn(packaged_name, self.build_script)

    def test_package_dependencies_cover_native_and_tpm_boot_paths(self) -> None:
        for dependency in (
            "cryptsetup-bin",
            "dracut-core",
            "libgtk-3-0t64 | libgtk-3-0",
            "libtss2-tcti-device0t64 | libtss2-tcti-device0",
            "mokutil",
            "pkexec",
            "polkitd",
            "systemd-cryptsetup",
            "tpm-udev",
            "tpm2-tools",
        ):
            with self.subTest(dependency=dependency):
                self.assertIn(dependency, self.build_script)

    def test_build_is_offline_after_dependency_resolution(self) -> None:
        self.assertIn("pubspec.lock", self.build_script)
        self.assertIn(".dart_tool/package_config.json", self.build_script)
        self.assertIn("flutter build linux --release --no-pub", self.build_script)
        self.assertIn('--dart-define="MANAGER_VERSION=$version"', self.build_script)

    def test_controller_installer_manifest_matches_packaging_manifest(self) -> None:
        packaged = set(re.findall(
            r"(?m)^\t([a-z0-9.-]+\.(?:sh|py|pl))$",
            self.build_script,
        ))
        installer = (
            REPO_ROOT / "scripts" / "install-update-controller.sh"
        ).read_text(encoding="utf-8")
        match = re.search(
            r"for script in (.*?); do",
            installer,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        installed = {
            name for name in match.group(1).split()
            if not name.startswith("\\")
        }
        self.assertEqual(
            installed,
            packaged - {"install-update-controller.sh"},
        )

    def test_postinst_is_fixed_and_valid(self) -> None:
        match = re.search(
            r"cat >\"\$package_root/DEBIAN/postinst\" <<'EOF'\n(.*?)\nEOF",
            self.build_script,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        postinst = match.group(1)
        self.assertIn(
            "/opt/secure-hibernate-manager/resources/backend/scripts/"
            "install-update-controller.sh",
            postinst,
        )
        self.assertNotIn("apparmor", postinst.lower())
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as script:
            script.write(postinst)
            script.flush()
            subprocess.run(["sh", "-n", script.name], check=True)

    def test_controller_lock_cannot_be_replaced_by_download_user(self) -> None:
        installer = (REPO_ROOT / "scripts" / "install-update-controller.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "lock_file=/var/lib/s4lockdown-update/update.lock", installer
        )
        self.assertNotIn(
            "lock_file=/var/cache/s4lockdown-update/update.lock", installer
        )
        for unit in (
            "s4lockdown-update-check.service",
            "s4lockdown-update-manager-check.service",
        ):
            source = (REPO_ROOT / "config" / "systemd" / unit).read_text(
                encoding="utf-8"
            )
            self.assertIn(
                "ReadWritePaths=/var/lib/s4lockdown-update/update.lock\n", source
            )

        manager_unit = (
            REPO_ROOT / "config/systemd/s4lockdown-update-manager-check.service"
        ).read_text(encoding="utf-8")
        self.assertIn("check --force --wait-for-lock\n", manager_unit)
        self.assertIn("TimeoutStartSec=2h\n", manager_unit)
        self.assertNotIn("Conflicts=s4lockdown-update-check.service", manager_unit)
        controller_installer = (
            REPO_ROOT / "scripts/install-update-controller.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("s4lockdown-update-manager-check.service", controller_installer)

    def test_controller_resets_only_units_that_are_failed(self) -> None:
        installer = (REPO_ROOT / "scripts/install-update-controller.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'if systemctl is-failed --quiet "$unit"; then',
            installer,
        )
        self.assertIn('systemctl reset-failed "$unit"', installer)
        self.assertNotIn("systemctl reset-failed \\\n", installer)

    def test_package_retry_resumes_configuration_when_archives_are_installed(self) -> None:
        installer = (REPO_ROOT / "scripts" / "install-signed-packages.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("package_installed_exactly", installer)
        self.assertIn("resuming configuration", installer)
        self.assertIn(
            '"$repo_root/scripts/set-default-kernel.sh" "$kernel_release"',
            installer,
        )


if __name__ == "__main__":
    unittest.main()
