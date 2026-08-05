#!/usr/bin/env python3
"""Create and verify project-signed Release manifests."""

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


MANIFEST_NAME = "release-manifest.json"
SIGNATURE_NAME = "release-manifest.p7s"
CERTIFICATE_NAME = "secure-hibernate-project.pem"
DER_CERTIFICATE_NAME = "secure-hibernate-project.der"
SCHEMA_VERSION = 1
MAX_MANIFEST_SIZE = 1024 * 1024
MAX_SIGNATURE_SIZE = 1024 * 1024
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*$")
SOURCE_VERSION = re.compile(
    r"^(?P<source>[0-9]+\.[0-9]+\.[0-9]+)-(?P<abi>[0-9]+)\.[0-9]+"
    r"(?:[.+~][0-9A-Za-z.+~-]+)?$"
)
KERNEL_RELEASE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_~-]*-hibernate$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
TOP_LEVEL_KEYS = {
    "schema_version",
    "ubuntu_source_package_version",
    "kernel_release",
    "release_tag",
    "git_commit",
    "certificate_sha256",
    "assets",
}
ASSET_KEYS = {"name", "size", "sha256"}


class ManifestError(Exception):
    pass


def fail(message: str) -> None:
    raise ManifestError(message)


def run(command: list[str], *, capture: bool = False) -> bytes:
    try:
        result = subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError:
        fail(f"Required command not found: {command[0]}")
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode("utf-8", "replace").strip()
        fail(detail or f"Command failed: {command[0]}")
    return result.stdout


def require_regular_file(path: Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"{label} is missing: {path.name}")
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular file: {path.name}")
    return metadata


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def certificate_der(certificate: Path) -> bytes:
    require_regular_file(certificate, "Pinned certificate")
    return run(
        ["openssl", "x509", "-in", str(certificate), "-outform", "DER"],
        capture=True,
    )


def certificate_fingerprint(certificate: Path) -> str:
    return hashlib.sha256(certificate_der(certificate)).hexdigest()


def read_text_file(path: Path, label: str) -> str:
    require_regular_file(path, label)
    try:
        value = path.read_text(encoding="ascii")
    except UnicodeDecodeError:
        fail(f"{label} must contain ASCII text: {path.name}")
    if not value.endswith("\n") or value.count("\n") != 1:
        fail(f"{label} must contain exactly one newline-terminated value: {path.name}")
    return value[:-1]


def expected_tag(source_version: str) -> str:
    return f"ubuntu-{source_version.replace('~', '_')}"


def validate_metadata_values(
    source_version: str, kernel_release: str, release_tag: str, git_commit: str
) -> None:
    if not SOURCE_VERSION.fullmatch(source_version):
        fail(f"Unsupported Ubuntu source package version: {source_version}")
    if not KERNEL_RELEASE.fullmatch(kernel_release):
        fail(f"Unsupported kernel release: {kernel_release}")
    if release_tag != expected_tag(source_version):
        fail(f"Release tag does not match the source version: {release_tag}")
    if not COMMIT.fullmatch(git_commit):
        fail("Git commit must be a lowercase 40-character SHA-1 object ID")


def validate_payload_shape(
    directory: Path, kernel_release: str, *, require_checksums: bool = True
) -> list[str]:
    names: list[str] = []
    for entry in directory.iterdir():
        if entry.name in {MANIFEST_NAME, SIGNATURE_NAME}:
            continue
        require_regular_file(entry, "Release asset")
        if not SAFE_NAME.fullmatch(entry.name):
            fail(f"Unsafe Release asset filename: {entry.name!r}")
        names.append(entry.name)

    names.sort()
    required_names = {
        "kernel-release.txt",
        "local-version.txt",
        "ubuntu-source-package-version.txt",
        CERTIFICATE_NAME,
        DER_CERTIFICATE_NAME,
    }
    if require_checksums:
        required_names.add("SHA256SUMS")
    missing = sorted(required_names.difference(names))
    if missing:
        fail(f"Required Release assets are missing: {', '.join(missing)}")

    patterns = {
        "headers": re.compile(
            rf"^linux-headers-{re.escape(kernel_release)}_.+_amd64\.deb$"
        ),
        "unsigned image": re.compile(
            rf"^linux-image-{re.escape(kernel_release)}_.+_amd64\.deb$"
        ),
        "signed image": re.compile(
            rf"^signed-linux-image-{re.escape(kernel_release)}_.+_amd64\.deb$"
        ),
    }
    matched: set[str] = set(required_names)
    for label, pattern in patterns.items():
        matches = [name for name in names if pattern.fullmatch(name)]
        if len(matches) != 1:
            fail(f"Expected exactly one {label} package, found {len(matches)}")
        matched.add(matches[0])

    extras = sorted(set(names).difference(matched))
    if extras:
        fail(f"Unexpected Release assets: {', '.join(extras)}")
    return names


