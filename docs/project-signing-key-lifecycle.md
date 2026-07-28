# Project signing key lifecycle

## Scope

The shared project MOK lets users enroll one public certificate and install
project-signed kernel updates without signing each Release locally. It is a
Secure Boot trust anchor, not an identity certificate or an encryption key.

The current certificate has these properties:

- Subject: `CN=Secure Hibernate Kernel Project`
- Algorithm: RSA-3072 with SHA-256
- Extended key usage: code signing
- Validity: 2026-07-28 through 2036-07-25
- SHA-256 fingerprint:
  `5F:59:E3:E3:8F:5A:3C:3F:27:6B:EC:A6:C2:AB:D3:CB:20:29:6D:7F:D3:D0:A2:DB:9D:BC:83:B0:DD:88:97:11`

The public PEM and DER forms are committed under `certs/`. The private key
must never be committed, uploaded as an artifact, included in a Release, or
stored in a repository-level secret.

## Generate a new key

Generate signing material on a trusted machine, outside the repository. The
private key is intentionally unencrypted because GitHub Actions cannot answer
an interactive passphrase prompt; access control therefore depends on the
GitHub environment and the offline backup procedure.

```bash
install -d -m 0700 /path/to/private-signing-directory
openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes \
  -days 3650 \
  -subj '/CN=Secure Hibernate Kernel Project/' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,digitalSignature,keyCertSign' \
  -addext 'extendedKeyUsage=codeSigning' \
  -keyout /path/to/private-signing-directory/MOK.priv \
  -out /path/to/private-signing-directory/MOK.pem
chmod 0600 /path/to/private-signing-directory/MOK.priv
openssl x509 -in /path/to/private-signing-directory/MOK.pem \
  -outform DER -out certs/secure-hibernate-project.der
cp /path/to/private-signing-directory/MOK.pem \
  certs/secure-hibernate-project.pem
```

Record and independently compare the fingerprint before distributing the
certificate:

```bash
openssl x509 -in certs/secure-hibernate-project.pem \
  -noout -subject -dates -fingerprint -sha256
openssl x509 -in certs/secure-hibernate-project.der -inform DER \
  -noout -fingerprint -sha256
```

Verify that the public certificate matches the private key without printing
private key material:

```bash
openssl pkey -in /path/to/private-signing-directory/MOK.priv \
  -pubout -outform DER | sha256sum
openssl x509 -in certs/secure-hibernate-project.pem \
  -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum
```

The two hashes must be identical. Keep an offline encrypted backup of the
private key. Losing the only copy prevents future project-signed updates;
exposing it requires certificate rotation on every enrolled machine.

## Configure GitHub Actions

Create an Actions environment named `release-signing`, restrict deployments to
`main` with a custom branch policy, require a maintainer approval before jobs
can access it, and add the base64-encoded private key as the environment secret
`PROJECT_MOK_PRIVATE_KEY_B64`:

```bash
base64 -w0 /path/to/private-signing-directory/MOK.priv \
  | gh secret set PROJECT_MOK_PRIVATE_KEY_B64 --env release-signing
```

Do not print the encoded value or pass it on the command line. The workflow
must preserve three separate jobs:

- `build` has read-only repository access and no signing environment.
- `sign` receives the `release-signing` environment and has no write access.
- `publish` can upload Releases and never receives the signing environment.

Every signing path must use a root-owned `sign-file` from an installed Ubuntu
headers package. Never execute a helper downloaded with the unsigned packages;
it would receive the private-key path. The signing job must cryptographically
verify the signed image and every module, and delete its temporary private-key
file under `if: always()`.

Published Release assets are immutable. The publish job creates a draft,
uploads and verifies the complete asset set, then publishes it. A repeated
manual dispatch for the same source tag must fail rather than replace assets.
An incomplete draft may be deleted and rebuilt because it has never been
published; published tags require a new, distinct tag.

## Planned rotation

Do not replace the existing certificate files in an already published tag.
Introduce a new, distinctly named certificate alongside the old one and use a
transition period:

1. Generate and audit the new key pair, then add its public certificate to the
   repository.
2. Publish the new fingerprint through the repository and Release notes.
3. Ask users to enroll the new DER certificate while the old certificate is
   still accepted.
4. Update the environment secret and workflow to sign new Releases with the
   new key.
5. Verify a project-signed Release and a real Secure Boot installation before
   retiring the old key.
6. Ask users to delete the old MOK only after they have a bootable kernel signed
   by the new key and an official Ubuntu recovery kernel.

Keep certificate names versioned during a transition. A Release must include
the exact certificate used to verify its packages, and `SHA256SUMS` must cover
that certificate.

## Compromise and revocation

GitHub cannot centrally remove a MOK already enrolled in user firmware. If the
private key or signing job is suspected to be compromised:

1. Delete or replace `PROJECT_MOK_PRIVATE_KEY_B64` immediately and disable the
   signing workflow.
2. Publish the affected fingerprint, time window, tags, and package hashes.
3. Generate a new project key and publish only after its handling has been
   audited.
4. Tell users to boot an official Ubuntu kernel, retain LUKS password recovery,
   and request deletion of the compromised certificate with:

```bash
pkexec /usr/bin/mokutil --delete /path/to/compromised-certificate.der
```

MokManager asks for the temporary deletion password on the next reboot. Users
must confirm the old certificate is absent with `mokutil --list-enrolled`
before treating it as revoked. Deleting GitHub Releases or secrets alone does
not revoke trust on installed systems.

Never remove the last known-good kernel or TPM/LUKS recovery method during
rotation or incident response.
