# Ubuntu Secure Boot hibernation kernel

This project builds a narrowly patched Ubuntu kernel that permits traditional
hibernation while kernel integrity lockdown is active. GitHub Actions builds
the kernel, signs its EFI image and modules with a dedicated project MOK, and
publishes verified Debian packages. Users enroll the public project certificate
once and can then install the same signed packages.

## Security boundary

Linux blocks hibernation during integrity lockdown because the standard resume
image is not authenticated before it replaces kernel memory. This patch makes
that policy configurable and enables the exception in this build.

The intended system stores its swap file inside a LUKS-encrypted root volume.
That protects a powered-off machine from offline inspection without the LUKS
key. It does not protect against an attacker who already has privileged access
while the encrypted volume is open and can modify a future resume image.

Do not use this build when Secure Boot is expected to defend against malicious
local root or an equivalent running-system compromise.

Enrolling the project MOK also trusts every future kernel signed by the project
private key. That key is stored as a secret in the `release-signing` GitHub
environment. The build and publishing jobs cannot access it; only the isolated
signing job receives it. A compromise of that key or signing workflow affects
every system that enrolls the project certificate.

See [Rationale, measurements, and audit boundary](docs/rationale-and-audit.md)
for the affected-platform evidence, exact retained guarantees, and upstream
positioning.

Maintainers should also read
[Project signing key lifecycle](docs/project-signing-key-lifecycle.md) before
changing the signing certificate, GitHub environment, or Release workflow.

## Build in GitHub Actions

Run the `Build Ubuntu hibernation kernel` workflow with `auto`, or specify an
exact Ubuntu source package version. Automatic builds follow the current
`linux-image-generic-hwe-26.04` package. Kernel releases include the Ubuntu ABI
in a suffix such as `-ubuntu28-s4lockdown`, so a new ABI installs alongside the
previous custom and official kernels instead of replacing their module trees.

The workflow downloads the matching `linux-source` and generic kernel config
from Ubuntu and applies the patch. A build job with read-only repository access
produces unsigned packages. A separate job uses Ubuntu's packaged `sign-file`
and the protected project secret to sign them. A final job without the secret
publishes the verified Release. Access to the signing environment requires an
explicit maintainer approval. A daily scheduled check skips complete Release
tags, and the workflow refuses to modify an existing tag. GitHub currently
reports these Releases as `immutable: false`, so this is a workflow policy, not
a platform-level immutability guarantee.

New Releases contain the project-signed image, the unsigned image for users who
prefer an independent MOK, headers, public project certificates, metadata,
`SHA256SUMS`, `release-manifest.json`, and its detached CMS signature
`release-manifest.p7s`. They exclude the optional multi-gigabyte debug-symbol
package. The Manifest binds the Ubuntu source version, kernel release, Release
tag, Git commit, project-certificate fingerprint, and the exact name, size, and
SHA-256 value of every payload asset. The verifier rejects missing, additional,
non-regular, or unsafe-named assets. The first Release,
`ubuntu-7.0.0-28.28`, predates this format and remains available for manual
installation only; it will not be modified retroactively.

The exact project certificate cryptographically protects the EFI image,
modules, and Release Manifest. `SHA256SUMS` remains useful for ordinary file
checks, but is not an independent authenticity proof when hosted in the same
mutable Release. The full Linux source tree is not committed here.

With GitHub CLI, a completed Release can be downloaded with:

```bash
gh release download ubuntu-SOURCE_PACKAGE_VERSION --dir release
scripts/release-manifest.py verify release \
  --expected-release-tag ubuntu-SOURCE_PACKAGE_VERSION
```

`--minimum-source-version VERSION` rejects a signed Release older than the
recorded local source version. This is intended for the automatic updater's
downgrade check. The complete schema and verification contract are documented
in [`docs/release-manifest.md`](docs/release-manifest.md).

## Enroll the project MOK

The public trust anchor is `certs/secure-hibernate-project.der`. Its SHA-256
fingerprint is:

```text
5F:59:E3:E3:8F:5A:3C:3F:27:6B:EC:A6:C2:AB:D3:CB:
20:29:6D:7F:D3:D0:A2:DB:9D:BC:83:B0:DD:88:97:11
```

Request enrollment, choose a temporary one-time password, and reboot into
MokManager to confirm it:

