#!/usr/bin/env python3
"""Validate and assemble isolated Secure Hibernate Manager releases."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


PACKAGE_NAME = "secure-hibernate-manager"
ARCHITECTURE = "amd64"
TAG_PREFIX = "manager-v"
DESCRIPTOR_NAME = "manager-release.json"
CHECKSUMS_NAME = "SHA256SUMS"
SCHEMA_VERSION = 1
MAX_DESCRIPTOR_SIZE = 64 * 1024
MAX_ATTESTATION_SIZE = 16 * 1024 * 1024
VERSION_PATTERN = re.compile(
    r"[0-9]+\.[0-9]+\.[0-9]+"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
class ReleaseError(RuntimeError):
    """A release input or artifact violates the Manager release contract."""


def fail(message: str) -> None:
    raise ReleaseError(message)


def regular_file(path: Path, label: str, maximum_size: int | None = None) -> os.stat_result:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular file: {path}")
    if maximum_size is not None and metadata.st_size > maximum_size:
        fail(f"{label} exceeds the size limit: {path}")
    return metadata


def parse_version(pubspec: Path) -> str:
    regular_file(pubspec, "Flutter pubspec", MAX_DESCRIPTOR_SIZE)
    versions: list[str] = []
    for line in pubspec.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"version:[ \t]*([^#\s]+)[ \t]*", line)
        if match:
            versions.append(match.group(1))
    if len(versions) != 1:
        fail("Flutter pubspec must contain exactly one unindented version field")
    version = versions[0]
    if VERSION_PATTERN.fullmatch(version) is None:
        fail(f"Unsupported Flutter Manager version: {version}")
    return version


def expected_names(version: str) -> dict[str, str]:
    deb = f"{PACKAGE_NAME}_{version}_{ARCHITECTURE}.deb"
    return {
        "version": version,
        "release_tag": f"{TAG_PREFIX}{version}",
        "deb_name": deb,
        "bundle_name": f"manager-release-{version}.intoto.jsonl",
        "candidate_artifact": f"manager-candidate-{version}",
        "release_artifact": f"manager-release-{version}",
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_commit(commit: str) -> None:
    if COMMIT_PATTERN.fullmatch(commit) is None:
        fail(f"Invalid Git commit: {commit}")


def package_fields(path: Path) -> dict[str, str]:
    try:
        process = subprocess.run(
            ["dpkg-deb", "--field", str(path), "Package", "Version", "Architecture"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError:
        fail("dpkg-deb is required to validate the Manager package")
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or "dpkg-deb rejected the package"
        fail(detail)

    fields: dict[str, str] = {}
    for line in process.stdout.splitlines():
        key, separator, value = line.partition(":")
        if not separator or key in fields:
            fail("dpkg-deb returned malformed package metadata")
        fields[key] = value.strip()
    if set(fields) != {"Package", "Version", "Architecture"}:
        fail("Manager package metadata is incomplete")
    return fields


def validate_package(path: Path, version: str) -> tuple[os.stat_result, str]:
    names = expected_names(version)
    if path.name != names["deb_name"]:
        fail(f"Unexpected Manager package filename: {path.name}")
    metadata = regular_file(path, "Manager Debian package")
    fields = package_fields(path)
    expected = {
        "Package": PACKAGE_NAME,
        "Version": version,
        "Architecture": ARCHITECTURE,
    }
    if fields != expected:
        fail(f"Manager package metadata does not match the release: {fields}")
    return metadata, sha256_file(path)


def atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def validate_directory_shape(directory: Path, version: str, require_attestation: bool) -> None:
    names = expected_names(version)
    allowed = {names["deb_name"], DESCRIPTOR_NAME, CHECKSUMS_NAME}
    if require_attestation:
        allowed.add(names["bundle_name"])
    try:
        actual = {entry.name for entry in directory.iterdir()}
    except FileNotFoundError:
        fail(f"Manager release directory is missing: {directory}")
    if actual != allowed:
        missing = sorted(allowed - actual)
        extra = sorted(actual - allowed)
        fail(f"Manager release directory has an invalid shape; missing={missing}, extra={extra}")


def metadata_command(arguments: argparse.Namespace) -> None:
    version = parse_version(arguments.pubspec)
    names = expected_names(version)
    if arguments.event_name not in {"push", "workflow_dispatch"}:
        fail(f"Unsupported Manager release event: {arguments.event_name}")
    if (
        arguments.ref_type != "branch"
        or arguments.ref_name != arguments.default_branch
    ):
        fail("Manager publication must run from the default branch")

    for key, value in names.items():
        print(f"{key}={value}")


def decision_command(arguments: argparse.Namespace) -> None:
    version = parse_version(arguments.pubspec)
    names = expected_names(version)
    if arguments.event_name not in {"push", "workflow_dispatch"}:
        fail(f"Unsupported Manager release event: {arguments.event_name}")
    if arguments.release_exists == "false":
        print("build=true")
        return

    regular_file(
        arguments.release_assets,
        "Manager Release asset list",
        MAX_DESCRIPTOR_SIZE,
    )
    try:
        lines = arguments.release_assets.read_text(encoding="ascii").splitlines()
    except UnicodeDecodeError:
        fail("Manager Release asset list must be ASCII")
    actual = set(lines)
    if len(actual) != len(lines) or "" in actual:
        fail("Manager Release asset list is malformed")
    expected = {
        names["deb_name"],
        names["bundle_name"],
        DESCRIPTOR_NAME,
        CHECKSUMS_NAME,
    }
    if actual != expected:
        fail("Existing Manager Release is incomplete or has unexpected assets")
    if arguments.event_name == "workflow_dispatch":
        fail("Refusing to modify an existing complete Manager Release")
    print("build=false")


def prepare_command(arguments: argparse.Namespace) -> None:
    version = parse_version(arguments.pubspec)
    validate_commit(arguments.git_commit)
    names = expected_names(version)
    directory = arguments.directory
    directory.mkdir(parents=True, exist_ok=True)
    deb = directory / names["deb_name"]
    metadata, digest = validate_package(deb, version)

    existing = [directory / DESCRIPTOR_NAME, directory / CHECKSUMS_NAME]
    if any(path.exists() or path.is_symlink() for path in existing):
        fail("Refusing to replace existing Manager release metadata")
    actual = {entry.name for entry in directory.iterdir()}
    if actual != {names["deb_name"]}:
        fail(f"Unexpected files exist before Manager release assembly: {sorted(actual)}")

    document = {
        "schema_version": SCHEMA_VERSION,
        "release_kind": "secure-hibernate-manager",
        "version": version,
        "release_tag": names["release_tag"],
        "git_commit": arguments.git_commit,
        "artifact": {
            "name": names["deb_name"],
            "architecture": ARCHITECTURE,
            "size": metadata.st_size,
            "sha256": digest,
        },
    }
    encoded = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")
    atomic_write(directory / DESCRIPTOR_NAME, encoded)
    atomic_write(directory / CHECKSUMS_NAME, f"{digest}  {names['deb_name']}\n".encode())
    validate_directory_shape(directory, version, require_attestation=False)
    print(f"Prepared Manager release candidate {names['release_tag']}")


def load_descriptor(path: Path) -> dict[str, Any]:
    regular_file(path, "Manager release descriptor", MAX_DESCRIPTOR_SIZE)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"Invalid Manager release descriptor: {error}")
    if not isinstance(document, dict):
        fail("Manager release descriptor must be a JSON object")
    return document


def verify_command(arguments: argparse.Namespace) -> None:
    version = parse_version(arguments.pubspec)
    names = expected_names(version)
    validate_commit(arguments.expected_git_commit)
    if arguments.expected_release_tag != names["release_tag"]:
        fail("Expected Manager tag does not match manager/pubspec.yaml")

    validate_directory_shape(arguments.directory, version, arguments.require_attestation)
    package = arguments.directory / names["deb_name"]
    metadata, digest = validate_package(package, version)
    document = load_descriptor(arguments.directory / DESCRIPTOR_NAME)

    expected_document = {
        "schema_version": SCHEMA_VERSION,
        "release_kind": "secure-hibernate-manager",
        "version": version,
        "release_tag": names["release_tag"],
        "git_commit": arguments.expected_git_commit,
        "artifact": {
            "name": names["deb_name"],
            "architecture": ARCHITECTURE,
            "size": metadata.st_size,
            "sha256": digest,
        },
    }
    if document != expected_document:
        fail("Manager release descriptor does not match the package or expected source")

    checksums = arguments.directory / CHECKSUMS_NAME
    regular_file(checksums, "Manager checksum file", MAX_DESCRIPTOR_SIZE)
    try:
        checksum_text = checksums.read_text(encoding="ascii")
    except UnicodeDecodeError:
        fail("Manager checksum file must be ASCII")
    if checksum_text != f"{digest}  {names['deb_name']}\n":
        fail("Manager checksum file does not exactly match the package")

    if arguments.require_attestation:
        bundle = arguments.directory / names["bundle_name"]
        bundle_metadata = regular_file(bundle, "Manager attestation bundle", MAX_ATTESTATION_SIZE)
        if bundle_metadata.st_size == 0:
            fail("Manager attestation bundle is empty")
    print(f"Verified Manager release candidate {names['release_tag']}")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    metadata = commands.add_parser("metadata", help="resolve and validate workflow metadata")
    metadata.add_argument("--pubspec", type=Path, required=True)
    metadata.add_argument("--event-name", required=True)
    metadata.add_argument("--ref-type", required=True)
    metadata.add_argument("--ref-name", required=True)
    metadata.add_argument("--default-branch", required=True)
    metadata.set_defaults(handler=metadata_command)

    decision = commands.add_parser(
        "decision",
        help="decide whether a Manager Release is new",
    )
    decision.add_argument("--pubspec", type=Path, required=True)
    decision.add_argument("--event-name", required=True)
    decision.add_argument(
        "--release-exists",
        choices=("true", "false"),
        required=True,
    )
    decision.add_argument("--release-assets", type=Path, required=True)
    decision.set_defaults(handler=decision_command)

    prepare = commands.add_parser("prepare", help="assemble checksum and release metadata")
    prepare.add_argument("directory", type=Path)
    prepare.add_argument("--pubspec", type=Path, required=True)
    prepare.add_argument("--git-commit", required=True)
    prepare.set_defaults(handler=prepare_command)

    verify = commands.add_parser("verify", help="verify an assembled Manager release")
    verify.add_argument("directory", type=Path)
    verify.add_argument("--pubspec", type=Path, required=True)
    verify.add_argument("--expected-release-tag", required=True)
    verify.add_argument("--expected-git-commit", required=True)
    verify.add_argument("--require-attestation", action="store_true")
    verify.set_defaults(handler=verify_command)
    return root


def main() -> int:
    try:
        arguments = parser().parse_args()
        arguments.handler(arguments)
    except ReleaseError as error:
        print(f"manager-release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