def package_field(package: Path, field: str) -> str:
    return run(["dpkg-deb", "-f", str(package), field], capture=True).decode().strip()


def validate_payload_metadata(
    directory: Path,
    source_version: str,
    kernel_release: str,
    fingerprint: str,
) -> None:
    recorded_source = read_text_file(
        directory / "ubuntu-source-package-version.txt", "Source-version metadata"
    )
    recorded_kernel = read_text_file(
        directory / "kernel-release.txt", "Kernel-release metadata"
    )
    local_version = read_text_file(directory / "local-version.txt", "Local-version metadata")
    if recorded_source != source_version:
        fail("Source-version metadata does not match the Manifest")
    if recorded_kernel != kernel_release:
        fail("Kernel-release metadata does not match the Manifest")
    if not re.fullmatch(r"-[0-9A-Za-z][0-9A-Za-z.+~-]*", local_version):
        fail(f"Invalid local-version metadata: {local_version}")
    if not kernel_release.endswith(local_version):
        fail("Kernel release does not end with the recorded local version")

    release_pem = directory / CERTIFICATE_NAME
    release_der = directory / DER_CERTIFICATE_NAME
    if hashlib.sha256(certificate_der(release_pem)).hexdigest() != fingerprint:
        fail("Release PEM certificate does not match the pinned certificate")
    require_regular_file(release_der, "Release DER certificate")
    if hashlib.sha256(release_der.read_bytes()).hexdigest() != fingerprint:
        fail("Release DER certificate does not match the pinned certificate")

    package_names = [
        name
        for name in validate_payload_shape(directory, kernel_release)
        if name.endswith(".deb")
    ]
    expected_version = f"1{local_version}+ubuntu{source_version}"
    for name in package_names:
        package = directory / name
        expected_package = (
            f"linux-image-{kernel_release}"
            if name.startswith(("linux-image-", "signed-linux-image-"))
            else f"linux-headers-{kernel_release}"
        )
        if package_field(package, "Package") != expected_package:
            fail(f"Debian package name does not match its asset filename: {name}")
        if package_field(package, "Version") != expected_version:
            fail(f"Debian package version does not match the Release metadata: {name}")
        if package_field(package, "Architecture") != "amd64":
            fail(f"Debian package architecture is not amd64: {name}")


def canonical_checksums(directory: Path, names: list[str]) -> bytes:
    lines = [
        f"{sha256_file(directory / name)}  {name}\n"
        for name in names
        if name != "SHA256SUMS"
    ]
    return "".join(lines).encode("ascii")


def build_assets(directory: Path, names: list[str]) -> list[dict[str, Any]]:
    return [
        {
            "name": name,
            "size": require_regular_file(directory / name, "Release asset").st_size,
            "sha256": sha256_file(directory / name),
        }
        for name in names
    ]


def no_duplicate_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"Duplicate JSON object key: {key}")
        result[key] = value
    return result


def load_manifest(path: Path) -> dict[str, Any]:
    metadata = require_regular_file(path, "Release Manifest")
    if metadata.st_size > MAX_MANIFEST_SIZE:
        fail("Release Manifest exceeds the size limit")
    try:
        document = json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=no_duplicate_object
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"Invalid Release Manifest JSON: {error}")
    if not isinstance(document, dict):
        fail("Release Manifest must be a JSON object")
    return document


