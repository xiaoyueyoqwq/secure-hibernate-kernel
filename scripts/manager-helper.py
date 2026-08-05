#!/usr/bin/env python3
"""Fixed privileged operations for Secure Hibernate Manager."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence


SCHEMA_VERSION = 1
PROJECT_FINGERPRINT = "5F:59:E3:E3:8F:5A:3C:3F:27:6B:EC:A6:C2:AB:D3:CB:20:29:6D:7F:D3:D0:A2:DB:9D:BC:83:B0:DD:88:97:11"
PROJECT_RELEASE = re.compile(r"^[0-9][0-9A-Za-z.+~-]*-(?:s4lockdown|hibernate)$")
MOK_PASSWORD_PATTERN = re.compile(r"[a-z]{3}[0-9]{5}")
LEGACY_MOK_PASSWORD_PATTERN = re.compile(r"[A-Za-z0-9]{12}")
STORED_MOK_PASSWORD_PATTERN = re.compile(r"(?:[a-z]{3}[0-9]{5}|[A-Za-z0-9]{12})")
MOK_PASSWORD_LETTERS = "abcdefghjkmnpqrstuvwxyz"
MOK_PASSWORD_DIGITS = "23456789"
POLICIES = {"manual", "check-and-notify", "automatic-install"}
PROJECT_KERNEL_HISTORY_VALUES = {1, 2, 3}
INSTALL_ROOT = Path("/usr/local/lib/s4lockdown-update")
CERTIFICATE_DER = INSTALL_ROOT / "certs/secure-hibernate-project.der"
UPDATE_TOOL = INSTALL_ROOT / "scripts/update-local.sh"
SYSTEM_CONFIG_TOOL = INSTALL_ROOT / "scripts/install-system-config.sh"
CHECK_UNIT = "s4lockdown-update-manager-check.service"
CONFIG_PATH = Path("/etc/s4lockdown-update.conf")
GRUB_PROJECT_CONFIG_PATH = Path("/etc/default/grub.d/99-s4lockdown.cfg")
FSTAB_PATH = Path("/etc/fstab")
ROOT_STATE_PATH = Path("/var/lib/s4lockdown-update/state.json")
CHECK_STATE_PATH = Path("/var/cache/s4lockdown-update/check-state.json")
STAGED_RELEASE_PATH = Path("/var/cache/s4lockdown-update/staged")
AVAILABLE_RELEASE_PATH = Path("/var/lib/s4lockdown-update/available")
MOK_STATE_PATH = Path("/var/lib/s4lockdown-update/manager-mok-enrollment.json")
TPM_BACKUP_DIRECTORY = Path("/var/lib/s4lockdown-update/luks-header-backups")
CRYPTTAB_PATH = Path("/etc/crypttab")
BOOT_DIRECTORY = Path("/boot")
HELPER_LOCK_PATH = Path("/run/lock/s4lockdown-manager.lock")
MEMINFO_PATH = Path("/proc/meminfo")
SWAPS_PATH = Path("/proc/swaps")
MANAGED_SWAP_PATH = Path("/swap.img")
GIB = 1024 * 1024 * 1024
MAX_PASSWORD_BYTES = 4096

EXECUTABLES = {
    "cryptsetup": Path("/usr/sbin/cryptsetup"),
    "dpkg": Path("/usr/bin/dpkg"),
    "dpkg_query": Path("/usr/bin/dpkg-query"),
    "dracut": Path("/usr/bin/dracut"),
    "fallocate": Path("/usr/bin/fallocate"),
    "findmnt": Path("/usr/bin/findmnt"),
    "lsinitrd": Path("/usr/bin/lsinitrd"),
    "lsblk": Path("/usr/bin/lsblk"),
    "mkswap": Path("/usr/sbin/mkswap"),
    "mokutil": Path("/usr/bin/mokutil"),
    "openssl": Path("/usr/bin/openssl"),
    "swapoff": Path("/usr/sbin/swapoff"),
    "swapon": Path("/usr/sbin/swapon"),
    "systemctl": Path("/usr/bin/systemctl"),
    "systemd_ask_password": Path("/usr/bin/systemd-ask-password"),
    "systemd_cryptenroll": Path("/usr/bin/systemd-cryptenroll"),
    "tpm2": Path("/usr/bin/tpm2"),
    "update_grub": Path("/usr/sbin/update-grub"),
}


class HelperError(Exception):
    pass


class CommandError(HelperError):
    def __init__(self, command: Sequence[str], returncode: int, stderr: str):
        self.command = list(command)
        self.returncode = returncode
        self.stderr = stderr
        super().__init__(stderr or f"Command failed with status {returncode}: {command[0]}")


def require_root() -> None:
    if os.geteuid() != 0:
        raise HelperError("This helper must run as root")


def require_trusted_file(path: Path, executable: bool = False) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise HelperError(f"Required trusted file is missing: {path}") from error
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise HelperError(f"Trusted path is not a regular file: {path}")
    if metadata.st_uid != 0 or metadata.st_gid != 0 or metadata.st_mode & 0o022:
        raise HelperError(f"Trusted file has unsafe ownership or permissions: {path}")
    if executable and not metadata.st_mode & stat.S_IXUSR:
        raise HelperError(f"Trusted helper is not executable: {path}")


def require_trusted_directory(path: Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise HelperError(f"Required trusted directory is missing: {path}") from error
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise HelperError(f"Trusted path is not a directory: {path}")
    if metadata.st_uid != 0 or metadata.st_gid != 0 or metadata.st_mode & 0o022:
        raise HelperError(f"Trusted directory has unsafe ownership or permissions: {path}")


@contextmanager
def helper_lock() -> Any:
    HELPER_LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(
        HELPER_LOCK_PATH,
        os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0:
            raise HelperError(f"Manager lock has unsafe ownership or type: {HELPER_LOCK_PATH}")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise HelperError("Another privileged Manager operation is active") from error
        yield
    finally:
        os.close(descriptor)


def run(
    command: Sequence[str | Path],
    *,
    input_bytes: bytes | None = None,
    timeout: int = 600,
    check: bool = True,
    pass_fds: Sequence[int] = (),
) -> subprocess.CompletedProcess[bytes]:
    arguments = [str(value) for value in command]
    try:
        result = subprocess.run(
            arguments,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
            pass_fds=tuple(pass_fds),
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as error:
        raise HelperError(f"Could not execute {arguments[0]}: {error}") from error
    if check and result.returncode != 0:
        raise CommandError(arguments, result.returncode, result.stderr.decode("utf-8", "replace").strip())
    return result


def read_json(path: Path) -> dict[str, Any]:
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise HelperError(f"JSON state is not a regular file: {path}")
        parsed: Any = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise HelperError(f"Invalid JSON state at {path}: {error}") from error
    if not isinstance(parsed, dict):
        raise HelperError(f"JSON state is not an object: {path}")
    return parsed


def write_atomic(path: Path, content: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def write_json(path: Path, document: dict[str, Any], mode: int = 0o600) -> None:
    write_atomic(path, (json.dumps(document, indent=2, sort_keys=True) + "\n").encode(), mode)


def record_install_progress(phase: str, progress: int) -> None:
    if phase not in {
        "preparing",
        "indexing-release",
        "downloading-release",
        "verifying-manifest",
        "verifying-download-packages",
        "authorizing-version",
        "configuring-system",
        "complete",
        "failed",
    }:
        raise HelperError(f"Unsupported Manager installation phase: {phase}")
    if not isinstance(progress, int) or not 0 <= progress <= 100:
        raise HelperError("Manager installation progress must be an integer from 0 to 100")
    state = read_json(ROOT_STATE_PATH)
    state.update({
        "schema_version": 1,
        "install_phase": phase,
        "install_progress": progress,
        "install_updated_at": datetime.now(timezone.utc).isoformat(
            timespec="microseconds"
        ).replace("+00:00", "Z"),
    })
    write_json(ROOT_STATE_PATH, state, 0o644)


def state_file_identity(path: Path) -> tuple[int, int] | None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise HelperError(f"JSON state is not a regular file: {path}")
    return metadata.st_ino, metadata.st_mtime_ns


def recovery_progress(check_state: dict[str, Any]) -> tuple[str, int] | None:
    status = check_state.get("status")
    if status == "indexing":
        return "indexing-release", 8
    if status == "downloading":
        downloaded = check_state.get("downloaded_bytes")
        total = check_state.get("total_bytes")
        if (
            isinstance(downloaded, int)
            and isinstance(total, int)
            and 0 <= downloaded <= total
            and total > 0
        ):
            return "downloading-release", 8 + round(downloaded * 47 / total)
        return "downloading-release", 8
    if status == "verifying-manifest":
        return "verifying-manifest", 58
    if status == "verifying-packages":
        return "verifying-download-packages", 62
    if status == "authorizing-version":
        return "authorizing-version", 64
    if status in {"verified", "already-staged"}:
        return "authorizing-version", 64
    return None


def recover_verified_release() -> None:
    baseline = state_file_identity(CHECK_STATE_PATH)
    run([EXECUTABLES["systemctl"], "reset-failed", CHECK_UNIT], check=False)
    run([EXECUTABLES["systemctl"], "start", "--no-block", CHECK_UNIT])
    deadline = time.monotonic() + 2 * 60 * 60
    last_progress: tuple[str, int] | None = None
    observed_new_state = False
    inactive_polls = 0

    while time.monotonic() < deadline:
        identity = state_file_identity(CHECK_STATE_PATH)
        if identity is not None and identity != baseline:
            observed_new_state = True
            check_state = read_json(CHECK_STATE_PATH)
            progress = recovery_progress(check_state)
            if progress is not None and progress != last_progress:
                record_install_progress(*progress)
                last_progress = progress

            status = check_state.get("status")
            if status in {"verified", "already-staged"}:
                if not STAGED_RELEASE_PATH.is_dir():
                    raise HelperError(
                        "Updater reported a verified Release but did not retain its staged files"
                    )
                return
            if status in {
                "check-failed",
                "release-unavailable",
                "downgrade-refused",
                "current",
                "paused",
            }:
                detail = check_state.get("error")
                if not isinstance(detail, str) or not detail:
                    detail = f"Updater check ended with status: {status}"
                raise HelperError(detail[:4096])

        active = run(
            [EXECUTABLES["systemctl"], "is-active", "--quiet", CHECK_UNIT],
            check=False,
        )
        if active.returncode not in {0, 3}:
            raise HelperError("Could not inspect the updater download service")
        if active.returncode == 3:
            inactive_polls += 1
            if inactive_polls >= 20:
                raise HelperError(
                    "Updater download service stopped without a verified Release"
                )
        else:
            inactive_polls = 0
        time.sleep(0.5)

    run([EXECUTABLES["systemctl"], "stop", CHECK_UNIT], check=False)
    raise HelperError("Timed out while recovering the verified Release")


def command_output(result: subprocess.CompletedProcess[bytes], limit: int = 16_384) -> dict[str, str]:
    return {
        "stdout": result.stdout.decode("utf-8", "replace")[-limit:],
        "stderr": result.stderr.decode("utf-8", "replace")[-limit:],
    }


def certificate_fingerprint(algorithm: str) -> str:
    require_trusted_file(CERTIFICATE_DER)
    result = run([
        EXECUTABLES["openssl"], "x509", "-inform", "DER", "-in", CERTIFICATE_DER,
        "-noout", "-fingerprint", f"-{algorithm}",
    ])
    fingerprint = result.stdout.decode("ascii", "strict").strip().split("=", 1)[-1].upper()
    expected_length = 32 if algorithm == "sha256" else 20
    if not re.fullmatch(rf"(?:[0-9A-F]{{2}}:){{{expected_length - 1}}}[0-9A-F]{{2}}", fingerprint):
        raise HelperError(f"OpenSSL returned an invalid {algorithm.upper()} fingerprint")
    return fingerprint


def project_mok_enrolled() -> bool:
    if certificate_fingerprint("sha256") != PROJECT_FINGERPRINT:
        raise HelperError("Installed project certificate fingerprint does not match the pinned value")
    return project_mok_sha1() in enrolled_mok_fingerprints()


def generate_mok_password() -> str:
    letters = "".join(secrets.choice(MOK_PASSWORD_LETTERS) for _ in range(3))
    digits = "".join(secrets.choice(MOK_PASSWORD_DIGITS) for _ in range(5))
    return letters + digits


def pending_mok_fingerprints() -> set[str]:
    result = run([EXECUTABLES["mokutil"], "--list-new"])
    output = result.stdout.decode("utf-8", "replace")
    return {match.replace(":", "").upper() for match in re.findall(
        r"SHA1 Fingerprint:\s*([0-9A-Fa-f:]+)", output
    )}


def enrolled_mok_fingerprints() -> set[str]:
    result = run([EXECUTABLES["mokutil"], "--list-enrolled"])
    output = result.stdout.decode("utf-8", "replace")
    return {match.replace(":", "").upper() for match in re.findall(
        r"SHA1 Fingerprint:\s*([0-9A-Fa-f:]+)", output
    )}


def project_mok_sha1() -> str:
    return certificate_fingerprint("sha1").replace(":", "")


def pending_project_mok() -> bool:
    return project_mok_sha1() in pending_mok_fingerprints()


def require_only_project_mok_pending() -> bool:
    fingerprints = pending_mok_fingerprints()
    if not fingerprints:
        return False
    if fingerprints != {project_mok_sha1()}:
        raise HelperError("Unrelated MOK enrollment requests are pending; refusing to modify them")
    return True


def action_start_check() -> dict[str, Any]:
    require_trusted_file(UPDATE_TOOL, executable=True)
    run([EXECUTABLES["systemctl"], "reset-failed", CHECK_UNIT], check=False)
    result = run([EXECUTABLES["systemctl"], "start", "--no-block", CHECK_UNIT])
    return {"unit": CHECK_UNIT, **command_output(result)}


def mark_check_paused() -> None:
    current = read_json(CHECK_STATE_PATH)
    current.update({"schema_version": 1, "status": "paused"})
    write_json(CHECK_STATE_PATH, current, 0o644)
    try:
        import pwd

        account = pwd.getpwnam("s4lockdown-update")
        os.chown(CHECK_STATE_PATH, account.pw_uid, account.pw_gid)
    except (KeyError, OSError) as error:
        raise HelperError(f"Could not preserve updater state ownership: {error}") from error


def action_pause_check() -> dict[str, Any]:
    result = run([EXECUTABLES["systemctl"], "stop", CHECK_UNIT])
    mark_check_paused()
    return {"unit": CHECK_UNIT, **command_output(result)}


def action_install_update() -> dict[str, Any]:
    require_trusted_file(UPDATE_TOOL, executable=True)
    require_trusted_file(SYSTEM_CONFIG_TOOL, executable=True)
    if not project_mok_enrolled():
        raise HelperError("The project MOK certificate is not enrolled")
    record_install_progress("preparing", 5)
    try:
        if not STAGED_RELEASE_PATH.is_dir() and not AVAILABLE_RELEASE_PATH.is_dir():
            recover_verified_release()
        run([UPDATE_TOOL, "install", "--force"], timeout=2 * 60 * 60)
        state = read_json(ROOT_STATE_PATH)
        if state.get("last_check_status") == "package-manager-busy":
            raise HelperError("Package installation is deferred because dpkg or APT is active")
        installed_source = state.get("installed_source_version")
        installed_release = state.get("installed_kernel_release")
        if not isinstance(installed_source, str) or not installed_source:
            raise HelperError("Updater did not record the installed Ubuntu source version")
        if not isinstance(installed_release, str) or not PROJECT_RELEASE.fullmatch(installed_release):
            raise HelperError("Updater did not record a valid installed project-kernel release")
        packages = installed_kernel_packages()
        target_packages = packages.get(installed_release, [])
        for required_package in (
            f"linux-image-{installed_release}",
            f"linux-headers-{installed_release}",
        ):
            if required_package not in target_packages:
                raise HelperError(
                    f"Expected package is not installed after processing the update: {required_package}"
                )
        record_install_progress("configuring-system", 90)
        run([SYSTEM_CONFIG_TOOL], timeout=30 * 60)
        record_install_progress("complete", 100)
        return {
            "installedSourceVersion": installed_source,
            "installedKernelRelease": installed_release,
        }
    except (HelperError, OSError):
        state = read_json(ROOT_STATE_PATH)
        progress = state.get("install_progress", 0)
        record_install_progress(
            "failed",
            progress if isinstance(progress, int) and 0 <= progress <= 100 else 0,
        )
        raise


def read_update_configuration() -> tuple[str, int]:
    if not CONFIG_PATH.exists():
        return "check-and-notify", 2
    require_trusted_file(CONFIG_PATH)
    policy: str | None = None
    history: int | None = None
    try:
        lines = CONFIG_PATH.read_text(encoding="ascii").splitlines()
    except UnicodeDecodeError as error:
        raise HelperError(
            f"Updater configuration must contain ASCII text: {CONFIG_PATH}"
        ) from error
    for line_number, raw_line in enumerate(lines, 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("POLICY=") and policy is None:
            policy = line.removeprefix("POLICY=")
        elif line.startswith("PROJECT_KERNEL_HISTORY=") and history is None:
            value = line.removeprefix("PROJECT_KERNEL_HISTORY=")
            if value not in {"1", "2", "3"}:
                raise HelperError(
                    f"Unsupported project kernel history at {CONFIG_PATH}:{line_number}"
                )
            history = int(value)
        else:
            raise HelperError(f"Unsupported updater configuration at {CONFIG_PATH}:{line_number}")
    if policy is None:
        policy = "check-and-notify"
    if policy not in POLICIES:
        raise HelperError(f"Unsupported update policy: {policy}")
    return policy, history if history is not None else 2


def write_update_configuration(policy: str, history: int) -> None:
    write_atomic(
        CONFIG_PATH,
        f"POLICY={policy}\nPROJECT_KERNEL_HISTORY={history}\n".encode("ascii"),
        0o644,
    )


def action_set_policy(policy: str) -> dict[str, Any]:
    if policy not in POLICIES:
        raise HelperError(f"Unsupported update policy: {policy}")
    previous = CONFIG_PATH.read_bytes() if CONFIG_PATH.exists() else None
    _, history = read_update_configuration()
    write_update_configuration(policy, history)
    command = "disable" if policy == "manual" else "enable"
    arguments: list[str | Path] = [EXECUTABLES["systemctl"], command, "--now", "s4lockdown-update.timer"]
    try:
        result = run(arguments)
    except HelperError:
        if previous is None:
            CONFIG_PATH.unlink(missing_ok=True)
        else:
            write_atomic(CONFIG_PATH, previous, 0o644)
        raise
    return {"policy": policy, **command_output(result)}


def action_set_kernel_retention(history: int) -> dict[str, Any]:
    if history not in PROJECT_KERNEL_HISTORY_VALUES:
        raise HelperError("Project kernel history must be 1, 2, or 3")
    previous = CONFIG_PATH.read_bytes() if CONFIG_PATH.exists() else None
    policy, _ = read_update_configuration()
    try:
        write_update_configuration(policy, history)
    except Exception:
        if previous is None:
            CONFIG_PATH.unlink(missing_ok=True)
        else:
            write_atomic(CONFIG_PATH, previous, 0o644)
        raise
    return {"projectKernelHistory": history}


def action_prepare_mok() -> dict[str, Any]:
    fingerprint = certificate_fingerprint("sha256")
    if fingerprint != PROJECT_FINGERPRINT:
        raise HelperError("Installed project certificate fingerprint does not match the pinned value")
    if project_mok_enrolled():
        MOK_STATE_PATH.unlink(missing_ok=True)
        return {"mokStatus": "enrolled", "fingerprintSha256": fingerprint}
    if require_only_project_mok_pending():
        state = read_json(MOK_STATE_PATH)
        password = state.get("one_time_password")
        state_is_valid = (
            state.get("fingerprint_sha256") == fingerprint
            and isinstance(password, str)
            and STORED_MOK_PASSWORD_PATTERN.fullmatch(password) is not None
        )
        if state_is_valid and MOK_PASSWORD_PATTERN.fullmatch(password) is not None:
            return {
                "mokStatus": "pending",
                "fingerprintSha256": fingerprint,
                "oneTimePassword": password,
            }
        run([EXECUTABLES["mokutil"], "--revoke-import"])
        MOK_STATE_PATH.unlink(missing_ok=True)
        if pending_mok_fingerprints():
            raise HelperError("Could not replace the incomplete or legacy project MOK request")

    password = generate_mok_password()
    password_hash = run(
        [EXECUTABLES["openssl"], "passwd", "-6", "-stdin"],
        input_bytes=password.encode("ascii"),
    ).stdout.strip()
    if not password_hash.startswith(b"$6$"):
        raise HelperError("OpenSSL did not produce a SHA-512 password hash")
    with tempfile.NamedTemporaryFile(prefix="s4lockdown-mok-hash.", delete=True) as hash_file:
        os.fchmod(hash_file.fileno(), 0o600)
        hash_file.write(password_hash + b"\n")
        hash_file.flush()
        os.fsync(hash_file.fileno())
        run([
            EXECUTABLES["mokutil"], "--import", CERTIFICATE_DER,
            "--hash-file", hash_file.name,
        ])
    if pending_mok_fingerprints() != {project_mok_sha1()}:
        raise HelperError("mokutil did not create the expected pending project MOK request")
    write_json(MOK_STATE_PATH, {
        "schema_version": 1,
        "fingerprint_sha256": fingerprint,
        "one_time_password": password,
    })
    return {
        "mokStatus": "pending",
        "fingerprintSha256": fingerprint,
        "oneTimePassword": password,
    }


def action_inspect_mok() -> dict[str, Any]:
    fingerprint = certificate_fingerprint("sha256")
    if fingerprint != PROJECT_FINGERPRINT:
        raise HelperError("Installed project certificate fingerprint does not match the pinned value")
    if project_mok_enrolled():
        MOK_STATE_PATH.unlink(missing_ok=True)
        return {"mokStatus": "enrolled", "fingerprintSha256": fingerprint}
    if not require_only_project_mok_pending():
        MOK_STATE_PATH.unlink(missing_ok=True)
        return {"mokStatus": "not-pending", "fingerprintSha256": fingerprint}
    state = read_json(MOK_STATE_PATH)
    password = state.get("one_time_password")
    if (
        state.get("fingerprint_sha256") != fingerprint
        or not isinstance(password, str)
        or STORED_MOK_PASSWORD_PATTERN.fullmatch(password) is None
    ):
        raise HelperError("The project MOK request is pending but its one-time password is unavailable")
    return {
        "mokStatus": "pending",
        "fingerprintSha256": fingerprint,
        "oneTimePassword": password,
    }


def action_startup_refresh() -> dict[str, Any]:
    inspection = action_inspect_mok()
    check = action_start_check()
    return {**inspection, **check}


def action_cancel_mok() -> dict[str, Any]:
    if not require_only_project_mok_pending():
        raise HelperError("No project MOK enrollment request is pending")
    run([EXECUTABLES["mokutil"], "--revoke-import"])
    if pending_mok_fingerprints():
        raise HelperError("mokutil did not remove the pending project MOK request")
    MOK_STATE_PATH.unlink(missing_ok=True)
    return {"mokStatus": "not-pending"}


def flatten_block_names(devices: list[Any]) -> set[str]:
    names: set[str] = set()
    for value in devices:
        if not isinstance(value, dict):
            continue
        name = value.get("name")
        if isinstance(name, str):
            names.add(name)
        children = value.get("children")
        if isinstance(children, list):
            names.update(flatten_block_names(children))
    return names


def parse_crypttab() -> list[tuple[str, str, str, str]]:
    try:
        require_trusted_file(CRYPTTAB_PATH)
        lines = CRYPTTAB_PATH.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as error:
        raise HelperError(f"Could not read {CRYPTTAB_PATH}: {error}") from error
    entries: list[tuple[str, str, str, str]] = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) < 2:
            raise HelperError(f"Malformed crypttab entry: {line}")
        entries.append((
            fields[0], fields[1], fields[2] if len(fields) > 2 else "none",
            fields[3] if len(fields) > 3 else "luks",
        ))
    return entries


def root_luks_entry() -> tuple[str, Path]:
    root_source = run([EXECUTABLES["findmnt"], "--noheadings", "--output", "SOURCE", "/"])
    source = root_source.stdout.decode("utf-8", "replace").strip()
    if not source.startswith("/dev/"):
        raise HelperError(f"Root filesystem source is not a block device: {source}")
    tree = run([
        EXECUTABLES["lsblk"], "--json", "--inverse", "--output", "NAME", source,
    ])
    try:
        parsed = json.loads(tree.stdout)
    except json.JSONDecodeError as error:
        raise HelperError(f"lsblk returned invalid JSON: {error}") from error
    names = flatten_block_names(parsed.get("blockdevices", [])) if isinstance(parsed, dict) else set()
    matching = [entry for entry in parse_crypttab() if entry[0] in names]
    if len(matching) != 1:
        raise HelperError("Could not identify exactly one crypttab entry backing the root filesystem")
    mapper, source_spec, _key, _options = matching[0]
    if source_spec.startswith("UUID="):
        device = Path("/dev/disk/by-uuid") / source_spec.removeprefix("UUID=")
    elif source_spec.startswith("/dev/"):
        device = Path(source_spec)
    else:
        raise HelperError(f"Unsupported root crypttab source: {source_spec}")
    try:
        resolved = device.resolve(strict=True)
        metadata = resolved.stat()
    except OSError as error:
        raise HelperError(f"Could not resolve root LUKS device: {error}") from error
    if not str(resolved).startswith("/dev/") or not stat.S_ISBLK(metadata.st_mode):
        raise HelperError(f"Resolved root LUKS target is not a block device: {resolved}")
    result = run([EXECUTABLES["cryptsetup"], "isLuks", resolved], check=False)
    if result.returncode != 0:
        raise HelperError(f"Root crypttab source is not a LUKS device: {resolved}")
    return mapper, resolved


def luks_metadata(device: Path) -> dict[str, Any]:
    result = run([
        EXECUTABLES["cryptsetup"], "luksDump", "--dump-json-metadata", device,
    ])
    try:
        parsed: Any = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise HelperError(f"cryptsetup returned invalid LUKS metadata: {error}") from error
    if not isinstance(parsed, dict):
        raise HelperError("LUKS metadata is not an object")
    return parsed


def tpm_token_ids(metadata: dict[str, Any]) -> list[str]:
    tokens = metadata.get("tokens")
    if not isinstance(tokens, dict):
        return []
    return sorted(
        token_id for token_id, value in tokens.items()
        if isinstance(token_id, str) and isinstance(value, dict)
        and value.get("type") == "systemd-tpm2"
    )


def inspect_tpm_tokens(device: Path, token_ids: Sequence[str] | None = None) -> list[dict[str, Any]]:
    ids = list(token_ids) if token_ids is not None else tpm_token_ids(luks_metadata(device))
    results: list[dict[str, Any]] = []
    for token_id in ids:
        result = run([
            EXECUTABLES["cryptsetup"], "open", "--test-passphrase", "--token-only",
            "--token-id", token_id, device,
        ], timeout=120, check=False)
        results.append({"tokenId": token_id, "passed": result.returncode == 0})
    return results


def verify_tpm_tokens(device: Path, token_ids: Sequence[str] | None = None) -> dict[str, Any]:
    results = inspect_tpm_tokens(device, token_ids)
    if not results:
        raise HelperError("No systemd TPM2 token is enrolled on the root LUKS device")
    if not any(result["passed"] for result in results):
        raise HelperError("No enrolled TPM2 token can unlock the root LUKS device")
    return {"tokens": results}


def luks_uuid(device: Path, header: Path | None = None) -> str:
    command: list[str | Path] = [EXECUTABLES["cryptsetup"], "luksUUID"]
    if header is not None:
        command.extend(["--header", header])
    command.append(device)
    value = run(command).stdout.decode("ascii", "strict").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value):
        raise HelperError("cryptsetup returned an invalid LUKS UUID")
    return value


def backup_luks_header(device: Path) -> Path:
    uuid = luks_uuid(device)
    try:
        directory_metadata = TPM_BACKUP_DIRECTORY.lstat()
        if not stat.S_ISDIR(directory_metadata.st_mode) or stat.S_ISLNK(directory_metadata.st_mode):
            raise HelperError(f"TPM backup path is not a directory: {TPM_BACKUP_DIRECTORY}")
        if directory_metadata.st_uid != 0 or directory_metadata.st_gid != 0:
            raise HelperError(f"TPM backup directory has unsafe ownership: {TPM_BACKUP_DIRECTORY}")
    except FileNotFoundError:
        TPM_BACKUP_DIRECTORY.mkdir(parents=False, mode=0o700)
    os.chmod(TPM_BACKUP_DIRECTORY, 0o700)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    descriptor, name = tempfile.mkstemp(
        prefix=f"luks-{uuid}-before-tpm-{timestamp}.",
        suffix=".img",
        dir=TPM_BACKUP_DIRECTORY,
    )
    os.close(descriptor)
    backup = Path(name)
    backup.unlink()
    try:
        run([
            EXECUTABLES["cryptsetup"], "luksHeaderBackup", device,
            "--header-backup-file", backup,
        ], timeout=300)
        os.chmod(backup, 0o600)
        require_trusted_file(backup)
        if luks_uuid(device, backup) != uuid:
            raise HelperError("LUKS header backup UUID does not match the root volume")
        return backup
    except Exception:
        backup.unlink(missing_ok=True)
        raise


def read_password_stdin() -> bytearray:
    password = bytearray(sys.stdin.buffer.read(MAX_PASSWORD_BYTES + 1))
    if len(password) > MAX_PASSWORD_BYTES:
        password[:] = b"\0" * len(password)
        raise HelperError("The LUKS recovery password exceeds 4096 bytes")
    if not password:
        raise HelperError("No LUKS recovery password was provided")
    return password


def password_memfd(prompt: str, password: bytes | bytearray | None = None) -> int:
    if password is None:
        try:
            password = run([
                EXECUTABLES["systemd_ask_password"], "--no-tty", "--timeout=60", "-n",
                "--id=s4lockdown-manager:luks-root", prompt,
            ], timeout=90).stdout
        except CommandError as error:
            raise HelperError(
                "No LUKS recovery password was received; the prompt timed out "
                "or no desktop ask-password agent was available"
            ) from error
    if not password:
        raise HelperError("No LUKS recovery password was provided")
    descriptor = os.memfd_create("s4lockdown-luks-password", os.MFD_CLOEXEC)
    os.write(descriptor, password)
    os.lseek(descriptor, 0, os.SEEK_SET)
    return descriptor


def test_password(device: Path, descriptor: int) -> None:
    os.lseek(descriptor, 0, os.SEEK_SET)
    try:
        run([
            EXECUTABLES["cryptsetup"], "open", "--test-passphrase",
            "--disable-external-tokens", "--key-file",
            f"/proc/self/fd/{descriptor}", device,
        ], pass_fds=[descriptor], timeout=120)
    except CommandError as error:
        if error.returncode == 2:
            raise HelperError("The LUKS recovery password is incorrect") from error
        raise


def ensure_tpm_crypttab(mapper: str) -> bool:
    require_trusted_file(CRYPTTAB_PATH)
    source = CRYPTTAB_PATH.read_text(encoding="utf-8")
    lines = source.splitlines(keepends=True)
    changed = False
    found = False
    output: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.split()[0] != mapper:
            output.append(line)
            continue
        found = True
        newline = "\n" if line.endswith("\n") else ""
        fields = stripped.split()
        while len(fields) < 4:
            fields.append("none" if len(fields) == 2 else "luks")
        options = fields[3].split(",")
        if not any(option.startswith("tpm2-device=") for option in options):
            options.append("tpm2-device=auto")
            fields[3] = ",".join(options)
            changed = True
        output.append(" ".join(fields) + newline)
    if not found:
        raise HelperError("Root crypttab entry disappeared during TPM enrollment")
    if changed:
        write_atomic(CRYPTTAB_PATH, "".join(output).encode("utf-8"), 0o644)
    return changed


def root_filesystem_uuid() -> str:
    result = run([
        EXECUTABLES["findmnt"], "--noheadings", "--output", "UUID", "--target", "/",
    ])
    value = result.stdout.decode("ascii", "strict").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value):
        raise HelperError("findmnt returned an invalid root filesystem UUID")
    return value


def verify_encrypted_root_initramfs(
    image: Path,
    mapper: str,
    root_uuid: str,
    device_uuid: str,
) -> None:
    listing = run([EXECUTABLES["lsinitrd"], image]).stdout.decode("utf-8", "replace")
    if "etc/crypttab" not in listing:
        raise HelperError("Generated initramfs does not contain /etc/crypttab")
    if not any(path in listing for path in (
        "usr/sbin/cryptsetup",
        "sbin/cryptsetup",
        "usr/bin/cryptsetup",
        "usr/lib/systemd/systemd-cryptsetup",
    )):
        raise HelperError("Generated initramfs does not contain a LUKS unlock executable")
    required_tpm_paths = {
        "usr/bin/tpm2": "TPM utility",
        "cryptsetup/libcryptsetup-token-systemd-tpm2.so": "TPM token plugin",
        "libtss2-tcti-device.so.": "TPM device TCTI library",
        "60-tpm-udev.rules": "TPM udev rules",
    }
    for path, description in required_tpm_paths.items():
        if path not in listing:
            raise HelperError(
                f"Generated initramfs does not contain the required {description}: {path}"
            )
    if f"root=UUID={root_uuid}" not in listing:
        raise HelperError("Generated initramfs does not contain the expected root UUID")
    if f"rd.luks.uuid=luks-{device_uuid}" not in listing:
        raise HelperError("Generated initramfs does not contain the expected LUKS UUID")

    embedded = run([
        EXECUTABLES["lsinitrd"], "--file", "/etc/crypttab", image,
    ]).stdout.decode("utf-8", "replace")
    expected_entries = [entry for entry in parse_crypttab() if entry[0] == mapper]
    if len(expected_entries) != 1:
        raise HelperError("Could not identify the expected root crypttab entry")
    expected_mapper, expected_source, expected_key, expected_options = expected_entries[0]
    matching_entry = False
    for line in embedded.splitlines():
        fields = line.strip().split()
        if len(fields) < 4 or fields[0] != mapper:
            continue
        matching_entry = (
            fields[:3] == [expected_mapper, expected_source, expected_key]
            and set(fields[3].split(",")) == set(expected_options.split(","))
            and "tpm2-device=auto" in fields[3].split(",")
        )
        break
    if not matching_entry:
        raise HelperError("Generated initramfs contains an unexpected root crypttab entry")


def rebuild_encrypted_root_initramfs(release: str, mapper: str, device: Path) -> None:
    if not PROJECT_RELEASE.fullmatch(release):
        raise HelperError(f"Refusing to rebuild an unexpected kernel release: {release}")
    for executable in ("cryptsetup", "dracut", "findmnt", "lsinitrd", "tpm2"):
        require_trusted_file(EXECUTABLES[executable], executable=True)
    require_trusted_directory(BOOT_DIRECTORY)

    target = BOOT_DIRECTORY / f"initrd.img-{release}"
    require_trusted_file(target)
    root_uuid = root_filesystem_uuid()
    device_uuid = luks_uuid(device)
    descriptor, name = tempfile.mkstemp(
        prefix=f".initrd.img-{release}.", suffix=".candidate", dir=BOOT_DIRECTORY,
    )
    os.close(descriptor)
    candidate = Path(name)
    candidate.unlink()
    backup: Path | None = None
    replaced = False
    keep_backup = False
    try:
        run([
            EXECUTABLES["dracut"], "--force", "--no-hostonly",
            "--add", "crypt dm rootfs-block systemd-cryptsetup tpm2-tss",
            "--include", CRYPTTAB_PATH, "/etc/crypttab",
            "--kernel-cmdline",
            f"root=UUID={root_uuid} rd.luks.uuid=luks-{device_uuid} rw",
            candidate, release,
        ], timeout=20 * 60)
        require_trusted_file(candidate)
        verify_encrypted_root_initramfs(
            candidate, mapper, root_uuid, device_uuid,
        )

        backup_descriptor, backup_name = tempfile.mkstemp(
            prefix=f".initrd.img-{release}.", suffix=".previous", dir=BOOT_DIRECTORY,
        )
        os.close(backup_descriptor)
        backup = Path(backup_name)
        backup.unlink()
        os.link(target, backup, follow_symlinks=False)
        os.replace(candidate, target)
        replaced = True
        directory = os.open(BOOT_DIRECTORY, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except Exception as error:
        if replaced and backup is not None and backup.exists():
            try:
                os.replace(backup, target)
                backup = None
                directory = os.open(BOOT_DIRECTORY, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            except Exception as restore_error:
                keep_backup = True
                raise HelperError(
                    "Could not restore the previous initramfs after replacement failed; "
                    f"the previous image remains at {backup}: {restore_error}"
                ) from error
        raise
    finally:
        candidate.unlink(missing_ok=True)
        if backup is not None and not keep_backup:
            try:
                backup.unlink()
            except OSError as error:
                print(f"Warning: could not remove initramfs backup {backup}: {error}", file=sys.stderr)


def configure_tpm_boot(release: str, mapper: str, device: Path) -> bool:
    original_crypttab = CRYPTTAB_PATH.read_bytes()
    crypttab_changed = False
    try:
        crypttab_changed = ensure_tpm_crypttab(mapper)
        rebuild_encrypted_root_initramfs(release, mapper, device)
        return crypttab_changed
    except Exception as error:
        if crypttab_changed:
            try:
                write_atomic(CRYPTTAB_PATH, original_crypttab, 0o644)
            except Exception as restore_error:
                raise HelperError(
                    "Initramfs replacement failed and crypttab could not be restored: "
                    f"{restore_error}"
                ) from error
        raise


def require_project_boot() -> str:
    release = os.uname().release
    if not PROJECT_RELEASE.fullmatch(release):
        raise HelperError("TPM enrollment requires the running project kernel")
    secure_boot = run([EXECUTABLES["mokutil"], "--sb-state"])
    if "SecureBoot enabled" not in secure_boot.stdout.decode("utf-8", "replace"):
        raise HelperError("Secure Boot is not enabled")
    lockdown = Path("/sys/kernel/security/lockdown").read_text(encoding="ascii")
    if "[integrity]" not in lockdown and "[confidentiality]" not in lockdown:
        raise HelperError("Kernel Lockdown is not active")
    packages = installed_kernel_packages()
    if not any(
        not release_name.endswith(("-s4lockdown", "-hibernate"))
        and f"linux-image-{release_name}" in names
        for release_name, names in packages.items()
    ):
        raise HelperError("No official Ubuntu fallback kernel is installed")
    return release


def action_verify_tpm() -> dict[str, Any]:
    _mapper, device = root_luks_entry()
    results = inspect_tpm_tokens(device)
    return {
        "deviceUuid": luks_uuid(device),
        "alreadyConfigured": any(result["passed"] for result in results),
        "tokens": results,
    }


def action_verify_recovery(password: bytes | bytearray | None = None) -> dict[str, Any]:
    _mapper, device = root_luks_entry()
    descriptor = password_memfd(
        "Enter the LUKS recovery password to verify it", password,
    )
    try:
        test_password(device, descriptor)
    finally:
        os.close(descriptor)
    return {"passwordRecovery": "verified"}


def action_enroll_tpm(password: bytes | bytearray | None = None) -> dict[str, Any]:
    release = require_project_boot()
    mapper, device = root_luks_entry()
    before = set(tpm_token_ids(luks_metadata(device)))
    existing_results = inspect_tpm_tokens(device, sorted(before))
    if any(result["passed"] for result in existing_results):
        descriptor = password_memfd(
            "Enter the LUKS recovery password to verify recovery access", password,
        )
        try:
            test_password(device, descriptor)
        finally:
            os.close(descriptor)
        try:
            crypttab_changed = configure_tpm_boot(release, mapper, device)
        except Exception as error:
            raise HelperError(
                "The TPM token is valid, but boot configuration failed; the previous "
                f"crypttab and initramfs were preserved. Error: {error}"
            ) from error
        return {
            "alreadyConfigured": True,
            "addedTokenIds": [],
            "headerBackup": None,
            "crypttabChanged": crypttab_changed,
            "tokens": existing_results,
            "passwordRecovery": "verified",
        }
    descriptor = password_memfd(
        "Enter the LUKS recovery password to enroll TPM automatic unlock", password,
    )
    backup: Path | None = None
    try:
        test_password(device, descriptor)
        backup = backup_luks_header(device)
        os.lseek(descriptor, 0, os.SEEK_SET)
        enrollment = run([
            EXECUTABLES["systemd_cryptenroll"],
            f"--unlock-key-file=/proc/self/fd/{descriptor}",
            "--tpm2-device=auto", "--tpm2-pcrs=7:sha256", device,
        ], pass_fds=[descriptor], timeout=300)
        test_password(device, descriptor)
    finally:
        os.close(descriptor)
    after = set(tpm_token_ids(luks_metadata(device)))
    added = sorted(after - before)
    if not added:
        raise HelperError("TPM enrollment did not add a new token")
    verification = verify_tpm_tokens(device, added)
    try:
        crypttab_changed = configure_tpm_boot(release, mapper, device)
    except Exception as error:
        raise HelperError(
            "TPM token was enrolled, but boot configuration failed; the previous "
            "crypttab and initramfs were preserved. "
            f"Header backup: {backup}. Error: {error}"
        ) from error
    return {
        "alreadyConfigured": False,
        "addedTokenIds": added,
        "headerBackup": str(backup),
        "crypttabChanged": crypttab_changed,
        "passwordRecovery": "verified",
        **verification,
        **command_output(enrollment),
    }


def installed_kernel_packages() -> dict[str, list[str]]:
    result = run([
        EXECUTABLES["dpkg_query"], "-W", "-f=${binary:Package}\t${db:Status-Abbrev}\n",
        "linux-image-*", "linux-headers-*",
    ])
    releases: dict[str, list[str]] = {}
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        try:
            package, status_value = line.split("\t", 1)
        except ValueError:
            continue
        if status_value != "ii ":
            continue
        match = re.fullmatch(r"linux-(?:image|headers)-([0-9].*)", package)
        if match:
            releases.setdefault(match.group(1), []).append(package)
    return releases


def configured_grub_top_level_release() -> str | None:
    try:
        GRUB_PROJECT_CONFIG_PATH.lstat()
    except FileNotFoundError:
        return None
    require_trusted_file(GRUB_PROJECT_CONFIG_PATH)
    try:
        source = GRUB_PROJECT_CONFIG_PATH.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        raise HelperError(
            f"Could not read project GRUB configuration: {error}"
        ) from error
    matches = re.findall(
        r'^GRUB_TOP_LEVEL="/boot/vmlinuz-([^"\n]+)"$', source, re.MULTILINE
    )
    if len(matches) != 1 or not PROJECT_RELEASE.fullmatch(matches[0]):
        raise HelperError(
            "Project GRUB configuration has an invalid top-level kernel"
        )
    return matches[0]


def action_remove_kernel(release: str) -> dict[str, Any]:
    if not PROJECT_RELEASE.fullmatch(release):
        raise HelperError("Only an exact project-kernel release may be removed")
    if release == os.uname().release:
        raise HelperError("The running kernel cannot be removed")
    if release == configured_grub_top_level_release():
        raise HelperError("The kernel selected for the next boot cannot be removed")
    releases = installed_kernel_packages()
    packages = releases.get(release, [])
    if not packages or f"linux-image-{release}" not in packages:
        raise HelperError(f"Project kernel is not installed: {release}")
    project_releases = [
        value for value, names in releases.items()
        if value.endswith(("-s4lockdown", "-hibernate"))
        and f"linux-image-{value}" in names
    ]
    official_releases = [
        value for value, names in releases.items()
        if not value.endswith(("-s4lockdown", "-hibernate"))
        and f"linux-image-{value}" in names
    ]
    if len(project_releases) < 2:
        raise HelperError("At least one other project kernel must remain installed")
    if not official_releases:
        raise HelperError("No official Ubuntu fallback kernel is installed")
    result = run([EXECUTABLES["dpkg"], "--remove", *sorted(packages)], timeout=30 * 60)
    run([EXECUTABLES["update_grub"]], timeout=10 * 60)
    remaining = installed_kernel_packages()
    if release in remaining:
        raise HelperError(f"Kernel packages remain installed after removal: {release}")
    if not any(
        not value.endswith(("-s4lockdown", "-hibernate"))
        for value in remaining
    ):
        raise HelperError("Official Ubuntu fallback disappeared after kernel removal")
    return {"removedRelease": release, "removedPackages": sorted(packages), **command_output(result)}


def required_swap_bytes() -> int:
    try:
        source = MEMINFO_PATH.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        raise HelperError(f"Could not read physical memory size: {error}") from error
    match = re.search(r"^MemTotal:\s+(\d+)\s+kB$", source, re.MULTILINE)
    if match is None:
        raise HelperError("MemTotal is missing from /proc/meminfo")
    memory_bytes = int(match.group(1)) * 1024
    return ((memory_bytes + GIB - 1) // GIB) * GIB


def active_swap_priority(path: Path) -> int | None:
    try:
        lines = SWAPS_PATH.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise HelperError(f"Could not inspect active swap: {error}") from error
    for line in lines[1:]:
        fields = line.split()
        if len(fields) >= 5 and fields[0] == str(path):
            try:
                return int(fields[4])
            except ValueError as error:
                raise HelperError(f"Invalid swap priority for {path}") from error
    return None


def normalized_fstab_swap(source: str) -> tuple[bytes, int]:
    require_trusted_file(FSTAB_PATH)
    metadata = FSTAB_PATH.stat()
    try:
        lines = FSTAB_PATH.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise HelperError(f"Could not read {FSTAB_PATH}: {error}") from error

    replacement = f"{source} none swap sw,pri=100 0 0"
    matches: list[int] = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if fields[0] != source:
            continue
        if len(fields) < 3 or fields[2] != "swap":
            raise HelperError(f"{source} has a non-swap entry in {FSTAB_PATH}")
        matches.append(index)
    if len(matches) > 1:
        raise HelperError(f"Multiple {source} entries exist in {FSTAB_PATH}")
    if matches:
        lines[matches[0]] = replacement
    else:
        if lines and lines[-1] != "":
            lines.append("")
        lines.extend(["# Managed by Secure Hibernate Manager", replacement])
    return ("\n".join(lines).rstrip("\n") + "\n").encode(), stat.S_IMODE(metadata.st_mode)


def validate_existing_managed_swap() -> None:
    try:
        metadata = MANAGED_SWAP_PATH.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise HelperError(f"Refusing to replace non-regular swap path: {MANAGED_SWAP_PATH}")
    if metadata.st_uid != 0 or metadata.st_gid != 0 or metadata.st_nlink != 1:
        raise HelperError(f"Swap file has unsafe ownership or links: {MANAGED_SWAP_PATH}")
    if metadata.st_mode & 0o077:
        raise HelperError(f"Swap file permissions are too broad: {MANAGED_SWAP_PATH}")


def action_repair_swap() -> dict[str, Any]:
    for executable in ("fallocate", "findmnt", "mkswap", "swapoff", "swapon"):
        require_trusted_file(EXECUTABLES[executable], executable=True)
    validate_existing_managed_swap()
    result = run([
        EXECUTABLES["findmnt"], "--noheadings", "--output", "FSTYPE", "--target", "/",
    ])
    filesystem = result.stdout.decode("ascii", "strict").strip()
    if filesystem not in {"ext4", "xfs"}:
        raise HelperError(
            f"Automatic swap-file repair supports ext4 and xfs roots, not {filesystem or 'unknown'}"
        )

    target_size = required_swap_bytes()
    filesystem_stats = os.statvfs("/")
    available = filesystem_stats.f_bavail * filesystem_stats.f_frsize
    if available < target_size:
        raise HelperError(
            f"Insufficient free space: need {target_size} bytes, have {available} bytes"
        )

    fstab_content, fstab_mode = normalized_fstab_swap(str(MANAGED_SWAP_PATH))
    original_fstab = FSTAB_PATH.read_bytes()
    previous_priority = active_swap_priority(MANAGED_SWAP_PATH)
    existing = MANAGED_SWAP_PATH.exists()
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".swap.img.s4lockdown-new-",
        dir=MANAGED_SWAP_PATH.parent,
    )
    temporary = Path(temporary_name)
    os.close(descriptor)
    backup = MANAGED_SWAP_PATH.parent / (
        f".swap.img.s4lockdown-old-{secrets.token_hex(8)}"
    )
    old_moved = False
    new_installed = False
    new_active = False
    try:
        os.chmod(temporary, 0o600)
        run([EXECUTABLES["fallocate"], "--length", str(target_size), temporary], timeout=600)
        run([EXECUTABLES["mkswap"], temporary], timeout=120)
        if previous_priority is not None:
            run([EXECUTABLES["swapoff"], MANAGED_SWAP_PATH], timeout=600)
        if existing:
            os.replace(MANAGED_SWAP_PATH, backup)
            old_moved = True
        os.replace(temporary, MANAGED_SWAP_PATH)
        new_installed = True
        write_atomic(FSTAB_PATH, fstab_content, fstab_mode)
        run([
            EXECUTABLES["swapon"], "--priority", "100", MANAGED_SWAP_PATH,
        ], timeout=120)
        new_active = True
        if old_moved:
            backup.unlink()
            old_moved = False
    except Exception as error:
        rollback_errors: list[str] = []
        replacement_deactivated = not new_active
        if new_active:
            try:
                run([EXECUTABLES["swapoff"], MANAGED_SWAP_PATH], timeout=600)
                replacement_deactivated = True
            except Exception as rollback_error:
                rollback_errors.append(f"could not deactivate replacement: {rollback_error}")
        if replacement_deactivated:
            try:
                write_atomic(FSTAB_PATH, original_fstab, fstab_mode)
            except Exception as rollback_error:
                rollback_errors.append(f"could not restore {FSTAB_PATH}: {rollback_error}")
            if new_installed:
                try:
                    MANAGED_SWAP_PATH.unlink(missing_ok=True)
                except OSError as rollback_error:
                    rollback_errors.append(f"could not remove replacement: {rollback_error}")
            if old_moved:
                try:
                    os.replace(backup, MANAGED_SWAP_PATH)
                except OSError as rollback_error:
                    rollback_errors.append(f"could not restore previous swap file: {rollback_error}")
            if previous_priority is not None and MANAGED_SWAP_PATH.exists():
                try:
                    run([
                        EXECUTABLES["swapon"], "--priority", str(previous_priority),
                        MANAGED_SWAP_PATH,
                    ], timeout=120)
                except Exception as rollback_error:
                    rollback_errors.append(f"could not reactivate previous swap: {rollback_error}")
        else:
            rollback_errors.append(
                f"replacement remains active at {MANAGED_SWAP_PATH}; previous file retained at {backup}"
            )
        detail = f"Swap repair failed: {error}"
        if rollback_errors:
            detail += "; rollback incomplete: " + "; ".join(rollback_errors)
        raise HelperError(detail) from error
    finally:
        temporary.unlink(missing_ok=True)

    return {
        "swapPath": str(MANAGED_SWAP_PATH),
        "swapSizeBytes": target_size,
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    for name in (
        "startup-refresh", "start-check", "pause-check", "resume-check", "install-update",
        "inspect-mok", "prepare-mok", "cancel-mok", "verify-tpm",
        "repair-swap",
    ):
        subparsers.add_parser(name)
    for name in ("enroll-tpm", "verify-recovery"):
        password_action = subparsers.add_parser(name)
        password_action.add_argument("--password-stdin", action="store_true")
    policy = subparsers.add_parser("set-policy")
    policy.add_argument("policy", choices=sorted(POLICIES))
    retention = subparsers.add_parser("set-kernel-retention")
    retention.add_argument("history", type=int, choices=sorted(PROJECT_KERNEL_HISTORY_VALUES))
    remove = subparsers.add_parser("remove-kernel")
    remove.add_argument("release")
    return parser.parse_args()


def dispatch(arguments: argparse.Namespace) -> dict[str, Any]:
    actions = {
        "startup-refresh": action_startup_refresh,
        "start-check": action_start_check,
        "pause-check": action_pause_check,
        "resume-check": action_start_check,
        "install-update": action_install_update,
        "inspect-mok": action_inspect_mok,
        "prepare-mok": action_prepare_mok,
        "cancel-mok": action_cancel_mok,
        "verify-tpm": action_verify_tpm,
        "repair-swap": action_repair_swap,
    }
    if arguments.action == "set-policy":
        return action_set_policy(arguments.policy)
    if arguments.action == "set-kernel-retention":
        return action_set_kernel_retention(arguments.history)
    if arguments.action == "remove-kernel":
        return action_remove_kernel(arguments.release)
    if arguments.action in {"enroll-tpm", "verify-recovery"}:
        password = read_password_stdin() if arguments.password_stdin else None
        try:
            action = action_enroll_tpm if arguments.action == "enroll-tpm" else action_verify_recovery
            return action(password)
        finally:
            if password is not None:
                password[:] = b"\0" * len(password)
    return actions[arguments.action]()


def main() -> int:
    arguments = parse_arguments()
    try:
        require_root()
        with helper_lock():
            data = dispatch(arguments)
        document = {
            "schemaVersion": SCHEMA_VERSION,
            "action": arguments.action,
            "status": "success",
            "error": None,
            "data": data,
        }
        print(json.dumps(document, sort_keys=True))
        return 0
    except (HelperError, OSError, UnicodeError, json.JSONDecodeError) as error:
        document = {
            "schemaVersion": SCHEMA_VERSION,
            "action": arguments.action,
            "status": "error",
            "error": str(error),
            "data": {},
        }
        print(json.dumps(document, sort_keys=True))
        return 1


if __name__ == "__main__":
    sys.exit(main())
