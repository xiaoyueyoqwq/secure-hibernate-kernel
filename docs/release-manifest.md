# Signed Release Manifest

## Purpose

GitHub currently reports this project's Releases as mutable. `SHA256SUMS`
cannot authenticate files when an actor can replace both a payload and its
checksum. Every Release after `ubuntu-7.0.0-28.28` therefore includes a JSON
Manifest and a detached CMS signature made with the project MOK key.

Clients trust the repository copy of `certs/secure-hibernate-project.pem`, not a
certificate selected from the downloaded Release. The same certificate can
therefore authenticate both the Secure Boot payload and the Release metadata.

## Schema version 1

`release-manifest.json` is an ASCII JSON object with these exact top-level
fields:

```json
{
  "schema_version": 1,
  "ubuntu_source_package_version": "7.0.0-29.29",
  "kernel_release": "7.0.13-ubuntu29-s4lockdown",
  "release_tag": "ubuntu-7.0.0-29.29",
  "git_commit": "0123456789abcdef0123456789abcdef01234567",
  "certificate_sha256": "5f59e3e38f5a3c3f276beca6c2abd3cb20296d7fd3d0a2db9dbc83b0dd889711",
  "assets": [
    {
      "name": "SHA256SUMS",
      "size": 1024,
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  ]
}
```

The real `assets` array contains every Release payload in lexical filename
order. It includes `SHA256SUMS`, packages, build metadata, and both public
certificate encodings. It excludes only `release-manifest.json` and its
detached `release-manifest.p7s`, which cannot recursively describe themselves.

The certificate fingerprint is the lowercase SHA-256 digest of the certificate
in DER encoding. Asset names are restricted to a portable basename character
set and cannot contain whitespace, path separators, control characters, or
leading punctuation.

## Verification contract

Run the verifier from a trusted checkout:

```bash
scripts/release-manifest.py verify /path/to/release \
  --expected-release-tag ubuntu-7.0.0-29.29 \
  --minimum-source-version 7.0.0-28.28
```

Verification fails unless all of these conditions hold:

- the detached CMS signature is valid under the exact pinned certificate;
- the schema contains only recognized fields and canonical asset ordering;
- the source version, kernel release, tag, local version, and Debian package
  metadata agree;
- the Manifest certificate fingerprint and both Release certificate files
  match the pinned certificate;
- every declared asset is a regular file with the exact signed size and hash;
- no declared asset is missing and no undeclared asset is present;
- `SHA256SUMS` is the canonical checksum list for the remaining payload;
- an optional expected tag, Git commit, and minimum source version match.

The verifier authenticates downloaded files. Package installation must still
run `scripts/install-signed-packages.sh --check-only` to validate the EFI image,
every kernel module, and matching headers before `dpkg` changes the system.

## Signing boundary

Only the protected `release-signing` job can run the `create` command with the
project private key. It assembles the final payload, generates `SHA256SUMS`,
writes and signs the Manifest, and immediately verifies the result. The private
key is then deleted by the job's unconditional cleanup step.

The publish job receives the signed directory as an Actions artifact. It checks
out the trusted verifier, re-verifies the tag and workflow commit, and publishes
the exact files without regenerating metadata. The publish job never receives
the signing environment or private key.
