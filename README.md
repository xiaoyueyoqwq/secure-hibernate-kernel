# Ubuntu Secure Boot hibernation kernel

This project provides a narrowly patched Ubuntu kernel that permits traditional
hibernation while kernel integrity lockdown is active. It includes a signed
kernel Release chain, a local update controller, and a Flutter desktop Manager
that handles installation, live security checks, MOK enrollment, updates, and
optional TPM-backed LUKS unlock.

GitHub Actions follows Ubuntu's current `linux-image-generic-hwe-26.04` source,
applies the lockdown exception, builds image and Headers packages, signs the EFI
image and modules with a dedicated project MOK, and publishes an authenticated
Release. Official Ubuntu kernels and the HWE meta-package remain installed as
independent recovery paths.

## Security boundary

Linux normally blocks hibernation during integrity lockdown because a resume
image is not authenticated before it replaces kernel memory. This build makes
that policy configurable and enables the exception. The intended system stores
disk-backed Swap inside a LUKS-encrypted root volume so a powered-off machine
does not expose the hibernation image without its LUKS key.

This design does not protect against malicious local root or equivalent access
while the encrypted volume is open. Such an attacker can modify a future resume
image. Do not use this build when Secure Boot is expected to defend against
that threat.

The Manager permits an explicit installation without LUKS, skips TPM unlock
setup, and retains a security warning. In that configuration, an offline party
can read session data and potentially key material from the hibernation image.

Enrolling the project MOK trusts every future kernel signed by the project
private key. That key exists only in the protected `release-signing` GitHub
environment; build and publishing jobs cannot read it. A compromise of the key
or signing workflow affects every system that enrolled the certificate.

See [Rationale and audit boundary](docs/rationale-and-audit.md) for the exact
guarantees, limitations, measurements, and upstream context.

## Recommended installation

[Secure Hibernate Manager](manager/README.md) is the supported installation
and maintenance interface. It checks the running Linux version, UEFI Secure
Boot, Lockdown, storage encryption, disk-backed Swap, and official Ubuntu
fallback before changing the machine. Downloads run as a dedicated
low-privilege account; privileged work uses a fixed root-owned Helper through
Polkit and repeats Release and package verification.

Manager and kernel Releases use independent version axes. Manager Releases use
`manager-v<version>` from `manager/pubspec.yaml`; kernel tags remain
`ubuntu-<source-version>`. A new Manager version on `main` builds only the amd64
Manager package, while the scheduled kernel workflow never builds the Manager.

Launch the Flutter development application directly from the repository root:

```bash
./dev.sh
```

Download a published Manager Release, or build it locally from `manager/`:

```bash
flutter pub get
./scripts/build-deb.sh
pkexec /usr/bin/apt-get install ./dist/secure-hibernate-manager_*.deb
```

Package installation deploys the application and update controller. It does
not enroll the project MOK, install a kernel, change LUKS/TPM metadata, or
restart automatically. Those operations remain explicit steps in the Manager.

The `Build and release Secure Hibernate Manager` workflow checks the version on
every `main` push. It skips an existing complete Release; a new version is
built, tested, signed with GitHub OIDC/Sigstore provenance, and published
automatically. The application icon is a recolored rendering of the CC0-1.0 AMP
icon from `gilbarbara/logos`. CC0 does not grant trademark rights; this project
is not affiliated with or endorsed by the AMP project.

## Release chain

Run the `Build Ubuntu hibernation kernel` workflow with `auto`, or supply an
exact Ubuntu source package version. Kernel releases include the Ubuntu ABI in
a suffix such as `-ubuntu28-s4lockdown`, so new project and official kernels
install alongside one another.

The workflow separates trust domains:

1. A read-only build job downloads Ubuntu source and produces unsigned Debian
   packages.
2. An approval-protected signing job uses Ubuntu's packaged `sign-file` and the
   project secret to sign the image, modules, and Release Manifest.
3. A publishing job without the private key re-verifies and publishes the exact
   signed assets.

Each current Release contains the signed and unsigned image packages, Headers,
public project certificates, `SHA256SUMS`, `release-manifest.json`, and its
detached CMS signature. The Manifest binds the Ubuntu source version, kernel
release, tag, Git commit, project-certificate fingerprint, and every payload's
name, size, and SHA-256 value. It rejects missing, additional, non-regular, and
unsafe-named assets.