def validate_manifest_schema(document: dict[str, Any]) -> None:
    if set(document) != TOP_LEVEL_KEYS:
        fail("Release Manifest has missing or unknown top-level fields")
    if document["schema_version"] != SCHEMA_VERSION or isinstance(
        document["schema_version"], bool
    ):
        fail(f"Unsupported Release Manifest schema: {document['schema_version']!r}")
    for field in (
        "ubuntu_source_package_version",
        "kernel_release",
        "release_tag",
        "git_commit",
        "certificate_sha256",
    ):
        if not isinstance(document[field], str):
            fail(f"Release Manifest field must be a string: {field}")
    if not SHA256.fullmatch(document["certificate_sha256"]):
        fail("Invalid certificate SHA-256 fingerprint")
    validate_metadata_values(
        document["ubuntu_source_package_version"],
        document["kernel_release"],
        document["release_tag"],
        document["git_commit"],
    )

    assets = document["assets"]
    if not isinstance(assets, list) or not assets:
        fail("Release Manifest assets must be a non-empty array")
    previous_name = ""
    for asset in assets:
        if not isinstance(asset, dict) or set(asset) != ASSET_KEYS:
            fail("Release Manifest asset has missing or unknown fields")
        name = asset["name"]
        size = asset["size"]
        digest = asset["sha256"]
        if not isinstance(name, str) or not SAFE_NAME.fullmatch(name):
            fail(f"Unsafe Release asset filename in Manifest: {name!r}")
        if name <= previous_name:
            fail("Release Manifest assets must have unique, lexically sorted names")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            fail(f"Invalid Release asset size: {name}")
        if not isinstance(digest, str) or not SHA256.fullmatch(digest):
            fail(f"Invalid Release asset SHA-256: {name}")
        previous_name = name


def verify_cms(directory: Path, certificate: Path) -> None:
    manifest = directory / MANIFEST_NAME
    signature = directory / SIGNATURE_NAME
    require_regular_file(manifest, "Release Manifest")
    signature_metadata = require_regular_file(signature, "Release Manifest signature")
    if signature_metadata.st_size > MAX_SIGNATURE_SIZE:
        fail("Release Manifest signature exceeds the size limit")
    run(
        [
            "openssl",
            "cms",
            "-verify",
            "-binary",
            "-inform",
            "DER",
            "-in",
            str(signature),
            "-content",
            str(manifest),
            "-nointern",
            "-certfile",
            str(certificate),
            "-CAfile",
            str(certificate),
            "-no-CApath",
            "-no-CAstore",
            "-purpose",
            "any",
            "-verify_retcode",
            "-out",
            os.devnull,
        ]
    )


def verify_directory(
    directory: Path,
    certificate: Path,
    *,
    minimum_source_version: str | None = None,
    expected_release_tag: str | None = None,
    expected_git_commit: str | None = None,
) -> dict[str, Any]:
    if not directory.is_dir():
        fail(f"Release directory does not exist: {directory}")
    verify_cms(directory, certificate)
    document = load_manifest(directory / MANIFEST_NAME)
    validate_manifest_schema(document)

    fingerprint = certificate_fingerprint(certificate)
    if document["certificate_sha256"] != fingerprint:
        fail("Release Manifest certificate fingerprint does not match the pinned certificate")
    if expected_release_tag is not None and document["release_tag"] != expected_release_tag:
        fail("Release Manifest tag does not match the expected GitHub Release tag")
    if expected_git_commit is not None and document["git_commit"] != expected_git_commit:
        fail("Release Manifest commit does not match the expected Git commit")
    if minimum_source_version is not None:
        if not SOURCE_VERSION.fullmatch(minimum_source_version):
            fail(f"Invalid minimum Ubuntu source package version: {minimum_source_version}")
        try:
            result = subprocess.run(
                [
                    "dpkg",
                    "--compare-versions",
                    document["ubuntu_source_package_version"],
                    "ge",
                    minimum_source_version,
                ],
                check=False,
            )
        except FileNotFoundError:
            fail("Required command not found: dpkg")
        if result.returncode != 0:
            fail(
                "Release source version is older than the minimum allowed version: "
                f"{document['ubuntu_source_package_version']} < {minimum_source_version}"
            )

    declared_names = [asset["name"] for asset in document["assets"]]
    actual_names = sorted(
        entry.name
        for entry in directory.iterdir()
        if entry.name not in {MANIFEST_NAME, SIGNATURE_NAME}
    )
    if actual_names != declared_names:
        missing = sorted(set(declared_names).difference(actual_names))
        extra = sorted(set(actual_names).difference(declared_names))
        details = []
        if missing:
            details.append(f"missing: {', '.join(missing)}")
        if extra:
            details.append(f"extra: {', '.join(extra)}")
        fail(f"Release asset set does not match the Manifest ({'; '.join(details)})")

    validate_payload_shape(directory, document["kernel_release"])
    for asset in document["assets"]:
        path = directory / asset["name"]
        metadata = require_regular_file(path, "Release asset")
        if metadata.st_size != asset["size"]:
            fail(f"Release asset size mismatch: {asset['name']}")
        if sha256_file(path) != asset["sha256"]:
            fail(f"Release asset SHA-256 mismatch: {asset['name']}")

    expected_checksums = canonical_checksums(directory, declared_names)
    if (directory / "SHA256SUMS").read_bytes() != expected_checksums:
        fail("SHA256SUMS is not the canonical checksum list for the Release payload")
    validate_payload_metadata(
        directory,
        document["ubuntu_source_package_version"],
        document["kernel_release"],
        fingerprint,
    )
    return document


