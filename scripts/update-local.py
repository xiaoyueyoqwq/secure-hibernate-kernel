#!/usr/bin/env python3
"""Local state machine for authenticated project kernel updates."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from contextlib import contextmanager
from datetime import datetime, timezone
from functools import cmp_to_key
from pathlib import Path
from typing import Any, Callable, Iterator


SCHEMA_VERSION = 1
PROJECT_REPOSITORY = "xiaoyueyoqwq/secure-hibernate-kernel"
POLICIES = {"manual", "check-and-notify", "automatic-install"}
PROJECT_KERNEL_HISTORY_VALUES = {1, 2, 3}
SAFE_ASSET_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*$")
SOURCE_VERSION = re.compile(
    r"^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+"
    r"(?:[.+~][0-9A-Za-z.+~-]+)?$"
)
COMMIT = re.compile(r"^[0-9a-f]{40}$")
PROJECT_SUFFIXES = ("-s4lockdown", "-hibernate")


def is_project_kernel(release: str) -> bool:
    """Project kernels end with -hibernate; the published first Release used -s4lockdown."""
    return release.endswith(PROJECT_SUFFIXES)
MAX_ASSET_BYTES = 4 * 1024 * 1024 * 1024
MAX_RELEASE_BYTES = 6 * 1024 * 1024 * 1024
MAX_RELEASE_ASSETS = 32
COPY_BLOCK_BYTES = 1024 * 1024
LOCK_WAIT_SECONDS = 2 * 60 * 60
ProgressCallback = Callable[[int, int, str], None]
PhaseCallback = Callable[[str], None]
CHECK_PHASES = {
    "indexing",
    "downloading",
    "verifying-manifest",
    "verifying-packages",
    "authorizing-version",
}

INSTALL_PROGRESS = {
    "preparing": 5,
    "verifying-release": 65,
    "verifying-packages": 70,
    "installing-packages": 78,
    "configuring-system": 90,
    "complete": 100,
}

# The published first Release uses the -ubuntu28-s4lockdown kernel name. Its
# assets are immutable, so first installation keeps this exact embedded snapshot.
LEGACY_RELEASE_TAG = "ubuntu-7.0.0-28.28"
LEGACY_RELEASE_SOURCE_VERSION = "7.0.0-28.28"
LEGACY_RELEASE_KERNEL = "7.0.12-ubuntu28-s4lockdown"
LEGACY_RELEASE_COMMIT = "f0a48cafb7b8b8d8a647ed2975cfd6c6fafa8bd9"
LEGACY_RELEASE_LOCAL_VERSION = "-ubuntu28-s4lockdown"
LEGACY_RELEASE_ASSETS = {
    "kernel-release.txt": (
        27,
        "e08793949d946122e785654f9aaeff34a87b1209dcd6c283a80e33d2e0c53dff",
    ),
    "linux-headers-7.0.12-ubuntu28-s4lockdown_"
    "1-ubuntu28-s4lockdown+ubuntu7.0.0-28.28_amd64.deb": (
        11116306,
        "67e7d4a28cb8d6b2e4999b3e7adb92725cde0aecc8a5181c71fe0fc6055f0b12",
    ),
    "linux-image-7.0.12-ubuntu28-s4lockdown_"
    "1-ubuntu28-s4lockdown+ubuntu7.0.0-28.28_amd64.deb": (
        126937008,
        "0064675950e66af6cd7cee2b84937ecaf54ab43cdd9fc8fe4da5a5b29f49a81c",
    ),
    "local-version.txt": (
        21,
        "13aeaf86577d28b0fb253b87a2f486aeae8daa9abd425bec86ee335f9e04ddf0",
    ),
    "secure-hibernate-project.der": (
        1118,
        "5f59e3e38f5a3c3f276beca6c2abd3cb20296d7fd3d0a2db9dbc83b0dd889711",
    ),
    "secure-hibernate-project.pem": (
        1570,
        "a00ae020bbb6b04c19494a0d2bb52aa3ab8f75ebfa981e2455582a2c3be41558",
    ),
    "SHA256SUMS": (
        933,
        "1d0f77add6fdadb95c32f42380611fbc3a7c71c99572c228e6b276763444f9a7",
    ),
    "signed-linux-image-7.0.12-ubuntu28-s4lockdown_"
    "1-ubuntu28-s4lockdown+ubuntu7.0.0-28.28_amd64.deb": (
        129711872,
        "afd5c7f20a17d33a5e87b8776636cd469fc3ad301d63d0cf383fca7bff5890db",
    ),
    "ubuntu-source-package-version.txt": (
        12,
        "3095af523c910608903007d899631c8d72c10c2d6a298c8e397f3e371d7582ab",
    ),
}


class UpdateError(Exception):
    pass


class LockBusy(UpdateError):
    pass


def fail(message: str) -> None:
    raise UpdateError(message)


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def run(
    command: list[str],
    *,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            command,
            check=check,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
    except FileNotFoundError:
        fail(f"Required command not found: {command[0]}")
    except subprocess.CalledProcessError as error:
        output = error.stderr or error.stdout or b""
        detail = output.decode("utf-8", "replace").strip()[-16_384:]
        fail(detail or f"Command failed with status {error.returncode}: {command[0]}")


def require_directory(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"{label} does not exist: {path}")
    if not stat.S_ISDIR(metadata.st_mode):
        fail(f"{label} is not a directory: {path}")


def require_regular_file(path: Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular file: {path}")
    return metadata


def read_json(path: Path, *, required: bool = False) -> dict[str, Any]:
    try:
        require_regular_file(path, "JSON state")
    except UpdateError:
        if not required and not path.exists():
            return {}
        raise
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"Invalid JSON in {path}: {error}")
    if not isinstance(document, dict):
        fail(f"JSON state must be an object: {path}")
    return document


def write_json_atomic(path: Path, document: dict[str, Any], mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def update_json(path: Path, values: dict[str, Any]) -> None:
    document = read_json(path)
    document.setdefault("schema_version", SCHEMA_VERSION)
    document.update(values)
    write_json_atomic(path, document)


def record_install_progress(path: Path, phase: str) -> None:
    progress = INSTALL_PROGRESS.get(phase)
    if progress is None:
        fail(f"Unsupported installation phase: {phase}")
    update_json(
        path,
        {
            "install_phase": phase,
            "install_progress": progress,
            "install_updated_at": now(),
        },
    )


def read_configuration(path: Path) -> tuple[str, int]:
    if not path.exists():
        return "check-and-notify", 2
    require_regular_file(path, "Updater configuration")
    policy: str | None = None
    project_kernel_history: int | None = None
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except UnicodeDecodeError:
        fail(f"Updater configuration must contain ASCII text: {path}")
    for line_number, raw_line in enumerate(lines, 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("POLICY=") and policy is None:
            policy = line.removeprefix("POLICY=")
        elif line.startswith("PROJECT_KERNEL_HISTORY="):
            if project_kernel_history is not None:
                fail(f"Duplicate project kernel history at {path}:{line_number}")
            value = line.removeprefix("PROJECT_KERNEL_HISTORY=")
            if value not in {"1", "2", "3"}:
                fail(f"Unsupported project kernel history at {path}:{line_number}")
            project_kernel_history = int(value)
        else:
            fail(f"Unsupported updater configuration at {path}:{line_number}")
    if policy is None:
        policy = "check-and-notify"
    if policy not in POLICIES:
        fail(f"Unsupported update policy: {policy}")
    return policy, project_kernel_history if project_kernel_history is not None else 2


def read_policy(path: Path) -> str:
    return read_configuration(path)[0]


def read_project_kernel_history(path: Path) -> int:
    return read_configuration(path)[1]


def version_compare(left: str, operator: str, right: str) -> bool:
    if not SOURCE_VERSION.fullmatch(left) or not SOURCE_VERSION.fullmatch(right):
        fail(f"Invalid Ubuntu source version comparison: {left!r}, {right!r}")
    result = run(["dpkg", "--compare-versions", left, operator, right], check=False)
    return result.returncode == 0


def highest_version(versions: list[str]) -> str | None:
    highest: str | None = None
    for version in versions:
        if not SOURCE_VERSION.fullmatch(version):
            continue
        if highest is None or version_compare(version, "gt", highest):
            highest = version
    return highest


def compare_kernel_releases(left: str, right: str) -> int:
    if left == right:
        return 0
    if run(["dpkg", "--compare-versions", left, "gt", right], check=False).returncode == 0:
        return -1
    if run(["dpkg", "--compare-versions", left, "lt", right], check=False).returncode == 0:
        return 1
    fail(f"Could not compare project kernel releases: {left} and {right}")


def installed_project_kernel_packages() -> dict[str, list[str]]:
    result = run(
        [
            "dpkg-query", "-W",
            "-f=${binary:Package}\t${db:Status-Abbrev}\n",
            "linux-image-*", "linux-headers-*",
        ],
        capture=True,
    )
    packages: dict[str, list[str]] = {}
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        try:
            package, status = line.split("\t", 1)
        except ValueError:
            continue
        if status != "ii ":
            continue
        match = re.fullmatch(r"linux-(?:image|headers)-([0-9].*)", package)
        if match and is_project_kernel(match.group(1)):
            packages.setdefault(match.group(1), []).append(package)
    return packages


def prune_project_kernels(
    target_release: str,
    project_kernel_history: int,
    running_release: str,
    *,
    testing: bool,
) -> list[str]:
    if project_kernel_history not in PROJECT_KERNEL_HISTORY_VALUES:
        fail(f"Unsupported project kernel history: {project_kernel_history}")
    if testing:
        return []
    installed = installed_project_kernel_packages()
    image_releases = {
        release
        for release, packages in installed.items()
        if f"linux-image-{release}" in packages
    }
    if target_release not in image_releases:
        fail(f"The installed project kernel is missing from package state: {target_release}")
    historical = sorted(
        (release for release in image_releases if release != target_release),
        key=cmp_to_key(compare_kernel_releases),
    )
    keep = set(historical[:project_kernel_history])
    keep.update({target_release, running_release})
    remove_releases = [release for release in historical if release not in keep]
    if not remove_releases:
        return []
    packages = [
        package
        for release in remove_releases
        for package in installed[release]
    ]
    run(["dpkg", "--remove", *sorted(packages)])
    run(["/usr/sbin/update-grub"])
    return remove_releases


def installed_package_versions() -> list[str]:
    result = run(
        ["dpkg-query", "-W", "-f=${db:Status-Abbrev}\t${Package}\t${Version}\n"],
        capture=True,
    )
    versions: list[str] = []
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        fields = line.split("\t")
        if len(fields) != 3 or fields[0] != "ii ":
            continue
        package, package_version = fields[1], fields[2]
        if not package.startswith("linux-image-") or not is_project_kernel(package):
            continue
        marker = "+ubuntu"
        if marker not in package_version:
            continue
        source_version = package_version.rsplit(marker, 1)[1]
        if SOURCE_VERSION.fullmatch(source_version):
            versions.append(source_version)
    return versions


def detected_installed_versions(testing: bool) -> list[str]:
    if testing and os.environ.get("S4LOCKDOWN_TEST_IGNORE_SYSTEM_PACKAGES") == "1":
        return []
    return installed_package_versions()


def resolve_version(resolver: Path, requested: str) -> dict[str, str]:
    require_regular_file(resolver, "Version resolver")
    result = run([str(resolver), requested, "auto"], capture=True)
    values: dict[str, str] = {}
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    required = {"source_package_version", "marker_tag", "local_version"}
    if not required.issubset(values):
        fail("Version resolver returned incomplete metadata")
    if not SOURCE_VERSION.fullmatch(values["source_package_version"]):
        fail("Version resolver returned an invalid source package version")
    return values


@contextmanager
def update_lock(path: Path, *, wait: bool = False) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(
        path,
        os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"Updater lock must be a regular file: {path}")
        deadline = time.monotonic() + LOCK_WAIT_SECONDS
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not wait:
                    raise LockBusy("Another s4lockdown update operation is active")
                if time.monotonic() >= deadline:
                    fail("Timed out waiting for another s4lockdown update operation")
                time.sleep(0.5)
        yield
    finally:
        os.close(descriptor)


def safe_release_assets(directory: Path) -> list[Path]:
    require_directory(directory, "Release source directory")
    assets: list[Path] = []
    for entry in directory.iterdir():
        require_regular_file(entry, "Release source asset")
        if not SAFE_ASSET_NAME.fullmatch(entry.name):
            fail(f"Unsafe Release asset filename: {entry.name!r}")
        assets.append(entry)
    if not assets:
        fail(f"Release source directory is empty: {directory}")
    return sorted(assets, key=lambda path: path.name)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(COPY_BLOCK_BYTES):
            digest.update(block)
    return digest.hexdigest()


def copy_offline_release(source: Path, destination: Path) -> str | None:
    for asset in safe_release_assets(source):
        shutil.copyfile(asset, destination / asset.name, follow_symlinks=False)
    return None


def download_json(url: str) -> tuple[int, bytes]:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "secure-hibernate-kernel-updater/1",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, response.read(8 * 1024 * 1024)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return 404, b""
        fail(f"GitHub Release API returned HTTP {error.code}")
    except urllib.error.URLError as error:
        fail(f"GitHub Release API request failed: {error.reason}")


def download_asset(
    url: str,
    destination: Path,
    expected_size: int,
    completed_before: int,
    release_size: int,
    progress: ProgressCallback | None,
) -> None:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != "github.com":
        fail(f"Unexpected GitHub asset URL: {url}")
    if expected_size < 0 or expected_size > MAX_ASSET_BYTES:
        fail(f"GitHub asset size is outside the allowed range: {destination.name}")
    if destination.exists():
        metadata = require_regular_file(destination, "Downloaded Release asset")
        if metadata.st_size == expected_size:
            if progress:
                progress(completed_before + expected_size, release_size, destination.name)
            return
        destination.unlink()

    partial = destination.with_name(f".{destination.name}.part")
    copied = 0
    if partial.exists():
        metadata = require_regular_file(partial, "Partial Release asset")
        if metadata.st_size > expected_size:
            partial.unlink()
        else:
            copied = metadata.st_size
    if copied == expected_size:
        os.replace(partial, destination)
        if progress:
            progress(completed_before + copied, release_size, destination.name)
        return

    headers = {
        "Accept": "application/octet-stream",
        "User-Agent": "secure-hibernate-kernel-updater/1",
    }
    if copied:
        headers["Range"] = f"bytes={copied}-"
    request = urllib.request.Request(
        url,
        headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            response_status = response.getcode()
            if copied and response_status != 206:
                partial.unlink(missing_ok=True)
                return download_asset(
                    url, destination, expected_size, completed_before, release_size, progress
                )
            if copied:
                content_range = response.headers.get("Content-Range", "")
                if not content_range.startswith(f"bytes {copied}-"):
                    fail(f"GitHub returned an invalid resume range: {destination.name}")
            with partial.open("ab" if copied else "xb") as output:
                while True:
                    block = response.read(1024 * 1024)
                    if not block:
                        break
                    copied += len(block)
                    if copied > expected_size or copied > MAX_ASSET_BYTES:
                        fail(f"GitHub asset exceeded its advertised size: {destination.name}")
                    output.write(block)
                    if progress:
                        progress(completed_before + copied, release_size, destination.name)
                output.flush()
                os.fsync(output.fileno())
    except urllib.error.HTTPError as error:
        if error.code == 416 and copied == expected_size:
            os.replace(partial, destination)
            return
        fail(f"GitHub asset download returned HTTP {error.code}: {destination.name}")
    except urllib.error.URLError as error:
        fail(f"GitHub asset download failed for {destination.name}: {error.reason}")
    if partial.stat().st_size != expected_size:
        fail(f"GitHub asset size differs from API metadata: {destination.name}")
    os.replace(partial, destination)
    if progress:
        progress(completed_before + expected_size, release_size, destination.name)


def download_github_release(
    repository: str,
    tag: str,
    destination: Path,
    progress: ProgressCallback | None = None,
) -> tuple[bool, str | None]:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        fail(f"Invalid GitHub repository: {repository}")
    encoded_tag = urllib.parse.quote(tag, safe="")
    status, content = download_json(
        f"https://api.github.com/repos/{repository}/releases/tags/{encoded_tag}"
    )
    if status == 404:
        return False, None
    try:
        document = json.loads(content)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"GitHub Release API returned invalid JSON: {error}")
    if not isinstance(document, dict):
        fail("GitHub Release API response is not an object")
    if (
        document.get("tag_name") != tag
        or document.get("draft") is not False
        or document.get("prerelease") is not False
    ):
        fail("GitHub Release metadata does not describe the requested published tag")
    assets = document.get("assets")
    if not isinstance(assets, list):
        fail("GitHub Release metadata has no asset list")

    seen: set[str] = set()
    total_size = 0
    downloads: list[tuple[str, str, int]] = []
    api_assets: dict[str, tuple[int, str | None]] = {}
    for asset in assets:
        if not isinstance(asset, dict):
            fail("GitHub Release contains malformed asset metadata")
        name = asset.get("name")
        url = asset.get("browser_download_url")
        size = asset.get("size")
        digest = asset.get("digest")
        if not isinstance(name, str) or not SAFE_ASSET_NAME.fullmatch(name):
            fail(f"GitHub Release contains an unsafe asset name: {name!r}")
        if name in seen:
            fail(f"GitHub Release contains a duplicate asset: {name}")
        expected_url = (
            f"https://github.com/{repository}/releases/download/{encoded_tag}/"
            f"{urllib.parse.quote(name, safe='')}"
        )
        if url != expected_url:
            fail(f"GitHub Release contains an unexpected asset URL: {name}")
        if not isinstance(size, int) or isinstance(size, bool):
            fail(f"GitHub Release contains an invalid asset size: {name}")
        total_size += size
        if total_size > MAX_RELEASE_BYTES:
            fail("GitHub Release exceeds the total download size limit")
        seen.add(name)
        downloads.append((name, url, size))
        api_assets[name] = (size, digest if isinstance(digest, str) else None)
    if len(downloads) > MAX_RELEASE_ASSETS:
        fail("GitHub Release contains too many assets")

    manifest_assets = {"release-manifest.json", "release-manifest.p7s"}
    if manifest_assets.difference(seen):
        if repository != PROJECT_REPOSITORY or tag != LEGACY_RELEASE_TAG:
            return False, None
        target = document.get("target_commitish")
        if target != LEGACY_RELEASE_COMMIT:
            fail("Legacy Release points to an unexpected Git commit")
        expected_names = set(LEGACY_RELEASE_ASSETS)
        if seen != expected_names:
            missing = sorted(expected_names.difference(seen))
            unexpected = sorted(seen.difference(expected_names))
            fail(
                "Legacy Release asset set differs from the pinned snapshot: "
                f"missing={missing}, unexpected={unexpected}"
            )
        for name, (expected_size, expected_digest) in LEGACY_RELEASE_ASSETS.items():
            size, digest = api_assets[name]
            if size != expected_size or digest != f"sha256:{expected_digest}":
                fail(f"Legacy Release API metadata differs from the pinned asset: {name}")

    completed = 0
    for name, url, size in sorted(downloads):
        download_asset(url, destination / name, size, completed, total_size, progress)
        completed += size
    target = document.get("target_commitish")
    return True, target if isinstance(target, str) and COMMIT.fullmatch(target) else None


def variant_kernel_release(
    repository: str,
    tag: str,
    testing: bool,
) -> str | None:
    """Kernel release of the same-source patch-variant Release, if any.

    The variant tag is the marker tag derived from the resolved Ubuntu
    source version, e.g. ubuntu-7.0.0-29.29-vmstat, so it is never
    inferred from an unverified source.  The result is advisory only: it
    decides whether an update is offered, while the staged Release still
    undergoes full Manifest and package verification before installation.
    """
    if testing:
        variant_dir = os.environ.get("S4LOCKDOWN_TEST_VARIANT_RELEASE")
        if not variant_dir:
            return None
        release_file = Path(variant_dir).resolve() / "kernel-release.txt"
        if not release_file.is_file():
            return None
        release = release_file.read_text(encoding="utf-8").strip()
        return release or None

    encoded_tag = urllib.parse.quote(tag, safe="")
    status, content = download_json(
        f"https://api.github.com/repos/{repository}/releases/tags/{encoded_tag}"
    )
    if status == 404:
        return None
    try:
        document = json.loads(content)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"GitHub Release API returned invalid JSON: {error}")
    if not isinstance(document, dict):
        fail("GitHub Release API response is not an object")
    for asset in document.get("assets", []):
        if not isinstance(asset, dict):
            continue
        name = asset.get("name")
        url = asset.get("browser_download_url")
        size = asset.get("size")
        if name != "kernel-release.txt" or not isinstance(url, str):
            continue
        if not isinstance(size, int) or isinstance(size, bool):
            fail("GitHub variant Release has an invalid kernel-release.txt size")
        probe_dir = Path(tempfile.mkdtemp(prefix=".variant-probe."))
        try:
            probe = probe_dir / "kernel-release.txt"
            download_asset(url, probe, size, 0, size, None)
            release = probe.read_text(encoding="utf-8").strip()
        finally:
            shutil.rmtree(probe_dir, ignore_errors=True)
        return release or None
    return None


def tool_paths() -> tuple[Path, Path, Path, Path]:
    repo_root = Path(__file__).resolve().parent.parent
    return (
        repo_root / "scripts" / "resolve-version.sh",
        repo_root / "scripts" / "release-manifest.py",
        repo_root / "scripts" / "install-signed-packages.sh",
        repo_root / "certs" / "secure-hibernate-project.pem",
    )


def runtime_paths() -> tuple[Path, Path, Path, Path, Path, bool]:
    test_root_value = os.environ.get("S4LOCKDOWN_TEST_ROOT")
    if test_root_value:
        test_root = Path(test_root_value).resolve()
        return (
            test_root / "var/cache/s4lockdown-update",
            test_root / "var/lib/s4lockdown-update",
            test_root / "etc/s4lockdown-update.conf",
            test_root / "run/reboot-required",
            test_root / "run/reboot-required.pkgs",
            True,
        )
    return (
        Path("/var/cache/s4lockdown-update"),
        Path("/var/lib/s4lockdown-update"),
        Path("/etc/s4lockdown-update.conf"),
        Path("/run/reboot-required"),
        Path("/run/reboot-required.pkgs"),
        False,
    )


def runtime_lock_path(cache_dir: Path, state_dir: Path, testing: bool) -> Path:
    return cache_dir / "update.lock" if testing else state_dir / "update.lock"


def package_tool_path(default: Path, testing: bool) -> Path:
    override = os.environ.get("S4LOCKDOWN_TEST_PACKAGE_TOOL") if testing else None
    path = Path(override).resolve() if override else default
    require_regular_file(path, "Signed-package verifier")
    if not os.access(path, os.X_OK):
        fail(f"Signed-package verifier is not executable: {path}")
    return path


def verify_release(
    directory: Path,
    manifest_tool: Path,
    package_tool: Path,
    certificate: Path,
    tag: str,
    minimum_version: str | None,
    expected_commit: str | None,
    phase: PhaseCallback | None = None,
) -> dict[str, Any]:
    if tag == LEGACY_RELEASE_TAG:
        if phase:
            phase("verifying-manifest")
        assets = safe_release_assets(directory)
        names = {asset.name for asset in assets}
        expected_names = set(LEGACY_RELEASE_ASSETS)
        if names != expected_names:
            missing = sorted(expected_names.difference(names))
            unexpected = sorted(names.difference(expected_names))
            fail(
                "Legacy Release asset set differs from the pinned snapshot: "
                f"missing={missing}, unexpected={unexpected}"
            )
        for asset in assets:
            expected_size, expected_digest = LEGACY_RELEASE_ASSETS[asset.name]
            metadata = require_regular_file(asset, "Legacy Release asset")
            if metadata.st_size != expected_size:
                fail(f"Legacy Release asset size differs from the pinned value: {asset.name}")
            if sha256_file(asset) != expected_digest:
                fail(f"Legacy Release asset digest differs from the pinned value: {asset.name}")
        if expected_commit and expected_commit != LEGACY_RELEASE_COMMIT:
            fail("Legacy Release Git commit differs from the pinned value")
        if phase:
            phase("verifying-packages")
        run([str(package_tool), "--check-only", str(directory), str(certificate)])
        if phase:
            phase("authorizing-version")
        if minimum_version and version_compare(
            LEGACY_RELEASE_SOURCE_VERSION, "lt", minimum_version
        ):
            fail(
                "Release source version is older than the installed version: "
                f"{LEGACY_RELEASE_SOURCE_VERSION} < {minimum_version}"
            )
        return {
            "schema_version": SCHEMA_VERSION,
            "release_tag": LEGACY_RELEASE_TAG,
            "ubuntu_source_package_version": LEGACY_RELEASE_SOURCE_VERSION,
            "kernel_release": LEGACY_RELEASE_KERNEL,
            "local_version": LEGACY_RELEASE_LOCAL_VERSION,
            "git_commit": LEGACY_RELEASE_COMMIT,
        }

    command = [
        str(manifest_tool),
        "verify",
        str(directory),
        "--expected-release-tag",
        tag,
    ]
    if expected_commit:
        command.extend(["--expected-git-commit", expected_commit])
    if phase:
        phase("verifying-manifest")
    run(command)
    if phase:
        phase("verifying-packages")
    run([str(package_tool), "--check-only", str(directory), str(certificate)])
    manifest = read_json(directory / "release-manifest.json", required=True)
    if phase:
        phase("authorizing-version")
    source_version = manifest.get("ubuntu_source_package_version")
    if not isinstance(source_version, str):
        fail("Verified Release Manifest has no Ubuntu source package version")
    if minimum_version and version_compare(source_version, "lt", minimum_version):
        fail(
            "Release source version is older than the installed version: "
            f"{source_version} < {minimum_version}"
        )
    return manifest


def replace_directory(source: Path, destination: Path) -> None:
    retired = destination.with_name(f".{destination.name}.retired.{os.getpid()}")
    if retired.exists():
        shutil.rmtree(retired)
    if destination.exists():
        os.replace(destination, retired)
    try:
        os.replace(source, destination)
    except Exception:
        if retired.exists() and not destination.exists():
            os.replace(retired, destination)
        raise
    if retired.exists():
        shutil.rmtree(retired)


def remove_path(path: Path) -> None:
    metadata = path.lstat()
    if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
        shutil.rmtree(path)
    else:
        path.unlink()


def cleanup_stale_paths(directory: Path, patterns: tuple[re.Pattern[str], ...]) -> None:
    if not directory.exists():
        return
    require_directory(directory, "Updater working directory")
    for entry in directory.iterdir():
        if any(pattern.fullmatch(entry.name) for pattern in patterns):
            remove_path(entry)


def check_command(arguments: argparse.Namespace) -> int:
    cache_dir, state_dir, config_file, _, _, testing = runtime_paths()
    resolver, manifest_tool, default_package_tool, certificate = tool_paths()
    package_tool = package_tool_path(default_package_tool, testing)
    cache_dir.mkdir(parents=True, exist_ok=True)
    check_state = cache_dir / "check-state.json"
    failed_phase = "indexing"
    candidate: str | None = None
    tag: str | None = None

    try:
        with update_lock(
            runtime_lock_path(cache_dir, state_dir, testing),
            wait=arguments.wait_for_lock,
        ):
            cleanup_stale_paths(
                cache_dir,
                (
                    re.compile(r"^\.incoming\.[A-Za-z0-9_]+$"),
                    re.compile(r"^\.staged\.retired\.[0-9]+$"),
                ),
            )
            policy, _project_kernel_history = read_configuration(config_file)
            if policy == "manual" and not arguments.force:
                write_json_atomic(
                    check_state,
                    {"schema_version": SCHEMA_VERSION, "status": "manual", "checked_at": now()},
                )
                return 0

            resolved = resolve_version(resolver, arguments.source_version)
            candidate = resolved["source_package_version"]
            tag = resolved["marker_tag"]
            repository = os.environ.get(
                "S4LOCKDOWN_GITHUB_REPOSITORY", PROJECT_REPOSITORY
            )
            partial = cache_dir / f".partial.{tag}"
            for entry in cache_dir.iterdir():
                if entry.name.startswith(".partial.") and entry != partial:
                    remove_path(entry)
            root_state = read_json(state_dir / "state.json")
            installed_versions = detected_installed_versions(testing)
            if arguments.installed_source_version:
                installed_versions.append(arguments.installed_source_version)
            recorded_installed = root_state.get("installed_source_version")
            if isinstance(recorded_installed, str):
                installed_versions.append(recorded_installed)
            installed = highest_version(installed_versions)

            installation_already_recorded = (
                isinstance(recorded_installed, str)
                and version_compare(candidate, "eq", recorded_installed)
            )
            variant_update_available = False
            if installed and installation_already_recorded:
                recorded_kernel = root_state.get("installed_kernel_release")
                if isinstance(recorded_kernel, str):
                    variant = variant_kernel_release(repository, tag, testing)
                    if variant and compare_kernel_releases(variant, recorded_kernel) < 0:
                        variant_update_available = True
            if installed and (
                version_compare(candidate, "lt", installed)
                or (
                    version_compare(candidate, "eq", installed)
                    and installation_already_recorded
                    and not variant_update_available
                )
            ):
                if partial.exists():
                    remove_path(partial)
                status = (
                    "downgrade-refused"
                    if version_compare(candidate, "lt", installed)
                    else "current"
                )
                write_json_atomic(
                    check_state,
                    {
                        "schema_version": SCHEMA_VERSION,
                        "status": status,
                        "checked_at": now(),
                        "candidate_source_version": candidate,
                        "installed_source_version": installed,
                    },
                )
                return 0

            available = root_state.get("available_source_version")
            if available == candidate and (state_dir / "available").is_dir():
                if partial.exists():
                    remove_path(partial)
                write_json_atomic(
                    check_state,
                    {
                        "schema_version": SCHEMA_VERSION,
                        "status": "already-staged",
                        "checked_at": now(),
                        "candidate_source_version": candidate,
                        "release_tag": tag,
                    },
                )
                return 0

            def record_phase(status: str) -> None:
                nonlocal failed_phase
                if status not in CHECK_PHASES:
                    fail(f"Unsupported updater check phase: {status}")
                failed_phase = status
                write_json_atomic(
                    check_state,
                    {
                        "schema_version": SCHEMA_VERSION,
                        "status": status,
                        "checked_at": now(),
                        "candidate_source_version": candidate,
                        "release_tag": tag,
                    },
                )

            staged = cache_dir / "staged"
            if staged.exists():
                try:
                    require_directory(staged, "Staged Release")
                    manifest = verify_release(
                        staged,
                        manifest_tool,
                        package_tool,
                        certificate,
                        tag,
                        installed,
                        None,
                        record_phase,
                    )
                except (OSError, UpdateError):
                    remove_path(staged)
                else:
                    write_json_atomic(
                        check_state,
                        {
                            "schema_version": SCHEMA_VERSION,
                            "status": "already-staged",
                            "checked_at": now(),
                            "candidate_source_version": manifest[
                                "ubuntu_source_package_version"
                            ],
                            "kernel_release": manifest["kernel_release"],
                            "release_tag": manifest["release_tag"],
                            "git_commit": manifest["git_commit"],
                        },
                    )
                    return 0

            staging = partial if not arguments.source_dir else Path(
                tempfile.mkdtemp(prefix=".incoming.", dir=cache_dir)
            )
            if not staging.exists():
                staging.mkdir(mode=0o700)
            retain_partial = not bool(arguments.source_dir)
            last_progress_write = 0.0
            failed_phase = "indexing"
            write_json_atomic(
                check_state,
                {
                    "schema_version": SCHEMA_VERSION,
                    "status": "indexing",
                    "checked_at": now(),
                    "candidate_source_version": candidate,
                    "release_tag": tag,
                },
            )

            def record_progress(downloaded: int, total: int, asset: str) -> None:
                nonlocal failed_phase, last_progress_write
                failed_phase = "downloading"
                current_time = time.monotonic()
                if downloaded < total and current_time - last_progress_write < 0.2:
                    return
                last_progress_write = current_time
                write_json_atomic(
                    check_state,
                    {
                        "schema_version": SCHEMA_VERSION,
                        "status": "downloading",
                        "checked_at": now(),
                        "candidate_source_version": candidate,
                        "release_tag": tag,
                        "downloaded_bytes": downloaded,
                        "total_bytes": total,
                        "current_asset": asset,
                    },
                )

            try:
                expected_commit: str | None
                if arguments.source_dir:
                    record_phase("downloading")
                    expected_commit = copy_offline_release(
                        Path(arguments.source_dir).resolve(), staging
                    )
                    release_exists = True
                else:
                    release_exists, expected_commit = download_github_release(
                        repository, tag, staging, record_progress
                    )
                if not release_exists:
                    if staging.exists():
                        shutil.rmtree(staging)
                    write_json_atomic(
                        check_state,
                        {
                            "schema_version": SCHEMA_VERSION,
                            "status": "release-unavailable",
                            "checked_at": now(),
                            "candidate_source_version": candidate,
                            "release_tag": tag,
                        },
                    )
                    return 0
                try:
                    manifest = verify_release(
                        staging,
                        manifest_tool,
                        package_tool,
                        certificate,
                        tag,
                        installed,
                        expected_commit,
                        record_phase,
                    )
                except Exception:
                    retain_partial = False
                    raise
                replace_directory(staging, cache_dir / "staged")
                retain_partial = False
                write_json_atomic(
                    check_state,
                    {
                        "schema_version": SCHEMA_VERSION,
                        "status": "verified",
                        "checked_at": now(),
                        "candidate_source_version": manifest[
                            "ubuntu_source_package_version"
                        ],
                        "kernel_release": manifest["kernel_release"],
                        "release_tag": manifest["release_tag"],
                        "git_commit": manifest["git_commit"],
                    },
                )
            finally:
                if staging.exists() and not retain_partial:
                    shutil.rmtree(staging)
    except LockBusy as error:
        print(f"s4lockdown-update: {error}", file=sys.stderr)
        return 75
    except (OSError, UpdateError) as error:
        try:
            failure_state: dict[str, Any] = {
                "schema_version": SCHEMA_VERSION,
                "status": "check-failed",
                "checked_at": now(),
                "failed_phase": failed_phase,
                "error": str(error),
            }
            if candidate is not None:
                failure_state["candidate_source_version"] = candidate
            if tag is not None:
                failure_state["release_tag"] = tag
            write_json_atomic(
                check_state,
                failure_state,
            )
        except OSError:
            pass
        print(f"s4lockdown-update: {error}", file=sys.stderr)
        return 1
    return 0


def copy_file_to_root(
    source_directory_fd: int,
    destination_directory_fd: int,
    name: str,
) -> int:
    source_fd = os.open(
        name,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        dir_fd=source_directory_fd,
    )
    try:
        source_metadata = os.fstat(source_fd)
        if not stat.S_ISREG(source_metadata.st_mode):
            fail(f"Staged Release asset must be a regular file: {name}")
        if source_metadata.st_size > MAX_ASSET_BYTES:
            fail(f"Staged Release asset exceeds the size limit: {name}")
        destination_fd = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
            dir_fd=destination_directory_fd,
        )
        try:
            copied = 0
            while True:
                block = os.read(source_fd, COPY_BLOCK_BYTES)
                if not block:
                    break
                copied += len(block)
                if copied > source_metadata.st_size or copied > MAX_ASSET_BYTES:
                    fail(f"Staged Release asset changed while being copied: {name}")
                remaining = memoryview(block)
                while remaining:
                    written = os.write(destination_fd, remaining)
                    if written <= 0:
                        fail(f"Could not copy staged Release asset: {name}")
                    remaining = remaining[written:]
            if copied != source_metadata.st_size:
                fail(f"Staged Release asset changed while being copied: {name}")
            os.fchmod(destination_fd, 0o600)
            os.fsync(destination_fd)
        finally:
            os.close(destination_fd)
    finally:
        os.close(source_fd)
    return source_metadata.st_size


def copy_staged_to_root(cache_dir: Path, state_dir: Path) -> Path | None:
    staged = cache_dir / "staged"
    if not staged.exists():
        return None
    require_directory(staged, "Staged Release")
    incoming = state_dir / f".incoming.{os.getpid()}"
    if incoming.exists():
        remove_path(incoming)
    incoming.mkdir(mode=0o700)
    source_directory_fd = -1
    destination_directory_fd = -1
    try:
        source_directory_fd = os.open(
            staged,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        destination_directory_fd = os.open(
            incoming,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        names = sorted(os.listdir(source_directory_fd))
        if not names:
            fail("Staged Release directory is empty")
        if len(names) > MAX_RELEASE_ASSETS:
            fail("Staged Release contains too many assets")
        total_size = 0
        for name in names:
            if not SAFE_ASSET_NAME.fullmatch(name):
                fail(f"Unsafe staged Release asset filename: {name!r}")
            total_size += copy_file_to_root(
                source_directory_fd, destination_directory_fd, name
            )
            if total_size > MAX_RELEASE_BYTES:
                fail("Staged Release exceeds the total size limit")
        os.fsync(destination_directory_fd)
        shutil.rmtree(staged)
    except Exception:
        if incoming.exists():
            remove_path(incoming)
        raise
    finally:
        if destination_directory_fd >= 0:
            os.close(destination_directory_fd)
        if source_directory_fd >= 0:
            os.close(source_directory_fd)
    return incoming


def package_manager_busy(testing: bool) -> bool:
    if testing and os.environ.get("S4LOCKDOWN_TEST_DPKG_BUSY") == "1":
        return True
    lock_paths = [Path("/var/lib/dpkg/lock-frontend"), Path("/var/lib/dpkg/lock")]
    for path in lock_paths:
        if not path.exists():
            continue
        result = run(["fuser", "-s", str(path)], check=False)
        if result.returncode == 0:
            return True
        if result.returncode not in {1}:
            fail(f"Could not inspect package-manager lock: {path}")
    return False


def notify(message: str, testing: bool) -> None:
    if testing:
        return
    try:
        subprocess.run(
            ["wall", "--nobanner"],
            input=(message + "\n").encode(),
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        pass


def propagate_check_state(root_state_path: Path, check_state_path: Path) -> None:
    check_state = read_json(check_state_path)
    if not check_state:
        return
    values: dict[str, Any] = {
        "last_check_status": check_state.get("status", "unknown"),
        "last_checked_at": check_state.get("checked_at", now()),
    }
    for field in ("candidate_source_version", "release_tag", "failed_phase", "error"):
        if field in check_state:
            values[field] = check_state[field]
    update_json(root_state_path, values)


def install_command(arguments: argparse.Namespace) -> int:
    cache_dir, state_dir, config_file, reboot_file, reboot_packages, testing = runtime_paths()
    if os.geteuid() != 0 and not testing:
        print("s4lockdown-update: install must run as root", file=sys.stderr)
        return 1
    resolver, manifest_tool, default_package_tool, certificate = tool_paths()
    package_tool = package_tool_path(default_package_tool, testing)
    cache_dir.mkdir(parents=True, exist_ok=True)
    state_dir.mkdir(parents=True, exist_ok=True)
    root_state_path = state_dir / "state.json"
    incoming: Path | None = None

    try:
        record_install_progress(root_state_path, "preparing")
        with update_lock(runtime_lock_path(cache_dir, state_dir, testing)):
            cleanup_stale_paths(
                state_dir,
                (
                    re.compile(r"^\.incoming\.[0-9]+$"),
                    re.compile(r"^\.available\.retired\.[0-9]+$"),
                ),
            )
            policy, project_kernel_history = read_configuration(config_file)
            incoming = copy_staged_to_root(cache_dir, state_dir)
            root_state = read_json(root_state_path)
            installed_versions = detected_installed_versions(testing)
            recorded = root_state.get("installed_source_version")
            if isinstance(recorded, str):
                installed_versions.append(recorded)
            installed = highest_version(installed_versions)

            candidate_dir = incoming if incoming else state_dir / "available"
            if not candidate_dir.is_dir():
                propagate_check_state(root_state_path, cache_dir / "check-state.json")
                if arguments.force:
                    fail("No verified Release is staged for installation")
                return 0
            expected = resolve_version(resolver, "auto")
            def install_phase(phase: str) -> None:
                mapped_phase = "verifying-release" if phase == "verifying-manifest" else (
                    "verifying-packages"
                    if phase in {"verifying-packages", "authorizing-version"}
                    else phase
                )
                record_install_progress(root_state_path, mapped_phase)

            manifest = verify_release(
                candidate_dir,
                manifest_tool,
                package_tool,
                certificate,
                expected["marker_tag"],
                installed,
                None,
                install_phase,
            )
            candidate = manifest["ubuntu_source_package_version"]
            if candidate != expected["source_package_version"]:
                fail(
                    "Staged Release source version does not match the current "
                    f"Ubuntu HWE candidate: {candidate} != "
                    f"{expected['source_package_version']}"
                )
            installation_already_recorded = (
                isinstance(recorded, str)
                and version_compare(candidate, "eq", recorded)
            )
            variant_update_available = False
            if installation_already_recorded:
                recorded_kernel = root_state.get("installed_kernel_release")
                candidate_kernel = manifest.get("kernel_release")
                if (
                    isinstance(recorded_kernel, str)
                    and isinstance(candidate_kernel, str)
                    and compare_kernel_releases(candidate_kernel, recorded_kernel) < 0
                ):
                    variant_update_available = True
            if installed and (
                version_compare(candidate, "lt", installed)
                or (
                    version_compare(candidate, "eq", installed)
                    and installation_already_recorded
                    and not variant_update_available
                )
            ):
                if incoming:
                    shutil.rmtree(incoming)
                    incoming = None
                elif candidate_dir == state_dir / "available":
                    shutil.rmtree(candidate_dir)
                update_json(
                    root_state_path,
                    {
                        "last_check_status": "current",
                        "last_checked_at": now(),
                        "installed_source_version": installed,
                        "available_source_version": None,
                        "available_kernel_release": None,
                        "available_release_tag": None,
                        "available_git_commit": None,
                    },
                )
                return 0
            if incoming:
                replace_directory(incoming, state_dir / "available")
                incoming = None
                candidate_dir = state_dir / "available"

            available_values = {
                "last_checked_at": now(),
                "available_source_version": candidate,
                "available_kernel_release": manifest["kernel_release"],
                "available_release_tag": manifest["release_tag"],
                "available_git_commit": manifest["git_commit"],
            }
            if policy != "automatic-install" and not arguments.force:
                should_notify = not (
                    root_state.get("available_source_version") == candidate
                    and root_state.get("last_check_status") == "update-available"
                )
                update_json(
                    root_state_path,
                    {**available_values, "last_check_status": "update-available"},
                )
                if should_notify:
                    notify(
                        f"A verified project kernel update is available: {candidate}. "
                        "Installation requires explicit approval.",
                        testing,
                    )
                return 0

            if package_manager_busy(testing):
                update_json(
                    root_state_path,
                    {**available_values, "last_check_status": "package-manager-busy"},
                )
                return 0

            running_kernel = os.uname().release
            record_install_progress(root_state_path, "installing-packages")
            try:
                run(
                    [
                        str(package_tool),
                        "--install-only",
                        str(candidate_dir),
                        str(certificate),
                    ],
                    capture=True,
                )
            except UpdateError as error:
                update_json(
                    root_state_path,
                    {
                        **available_values,
                        "last_check_status": "install-failed",
                        "last_install_error": str(error),
                    },
                )
                raise

            record_install_progress(root_state_path, "configuring-system")
            pruned_releases = prune_project_kernels(
                manifest["kernel_release"],
                project_kernel_history,
                running_kernel,
                testing=testing,
            )

            reboot_file.parent.mkdir(parents=True, exist_ok=True)
            reboot_file.write_text("System restart required\n", encoding="ascii")
            package_name = f"linux-image-{manifest['kernel_release']}"
            existing_packages = ""
            if reboot_packages.exists():
                existing_packages = reboot_packages.read_text(
                    encoding="utf-8", errors="replace"
                )
            package_lines = {line for line in existing_packages.splitlines() if line}
            package_lines.add(package_name)
            reboot_packages.write_text(
                "".join(f"{line}\n" for line in sorted(package_lines)), encoding="utf-8"
            )
            shutil.rmtree(candidate_dir)
            update_json(
                root_state_path,
                {
                    "last_check_status": "installed-reboot-required",
                    "last_checked_at": now(),
                    "last_installed_at": now(),
                    "installed_source_version": candidate,
                    "installed_kernel_release": manifest["kernel_release"],
                    "installed_release_tag": manifest["release_tag"],
                    "installed_git_commit": manifest["git_commit"],
                    "previous_running_kernel": running_kernel,
                    "project_kernel_history": project_kernel_history,
                    "pruned_project_kernels": pruned_releases,
                    "install_phase": "complete",
                    "install_progress": INSTALL_PROGRESS["complete"],
                    "install_updated_at": now(),
                    "reboot_required": True,
                    "last_install_error": None,
                    "available_source_version": None,
                    "available_kernel_release": None,
                    "available_release_tag": None,
                    "available_git_commit": None,
                },
            )
            notify(
                f"project kernel {manifest['kernel_release']} was installed. "
                "Restart when convenient; the system will not restart automatically.",
                testing,
            )
    except LockBusy as error:
        print(f"s4lockdown-update: {error}", file=sys.stderr)
        return 75
    except (OSError, UpdateError) as error:
        if incoming and incoming.exists():
            shutil.rmtree(incoming)
        try:
            current = read_json(root_state_path)
            update_json(
                root_state_path,
                {
                    "install_phase": "failed",
                    "install_progress": current.get("install_progress", 0),
                    "install_updated_at": now(),
                },
            )
        except (OSError, UpdateError) as state_error:
            print(
                f"s4lockdown-update: could not record installation failure: {state_error}",
                file=sys.stderr,
            )
        print(f"s4lockdown-update: {error}", file=sys.stderr)
        return 1
    return 0


def status_command() -> int:
    cache_dir, state_dir, config_file, _, _, _ = runtime_paths()
    output = {
        "policy": read_policy(config_file),
        "project_kernel_history": read_project_kernel_history(config_file),
        "state": read_json(state_dir / "state.json"),
        "check": read_json(cache_dir / "check-state.json"),
    }
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser("check", help="resolve, download, and verify an update")
    check.add_argument("--source-version", default="auto")
    check.add_argument("--source-dir")
    check.add_argument("--installed-source-version")
    check.add_argument("--force", action="store_true")
    check.add_argument("--wait-for-lock", action="store_true")

    install = subparsers.add_parser("install", help="re-verify and process a staged update")
    install.add_argument("--force", action="store_true")
    subparsers.add_parser("status", help="print updater state as JSON")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.command == "check":
            return check_command(arguments)
        if arguments.command == "install":
            return install_command(arguments)
        return status_command()
    except (OSError, UpdateError) as error:
        print(f"s4lockdown-update: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
