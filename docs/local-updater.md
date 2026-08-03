# Local Update Controller

## Execution model

The updater has two systemd stages and one daily timer:

- `s4lockdown-update-check.service` runs as the dedicated, non-login
  `s4lockdown-update` user. It resolves the current Ubuntu HWE source version,
  downloads the matching GitHub Release into a temporary cache directory,
  verifies the signed Manifest or the single pinned legacy Release snapshot,
  and performs package-level EFI, module, and headers validation.
- `s4lockdown-update.service` runs as root after a successful check. It resolves
  the current HWE candidate independently, copies every staged asset into a new
  root-owned file, removes the download-user copy, and repeats the complete
  metadata, hash, and package validation. It accepts only an exact
  source-version and Release-tag match before following the configured
  installation policy.
- `s4lockdown-update.timer` starts the sequence daily with a randomized delay
  and catches up after missed calendar runs. The root stage runs only on AC
  power.

Both stages take the same non-blocking `flock` lock. They never execute a file
from the downloaded Release, never receive a private key, and never run from a
user-writable repository checkout after installation.

The unprivileged check units intentionally do not set
`RestrictSUIDSGID=yes`. `dpkg-deb` invokes `tar` while validating the signed
image, and systemd's SUID/SGID seccomp restriction makes tar's mode-restoration
calls fail with `ENOSYS` (`Function not implemented`) even inside the private
temporary directory. The check account has no privilege escalation path and
the extracted files are never executed; `NoNewPrivileges`, `PrivateTmp`, and
the other filesystem restrictions remain enabled.

## Policies

`/etc/s4lockdown-update.conf` accepts the update policy and project-kernel
history limit:

```text
POLICY=check-and-notify
PROJECT_KERNEL_HISTORY=2
```

Supported values are:

- `manual`: scheduled activation records the check time without using the
  network. A GUI or administrator can request a forced check explicitly.
- `check-and-notify`: the default. A verified update is retained under
  `/var/lib/s4lockdown-update/available`, recorded in `state.json`, and
  announced without installing it. The Manager can install it after explicit
  authorization.
- `automatic-install`: a verified update is installed when dpkg is idle. A busy
  package manager defers the update without treating it as a package failure.

`PROJECT_KERNEL_HISTORY` controls how many older project kernels remain after a
successful update. Valid values are `1`, `2`, and `3`; the default is `2`.
Cleanup never removes the newly installed kernel, the running kernel, an
official Ubuntu kernel, or the Ubuntu HWE meta-package. The running kernel can
temporarily make the retained count exceed the selected history until a later
update runs after reboot.

No policy restarts, powers off, hibernates, enrolls a MOK, or changes TPM/LUKS
metadata. Successful installation creates the conventional
`/run/reboot-required` marker, updates the top-level Ubuntu GRUB entry only
after package validation and installation succeed, and sends a wall
notification. The running kernel remains active until the user chooses to
restart.

## Installation

Install the root-owned controller, dedicated system user, configuration, units,
and enabled timer from a trusted checkout:

```bash
pkexec "$(realpath scripts/install-update-controller.sh)"
```

The installer refuses a conflicting non-system account, checks all runtime
dependencies, takes the updater lock, verifies the installed Python and systemd
files, and preserves an existing `/etc/s4lockdown-update.conf`.

It also deploys the fixed Manager helper, the project DER certificate, and the
existing system-integration templates. GUI-requested checks run through
`s4lockdown-update-manager-check.service` as `s4lockdown-update` with `--force`,
so the manual policy can still perform an explicit user-requested check. Only
`check-state.json` is mode 0644; staged and partial package directories remain
mode 0700 and are reverified after crossing into the root stage.

The helper accepts fixed action names only. It can control that check service,
install a verified candidate, apply system integration, manage the project MOK
request, set an implemented policy, verify or enroll TPM recovery, and remove
one validated non-running project kernel. It does not accept a command,
executable path, systemd unit, block device, or package directory from the
desktop application.

Inspect the timer and structured state with:

```bash
systemctl list-timers s4lockdown-update.timer
pkexec /usr/local/lib/s4lockdown-update/scripts/update-local.sh status
```

Run an immediate ordinary check through the same systemd dependency chain:

```bash
pkexec /usr/bin/systemctl start s4lockdown-update.service
```

Under the default policy, explicitly install an already verified candidate
without changing the persistent policy:

```bash
pkexec /usr/local/lib/s4lockdown-update/scripts/update-local.sh install --force
```

The Manager is the preferred way to change both policy and retained history.
For a manual configuration change, write the complete file so one setting does
not erase the other, then start the service:

```bash
printf '%s\n' 'POLICY=automatic-install' 'PROJECT_KERNEL_HISTORY=2' \
  | pkexec /usr/bin/tee /etc/s4lockdown-update.conf >/dev/null
pkexec /usr/bin/systemctl start s4lockdown-update.service
```

## State and recovery

The download user writes only under `/var/cache/s4lockdown-update`. Root copies a
verified candidate into newly created files under `/var/lib/s4lockdown-update`
before re-verification and installation. This prevents an already open download
file descriptor from modifying the root-owned candidate. JSON files are written
through a temporary file, `fsync`, and atomic rename.

The shared `update.lock` lives in the root-owned state directory. Its inode is
writable by the download account, but that account cannot replace the path;
both updater stages open it with `O_NOFOLLOW` and require a regular file.

Both stages remove recognized stale incoming and retired directories while
holding the shared lock. Interrupted downloads, verification, shutdowns, and
power loss therefore do not accumulate abandoned Release-sized directories.

`state.json` records the installed Ubuntu source version, kernel release,
Release tag, Git commit, previous running kernel, reboot state, available
candidate, timestamps, and the last outcome. This prevents repeated processing
of an installed version and gives the Manager a stable status contract. A
successfully installed candidate is removed from the package cache; a failed
candidate remains root-owned for diagnosis and retry.

The stored `reboot_required` value records that installation produced a new
kernel. The Manager reports a live restart requirement only while the running
kernel differs from that recorded target. This keeps the immutable installation
record useful while allowing later update checks to appear after a successful
boot.

If a Release is absent or has not yet published both signed Manifest files, the
check exits successfully with `release-unavailable`; the current kernel and GRUB
configuration remain unchanged. The sole exception is the original
`ubuntu-7.0.0-28.28` Release used for first installation. Because it predates
the Manifest, the controller accepts it only from the canonical project
repository and requires an exact embedded Git commit, asset-name set, size, and
SHA-256 match. The download and root stages repeat those checks and package
signature validation independently. The Release-hosted `SHA256SUMS` file is
itself pinned and is not treated as an independent trust anchor.

Signature, hash, package, or state failures exit unsuccessfully before
installation. An install failure retains the root-owned candidate for diagnosis
and leaves GRUB unchanged unless dpkg itself completed and the final GRUB
validation succeeded.

If Ubuntu package metadata changes between the two stages, the root stage
rejects the stale candidate. The next scheduled or manual run resolves and
downloads the new exact version.

After a verified installation, the updater removes only superseded project
kernels beyond `PROJECT_KERNEL_HISTORY`. It always preserves the new target,
the currently running kernel, every official Ubuntu kernel, and the HWE
meta-package. If the running kernel is an older project release outside the
selected history, it remains installed until a later successful update runs
after the machine has booted another kernel.