`ubuntu-7.0.0-28.28` is the sole pre-Manifest Release. The controller accepts it
only for project-signed first installation by matching an embedded canonical
repository, commit, asset, size, and hash snapshot at both trust boundaries.
Every later Release requires the signed Manifest.

GitHub currently reports project Releases as `immutable: false`. The workflow
refuses to reuse a tag, but that is project policy rather than platform-level
asset immutability.

Download and verify a completed Release with:

```bash
gh release download ubuntu-SOURCE_PACKAGE_VERSION --dir release
scripts/release-manifest.py verify release \
  --expected-release-tag ubuntu-SOURCE_PACKAGE_VERSION
```

The complete format is documented in
[Release Manifest](docs/release-manifest.md). Maintainers changing trust or
workflow configuration must also follow
[Project signing key lifecycle](docs/project-signing-key-lifecycle.md).

## Manual project MOK path

The public trust anchor is `certs/secure-hibernate-project.der`. Its SHA-256
fingerprint is:

```text
5F:59:E3:E3:8F:5A:3C:3F:27:6B:EC:A6:C2:AB:D3:CB:
20:29:6D:7F:D3:D0:A2:DB:9D:BC:83:B0:DD:88:97:11
```

Request enrollment, choose a temporary one-time password, and confirm it in
MokManager after restart:

```bash
pkexec /usr/bin/mokutil --import \
  "$(realpath certs/secure-hibernate-project.der)"
```

The temporary password authorizes only the pending enrollment. It is unrelated
to the project private key, login password, or LUKS recovery password.

After enrollment, validate and install a downloaded Release:

```bash
scripts/install-signed-packages.sh --check-only \
  release certs/secure-hibernate-project.pem
pkexec "$(realpath scripts/install-signed-packages.sh)" \
  release certs/secure-hibernate-project.pem
```

The installer cryptographically verifies the EFI image and every module,
requires matching Headers, installs the project packages, selects the top-level
Ubuntu entry, and hides the normal GRUB menu while keeping Advanced Options
available through the firmware/GRUB reveal key.

## Independent MOK path

Users who do not want to trust the shared project key can sign the unsigned
image from an authenticated Release with a machine-specific MOK kept outside
this repository:

```bash
pkexec /usr/bin/apt-get install -y \
  linux-headers-generic-hwe-26.04 openssl perl python3 sbsigntool xz-utils zstd

scripts/prepare-release.sh /path/to/MOK.priv /path/to/MOK.pem auto
```

The signing path resolves `sign-file` only from an installed, root-owned Ubuntu
Headers package. It never executes a downloaded signing helper. The private key
must remain mode `0600` and must never be committed or uploaded.

## System integration and updates

`scripts/install-system-config.sh` installs the dracut, GRUB, Polkit, logind,
and systemd configuration. Before S4 it selects the currently running project
kernel through a dedicated top-level GRUB entry; hibernation fails if that
selection cannot be verified. The command does not create Swap, modify LUKS
tokens, enroll a MOK, or remove official kernels.

Install the daily local update controller with:

```bash
pkexec "$(realpath scripts/install-update-controller.sh)"
```

The default `check-and-notify` policy downloads and verifies as the dedicated
`s4lockdown-update` user. The root stage independently resolves the current HWE
candidate, copies assets into new root-owned files, and repeats all checks.
`manual` and `automatic-install` are also supported. No policy restarts the
machine. Retention removes only superseded project kernels while preserving the
new kernel, running kernel, all official Ubuntu kernels, and the HWE
meta-package.

See [Local update controller](docs/local-updater.md) for policy, state,
services, failure handling, and manual commands.

## Documentation

- [Manager development and packaging](manager/README.md)
- [Security rationale and audit boundary](docs/rationale-and-audit.md)
- [Release Manifest contract](docs/release-manifest.md)
- [Local update controller](docs/local-updater.md)
- [Project signing key lifecycle](docs/project-signing-key-lifecycle.md)
- [Disposable VM acceptance test](docs/manager-vm-test.md)

## License

GPL-2.0-only. Linux source downloaded during a build remains governed by its
own copyright notices and license files.