def create_manifest(arguments: argparse.Namespace, certificate: Path) -> None:
    directory = Path(arguments.directory).resolve()
    if not directory.is_dir():
        fail(f"Release directory does not exist: {directory}")
    manifest_path = directory / MANIFEST_NAME
    signature_path = directory / SIGNATURE_NAME
    checksums_path = directory / "SHA256SUMS"
    if manifest_path.exists() or signature_path.exists() or checksums_path.exists():
        fail("Refusing to overwrite existing Release metadata")

    validate_metadata_values(
        arguments.source_version,
        arguments.kernel_release,
        arguments.release_tag,
        arguments.git_commit,
    )
    fingerprint = certificate_fingerprint(certificate)
    names_without_checksums = validate_payload_shape(
        directory, arguments.kernel_release, require_checksums=False
    )
    private_key = Path(arguments.private_key).resolve()
    key_metadata = require_regular_file(private_key, "Manifest signing private key")
    if stat.S_IMODE(key_metadata.st_mode) & 0o077:
        fail("Refusing a Manifest signing key readable by users other than its owner")

    try:
        checksums_path.write_bytes(canonical_checksums(directory, names_without_checksums))
        names = validate_payload_shape(directory, arguments.kernel_release)
        validate_payload_metadata(
            directory, arguments.source_version, arguments.kernel_release, fingerprint
        )
        document = {
            "schema_version": SCHEMA_VERSION,
            "ubuntu_source_package_version": arguments.source_version,
            "kernel_release": arguments.kernel_release,
            "release_tag": arguments.release_tag,
            "git_commit": arguments.git_commit,
            "certificate_sha256": fingerprint,
            "assets": build_assets(directory, names),
        }
        encoded = (json.dumps(document, indent=2, ensure_ascii=True) + "\n").encode(
            "ascii"
        )

        with tempfile.TemporaryDirectory(
            prefix=".release-manifest-", dir=directory.parent
        ) as temp:
            temporary_manifest = Path(temp) / MANIFEST_NAME
            temporary_signature = Path(temp) / SIGNATURE_NAME
            temporary_manifest.write_bytes(encoded)
            run(
                [
                    "openssl",
                    "cms",
                    "-sign",
                    "-binary",
                    "-in",
                    str(temporary_manifest),
                    "-signer",
                    str(certificate),
                    "-inkey",
                    str(private_key),
                    "-outform",
                    "DER",
                    "-out",
                    str(temporary_signature),
                    "-md",
                    "sha256",
                    "-nosmimecap",
                ]
            )
            os.replace(temporary_manifest, manifest_path)
            os.replace(temporary_signature, signature_path)

        verify_directory(directory, certificate)
    except ManifestError:
        manifest_path.unlink(missing_ok=True)
        signature_path.unlink(missing_ok=True)
        checksums_path.unlink(missing_ok=True)
        raise
    print(f"Created and verified {manifest_path.name} and {signature_path.name}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create", help="create and sign a Release Manifest")
    create.add_argument("directory")
    create.add_argument("--source-version", required=True)
    create.add_argument("--kernel-release", required=True)
    create.add_argument("--release-tag", required=True)
    create.add_argument("--git-commit", required=True)
    create.add_argument("--private-key", required=True)

    verify = subparsers.add_parser("verify", help="verify a signed Release directory")
    verify.add_argument("directory")
    verify.add_argument("--minimum-source-version")
    verify.add_argument("--expected-release-tag")
    verify.add_argument("--expected-git-commit")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    repo_root = Path(__file__).resolve().parent.parent
    certificate = repo_root / "certs" / CERTIFICATE_NAME
    try:
        if arguments.command == "create":
            create_manifest(arguments, certificate)
        else:
            document = verify_directory(
                Path(arguments.directory).resolve(),
                certificate,
                minimum_source_version=arguments.minimum_source_version,
                expected_release_tag=arguments.expected_release_tag,
                expected_git_commit=arguments.expected_git_commit,
            )
            print(
                "Verified signed Release Manifest for "
                f"{document['ubuntu_source_package_version']} "
                f"({document['kernel_release']})"
            )
    except ManifestError as error:
        print(f"release-manifest: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
