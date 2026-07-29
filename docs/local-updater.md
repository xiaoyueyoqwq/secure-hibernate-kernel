# Local Update Controller

## Execution model

The updater has two systemd stages and one daily timer:

- `s4lockdown-update-check.service` runs as the dedicated, non-login
  `s4lockdown-update` user. It resolves the current Ubuntu HWE source version,
  downloads the matching GitHub Release into a temporary cache directory,
  verifies the signed Manifest, and performs package-level EFI, module, and
  headers validation.
- `s4lockdown-update.service` runs as root after a successful check. It resolves
  the current HWE candidate independently, copies every staged asset into a new
  root-owned file, removes the download-user copy, and repeats the complete
  Manifest and package validation. It accepts only an exact source-version and
  Release-tag match before following the configured installation policy.
- `s4lockdown-update.timer` starts the sequence daily with a randomized delay
  and catches up after missed calendar runs. The root stage runs only on AC
  power.

Both stages take the same non-blocking `flock` lock. They never execute a file
from the downloaded Release, never receive a private key, and never run from a
user-writable repository checkout after installation.

## Policies

`/etc/s4lockdown-update.conf` accepts exactly one setting:

```text
POLICY=check-and-notify
```

Supported values are:

- `manual`: scheduled activation records the check time without using the
  network. A GUI or administrator can request a forced check explicitly.
- `check-and-notify`: the default. A verified update is retained under
  `/var/lib/s4lockdown-update/available`, recorded in `state.json`, and
  announced without installing it.
- `automatic-install`: a verified update is installed when dpkg is idle. A busy
  package manager defers the update without treating it as a package failure.

No policy restarts, powers off, hibernates, enrolls a MOK, changes TPM/LUKS
metadata, or removes a kernel. Successful installation creates the conventional
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

To select automatic installation, write the complete fixed configuration value
through Polkit and start the service:

```bash
printf '%s\n' 'POLICY=automatic-install' \
  | pkexec /usr/bin/tee /etc/s4lockdown-update.conf >/dev/null
pkexec /usr/bin/systemctl start s4lockdown-update.service
```

## State and recovery

The download user writes only under `/var/cache/s4lockdown-update`. Root copies a
verified candidate into newly created files under `/var/lib/s4lockdown-update`
before re-verification and installation. This prevents an already open download
file descriptor from modifying the root-owned candidate. JSON files are written
through a temporary file, `fsync`, and atomic rename.

Both stages remove recognized stale incoming and retired directories while
holding the shared lock. Interrupted downloads, verification, shutdowns, and
power loss therefore do not accumulate abandoned Release-sized directories.

`state.json` records the installed Ubuntu source version, kernel release,
Release tag, Git commit, previous running kernel, reboot state, available
candidate, timestamps, and the last outcome. This prevents repeated processing
of an installed version and gives the future GUI a stable status contract. A
successfully installed candidate is removed from the package cache; a failed
candidate remains root-owned for diagnosis and retry.

If a Release is absent or has not yet published both signed Manifest files, the
check exits successfully with `release-unavailable`; the current kernel and GRUB
configuration remain unchanged. Signature, hash, package, or state failures
exit unsuccessfully before installation. An install failure retains the
root-owned candidate for diagnosis and leaves GRUB unchanged unless dpkg itself
completed and the final GRUB validation succeeded.

If Ubuntu package metadata changes between the two stages, the root stage
rejects the stale candidate. The next scheduled or manual run resolves and
downloads the new exact version.

The updater deliberately performs no pruning. The running custom kernel, every
previous custom kernel, all official Ubuntu kernels, and the HWE meta-package
remain managed independently. Kernel cleanup requires a later boot-success
policy and is outside this controller version.
