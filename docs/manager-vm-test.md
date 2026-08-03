# Manager virtual-machine acceptance test

Use disposable UEFI virtual machines with Secure Boot, a virtual TPM 2.0, and
at least one official Ubuntu kernel. Keep a clean snapshot before starting.
The existing unencrypted VM is the negative baseline for LUKS warnings and
Swap repair. A separate LUKS2-root VM with encrypted disk-backed Swap is needed
for the complete TPM and hibernation chain.

`secure-hibernate-lab` uses a complete external baseline under
`/var/lib/libvirt/images/secure-hibernate-lab-clean-base`, not a libvirt
snapshot. An empty virt-manager snapshot list is therefore expected. The
baseline keeps the read-only disk, OVMF NVRAM, swtpm state, inactive domain XML,
and checksums from one powered-off checkpoint.

The disposable LUKS2 conversion of this lab uses the fixed recovery passphrase
`12345678`. This credential is intentionally memorable for repeated acceptance
tests and must never be reused outside the disposable lab VM.

These tests change EFI variables, LUKS metadata, installed kernels, GRUB, and
systemd state inside the VM. Each restart remains a deliberate user action.

## Package and baseline

1. Build `manager/dist/secure-hibernate-manager_*.deb` with
   `./scripts/build-deb.sh` from `manager/` on the development machine and
   record its SHA-256.
2. From the Manager `dist/` directory, run
   `python3 -m http.server 8080 --bind 192.168.122.1`. This address is the host
   side of the isolated default libvirt network; never bind this temporary
   transfer server to `0.0.0.0`.
3. Open `http://192.168.122.1:8080/` inside the VM, download only the Debian
   package, verify its SHA-256 against the host value, then stop the foreground
   server with `Ctrl+C`.
4. Install it with
   `pkexec /usr/bin/apt-get install ./secure-hibernate-manager_*.deb`.
5. Confirm the desktop entry, Dock icon, custom title bar, language selection,
   light/dark theme, and fractional scaling.
6. Confirm `s4lockdown-update.timer` is installed and that
   `/usr/local/lib/s4lockdown-update/scripts/manager-helper.py` is root-owned,
   non-writable by other users, and executable.

## Preflight and download

1. Confirm the system page reports the running Linux version, Secure Boot,
   Lockdown, LUKS ancestry, hibernation capacity, and official fallback from
   live state. Confirm every row has an inline help control that explains both
   why the check matters and how to resolve a failure.
2. On the unencrypted baseline, confirm LUKS is an orange recommendation rather
   than a blocker, TPM setup is not applicable, setup can finish, and Overview
   continues to show `Security enhancement recommended`. Do not treat this
   state as protection for the hibernation image against offline inspection.
3. With insufficient Swap, select the one-click repair and authorize it once.
   Confirm `/swap.img` is at least `MemTotal`, is active, and has exactly one
   matching `/etc/fstab` entry. Confirm swap partitions, zram, and swap files at
   other paths are unchanged. Automatic repair supports only ext4 and XFS.
4. Start a Release check and confirm the sequence `indexing`, `downloading`,
   `verifying-manifest`, `verifying-packages`, then `verified` or `current`.
5. Pause during a large asset, close and reopen the application, then resume.
   Confirm the percentage continues from the retained `.part` file.
6. Interrupt networking once. Confirm the current kernel and GRUB default do
   not change and a later resume uses an HTTP Range request.

## MOK and restart checkpoint

1. Check the project MOK state. A fresh VM must report `missing`, not `unknown`.
2. Prepare enrollment and record the displayed one-time password.
3. Close and reopen the Manager. Confirm the pending state and same password
   are recovered without creating another request.
4. Use the two-click restart control. Enroll the certificate in MokManager.
5. After login, confirm the Manager opens automatically at the MOK checkpoint,
   detects the enrolled certificate, deletes the one-time password state, and
   continues only after live verification.

## Kernel installation and boot

1. Install the verified candidate. Confirm package signatures are rechecked in
   the root stage and the application remains on the install step on failure.
2. Confirm the project image and matching headers are installed, the exact S4
   GRUB generator exists, and the update controller remains installed.
3. Confirm the official Ubuntu kernel and HWE meta-package remain installed.
4. Cancel the first restart authorization. Confirm the checkpoint remains and
   no restart occurs. Retry and boot the project kernel.
5. Confirm live Secure Boot, Lockdown, running-project-kernel, and official
   fallback checks all pass before the TPM step is enabled.

## TPM and recovery

Run this section only on the LUKS2-root baseline. The unencrypted baseline must
show these operations as not applicable.

1. Record the LUKS UUID, keyslots, and tokens before enrollment.
2. Start TPM setup. Confirm the LUKS password is sent only through anonymous
   standard input to the fixed privileged Helper and is absent from process
   arguments, environment variables, logs, and files.
3. Confirm a UUID-matching mode-0600 header backup appears under
   `/var/lib/s4lockdown-update/luks-header-backups/`.
4. Confirm existing tokens are preserved. If a working token already exists,
   confirm no duplicate token is added.
5. Confirm token-only unlock and password recovery both pass before setup is
   marked complete.
6. Restart once and verify TPM automatic unlock. Then perform a separate
   password-recovery test while retaining the VM snapshot.

## Maintenance actions

1. Change all three update policies and confirm timer enablement matches the
   selected policy.
2. Select each 1/2/3 historical project-kernel limit and install enough verified
   updates to cross it. Confirm only superseded project kernels outside the
   selected history are removed.
3. Confirm removal is refused for the running kernel, the last project kernel,
   or a system without an official image fallback.
4. Confirm no action prunes an official kernel, removes the HWE meta-package,
   removes a LUKS password slot, deletes an existing TPM token, or restarts
   automatically.

Restore the clean external baseline before repeating the full sequence. Keep
the VM powered off and restore its disk overlay, OVMF NVRAM, swtpm state, and
inactive domain definition together. Preserve the previous active state in a
timestamped recovery directory until the restored VM has booted successfully;
restoring only the disk produces an invalid Secure Boot/TPM test checkpoint.
