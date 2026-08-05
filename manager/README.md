# Secure Hibernate Manager

Secure Hibernate Manager is the project's Flutter/GTK desktop application for
Ubuntu Linux. It guides installation of the signed hibernation kernel, checks
the live Secure Boot and storage state, manages verified updates, prepares the
project MOK enrollment request, and configures TPM-backed LUKS unlock when the
machine supports it.

The production entry point always uses the fixed native backend. Unit and
Widget tests inject a deterministic in-memory backend; production builds never
substitute simulated system state.

## Architecture and security

The application runs as the desktop user. Read-only inspection uses fixed
system files and absolute commands. State-changing operations invoke only the
installed, root-owned
`/usr/local/lib/s4lockdown-update/scripts/manager-helper.py` through
`/usr/bin/pkexec`. The UI cannot choose an executable, shell fragment, systemd
unit, block device, package directory, certificate, or signing key.

Release downloads run in `s4lockdown-update-manager-check.service` as the
dedicated `s4lockdown-update` user. The root installation stage copies each
verified asset into a new root-owned inode and independently repeats Manifest,
version, EFI image, module, and package verification.

LUKS recovery passwords are collected in an application dialog as mutable
UTF-8 bytes. They are sent only through anonymous standard input to the fixed
Helper's `--password-stdin` mode, transferred to a memfd, and cleared by both
processes. They are never placed in arguments, environment variables, logs, or
files. Password verification disables external LUKS tokens so a working TPM
token cannot make an incorrect recovery password appear valid.

Setup completion is also treated as untrusted input. The native backend
re-reads the running kernel, Secure Boot, Lockdown, official fallback, updater,
disk-backed Swap, LUKS, TPM, and current-process recovery evidence before it
stores completion.

## Installation workflow

| Phase | What the Manager verifies or changes |
| --- | --- |
| System check | Linux `>= 7.0.0`, Secure Boot, Lockdown, LUKS ancestry, disk-backed Swap, and an official Ubuntu fallback |
| Options | Update policy and retention of 1, 2, or 3 historical project kernels |
| Download | Low-privilege Release download, signed Manifest verification, and package checks |
| MOK | Project certificate inspection, pending import, and one-time MokManager password |
| Install | Root-side verification, package installation, GRUB, dracut, logind, Polkit, and updater integration |
| Boot | Live project kernel, Secure Boot, Lockdown, and fallback verification after restart |
| TPM | Existing-token test or PCR 7 enrollment, initramfs validation, token-only unlock, and recovery-password verification |

LUKS is strongly recommended but not an installation blocker. Without LUKS,
the Manager skips TPM unlock setup and retains a security warning because an
offline party can read the hibernation image. Disk-backed Swap large enough for
physical memory remains mandatory. Automatic repair manages only `/swap.img`
on ext4 or XFS and restores the previous file, `/etc/fstab`, and activation
state if replacement fails.

The application never restarts automatically. Restart controls require a
second confirmation and a separate Polkit authorization. Post-restart
checkpoints are navigation hints only; every resumed phase revalidates live
state.

## Development

Install Flutter dependencies and launch the native Linux application from this
directory:

```bash
flutter pub get
./scripts/dev.sh
```

The wrapper removes desktop artifacts left by older development scripts, then
replaces itself with `flutter run -d linux`. It does not install a development
launcher, so an installed Debian package keeps ownership of the production
desktop identity. Stop the development process with `q` or `Ctrl+C`. To remove
older development desktop artifacts without launching Flutter, run:

```bash
./scripts/uninstall-dev-desktop.sh
```

The checked-in JSON files under `assets/i18n/` are the authoritative
translations. The Linux runner and desktop entry live under `linux/`, the Dart
application under `lib/`, and focused tests under `test/`.

## Verification

These checks do not launch the desktop application:

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

From the repository root, the fixed Helper and package contracts can be checked
with:

```bash
python3 tests/manager-helper.py
python3 tests/manager-package.py
python3 tests/update-download.py
```

Native backend tests use an in-memory command runner; they do not execute
`pkexec`, systemd, MOK, TPM, package, GRUB, or restart operations.

## Debian package

Resolve Flutter dependencies once, then build the amd64 package without another
package-network operation:

```bash
flutter pub get
./scripts/build-deb.sh
```

The artifact is written to
`dist/secure-hibernate-manager_<version>_amd64.deb`. Install it through the
desktop authorization prompt:

```bash
pkexec /usr/bin/apt-get install ./dist/secure-hibernate-manager_*.deb
```

The package contains the Flutter release bundle, public project certificates,
fixed backend scripts, and configuration templates. Its `postinst` installs the
root-owned update controller and Helper. Package installation does not enroll a
MOK, modify LUKS or TPM metadata, install a kernel, or restart the machine.

## Releases

Manager Releases are independent from kernel Releases. Update the `version:` in
`pubspec.yaml` and merge that commit into `main`; no manual tag or Release is
required.

After the project checks pass on `main`, the `Check project and release Manager`
workflow invokes the reusable Manager release workflow. It compares the exact
`manager-v<version>` Release with the source version and skips a complete
existing Release. For a new version it builds and tests the amd64 package,
verifies its Debian metadata, creates `SHA256SUMS` and
`manager-release.json`, signs all three files together with GitHub
OIDC/Sigstore provenance, creates the version tag at the workflow commit, and
publishes the Release automatically. Release notes are generated from the
previous published `manager-v*` tag and include GitHub's full changelog link;
kernel tags are never used as the comparison base. The workflow refuses
incomplete Releases, unexpected assets, and existing tags. A direct manual run
is an explicit retry for an unpublished version and cannot replace a completed
Release. Kernel tags use the separate `ubuntu-*` namespace and do not invoke
this workflow.

The application icon is a recolored rendering of the AMP icon from the
CC0-1.0 `gilbarbara/logos` collection, also indexed by SVG Repo as asset
`353393/amp-icon`. Its exact source and upstream object hash are recorded in
`assets/licenses/App-Icon-CC0.txt`. CC0 does not grant trademark rights; this
project is not affiliated with or endorsed by the AMP project.

The destructive end-to-end procedure is documented in
[`../docs/manager-vm-test.md`](../docs/manager-vm-test.md) and must be run only
inside a disposable Secure Boot/vTPM virtual machine.