```bash
pkexec /usr/bin/mokutil --import \
  "$(realpath certs/secure-hibernate-project.der)"
```

The temporary password authorizes only the pending enrollment. It is unrelated
to the project private key, login password, or LUKS passphrase.

After enrollment, validate and install a downloaded Release:

```bash
scripts/install-signed-packages.sh --check-only \
  release certs/secure-hibernate-project.pem
pkexec "$(realpath scripts/install-signed-packages.sh)" \
  release certs/secure-hibernate-project.pem
```

## Use an independent MOK

Users who do not want to trust the shared project key can sign the unsigned
image from the same Release with a machine-specific MOK.

Install the local tooling once:

```bash
pkexec /usr/bin/apt-get install -y \
  linux-headers-generic-hwe-26.04 openssl perl python3 sbsigntool xz-utils zstd
```

Keep the private key outside this repository and restrict it to mode `0600`:

```bash
scripts/sign-packages.sh \
  artifacts/ubuntu-hibernation-kernel-7.0.0-28.28 \
  /path/to/MOK.priv /path/to/MOK.pem
```

The script resolves `sign-file` only from an installed, root-owned Ubuntu
generic headers package. It signs every kernel module, signs the EFI-stub
kernel image, and rebuilds the image package. Header packages are copied
unchanged. It does not install packages, enroll a MOK, edit GRUB, alter
initramfs, or change TPM/LUKS configuration.

The Release download, checksum, and local signing steps can be run together:

```bash
scripts/prepare-release.sh /path/to/MOK.priv /path/to/MOK.pem auto
```

For every new tag, `prepare-release.sh` authenticates the download with the
project-signed Manifest before exposing any package to the local signing key.
Only the append-only-by-project-policy legacy tag `ubuntu-7.0.0-28.28` uses its
original `SHA256SUMS`-only manual path.

`scripts/install-signed-packages.sh` cryptographically validates the PE image
and every module against the selected certificate, checks signer metadata and
matching headers, installs the packages, and selects the custom kernel while
keeping official Ubuntu kernels in Advanced options. It preserves the user's
existing GRUB menu visibility and timeout. Validation can be run without root
or installation first:

```bash
scripts/install-signed-packages.sh --check-only /path/to/signed /path/to/MOK.pem
```

After the certificate has been enrolled through MokManager, install the checked
packages with a desktop authorization prompt:

```bash
pkexec "$(realpath scripts/install-signed-packages.sh)" \
  /path/to/signed /path/to/MOK.pem
```

## System integration

`scripts/install-system-config.sh` installs the narrowly scoped dracut,
Polkit, logind, and systemd configuration used by this setup. It enables direct
lid-close hibernation. The hibernation service directly requires a helper that
selects the currently running custom kernel for the next boot; hibernation
fails if that selection cannot be verified. A dedicated top-level GRUB entry
receives the verified kernel path, initrd path, and running command line through
`grubenv`, avoiding the additional measured-boot events produced by parsing the
complete Advanced submenu. This preserves exact-kernel resume even when a newer
kernel has become the normal default.

The system configuration does not create swap, modify LUKS tokens, enroll a
MOK, or remove official kernels. Those operations remain explicit because
their correct recovery procedure depends on the target machine.

For a machine that already has disk-backed swap inside its encrypted root
volume, deploy the integration and create a separate LUKS2 header backup with:

```bash
pkexec "$(realpath scripts/deploy-system.sh)" \
  /dev/ROOT_LUKS /path/to/new-luks-header.img KERNEL_RELEASE
```

The backup path must not exist. The command leaves every existing LUKS
keyslot and TPM token unchanged. Additional TPM enrollment is deliberately a
separate `systemd-cryptenroll` operation so its recovery implications remain
visible.

## Updating

Normal Ubuntu updates remain enabled, including the official HWE meta-package.
The scheduled workflow publishes project-signed and unsigned packages when that
meta-package moves to a new source version. New Releases now carry the signed
Manifest required by an unattended verifier. Installing a published package is
still an explicit local operation; the next implementation stage is the local
update service that downloads, verifies, installs, and notifies without
receiving the signing key. Always retain at least one official Ubuntu kernel as
a recovery boot option.

## License

GPL-2.0-only. The Linux kernel source downloaded during the build is governed
by its own copyright notices and license files.
