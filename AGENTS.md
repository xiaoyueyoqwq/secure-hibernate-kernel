# Project maintenance notes

- A saved GRUB submenu selection uses `submenu_id>kernel_id`, while
  `/boot/grub/grub.cfg` stores those IDs on separate lines. Validate each ID
  separately before passing the combined value to `GRUB_DEFAULT` or
  `grub-reboot`.
- For exact-kernel S4 resume, prefer the dedicated parameterized top-level GRUB
  entry over an Advanced submenu selection. Entering the submenu causes GRUB's
  TPM hook to measure every nested kernel and recovery entry, which can exhaust
  firmware TCG2 event-log capacity.
- `/etc/grub.d` generators that source `grub-mkconfig_lib` must not enable
  nounset; Ubuntu's library intentionally reads variables that may be unset.
- Inspect both `/etc/default/grub` and `/etc/default/grub.d/*.cfg` when
  determining effective GRUB defaults; later fragments can override the base
  timeout and menu style.
- Never upload a machine-specific MOK private key. The dedicated project key
  may exist only as the `PROJECT_MOK_PRIVATE_KEY_B64` secret in the
  `release-signing` GitHub environment. Build and publish jobs must not receive
  that environment or secret.
- After staging a MOK import or deletion, verify the pending EFI variable with
  root-readable `mokutil` through Polkit before rebooting. An unprivileged
  `mokutil --list-delete` can exit successfully with an empty result when
  `MokDel` is mode `0600`; command success alone does not prove the request.
- Do not assume every MOK list change alters PCR 7. After MokManager completes,
  read the live PCR and run an explicit token-only unlock test before deciding
  that TPM enrollment or token cleanup is necessary.
- In `.gitignore`, unignore public signing certificates by exact filename only;
  never use a wildcard exception for key-like extensions such as `*.pem`.
- Follow `docs/project-signing-key-lifecycle.md` for key generation, planned
  rotation, and compromise response. Never overwrite certificate assets in an
  already published tag.
- Do not describe workflow refusal to reuse an existing Release tag as
  platform-level asset immutability. Treat assets as immutable only when the
  GitHub Release API reports `immutable: true`; otherwise rely on exact
  certificate verification and document the remaining mutability accurately.
- Never execute a downloaded or artifact-provided `sign-file` with a private
  key. Both project and independent-MOK signing must use a trusted,
  distribution-owned helper whose package ownership is verified.
- `modinfo` signer and key-ID fields are metadata, not cryptographic module
  signature verification. Keep a negative test that corrupts a signature byte
  and requires package validation to fail.
- An environment branch policy limits eligible refs but does not authorize a
  specific workflow. Require environment approval or protected-branch review
  before allowing a signing job to read the project secret.
- Preserve official Ubuntu kernels, the HWE meta-package, password LUKS
  recovery, and existing TPM tokens during installation and updates.
- On systemd 259, one failed TPM policy message during initrd unlock does not
  prove every enrolled token is stale. Test each token explicitly with
  `cryptsetup open --test-passphrase --token-only --token-id ID` before changing
  metadata. Multiple tokens with the same PCR selection may not provide useful
  fallback ordering; compare metadata before and after `systemd-cryptenroll`
  and require explicit authorization before removing token metadata.
- A LUKS recovery-password test on a volume with external tokens must pass
  `--disable-external-tokens`. Otherwise `cryptsetup open --test-passphrase`
  tries an available TPM token first and can report success for a wrong key
  file. Treat return code 2 as a bad passphrase and keep a regression test that
  proves header backup, enrollment, crypttab, and initramfs mutations do not run.
- TPM error `0x128` means PCR values changed between a policy check and the
  command. It can be transient during early boot; determine the outcome from
  the final cryptsetup result, password-prompt behavior, and a token-only test.
- EFI TCG2 status `EFI_VOLUME_FULL` from `HashLogExtendEvent` means the PCR
  extend occurred but one or more event logs could not record it. It is not EFI
  partition or NVRAM exhaustion. After S4 restore, do not replay live PCRs from
  the restored pre-hibernation event-log copy.
- When passing `systemd-ask-password` output to a key-file option, use `-n` so
  its default trailing newline does not become part of the LUKS passphrase. A
  background root request may need `pkexec systemd-tty-ask-password-agent
  --query` in the user's terminal when no desktop ask-password agent is active.
- Run `bash -n`, ShellCheck, actionlint, `tests/resolve-version.sh`,
  `git diff --check`, systemd unit verification, and package signature checks
  after changing the maintenance chain.
- Keep release-policy and signing-security regression tests wired into the
  GitHub Actions script-check step; a test file that CI never invokes does not
  protect the release chain.
- Keep a secret-free push/pull-request workflow for immediate script and unit
  regression results. The scheduled release workflow skips checks when the
  current ABI Release is already complete.
- GitHub container jobs run as root. Permission-failure tests must use a
  UID-independent invalid target or explicitly drop privileges; mode bits alone
  do not make a directory unwritable to root.
- Generate and CMS-sign `release-manifest.json` only inside the protected
  signing job. The publish job must re-verify it against the repository-pinned
  project certificate and must never regenerate Release metadata.
- `ubuntu-7.0.0-28.28` is the only legacy Release allowed without a signed
  Manifest. Do not add assets to it; every later tag requires both
  `release-manifest.json` and `release-manifest.p7s`.
- Automatic first installation from `ubuntu-7.0.0-28.28` must remain limited to
  the canonical repository and an embedded exact commit, asset-name, size, and
  SHA-256 snapshot. Repeat this verification on both sides of the root copy
  boundary; never generalize the exception to another Manifest-less tag.
- Do not enable `RestrictSUIDSGID` on the unprivileged updater check units:
  `dpkg-deb`/`tar` must restore package mode metadata in their private
  extraction directory, and systemd otherwise returns `ENOSYS` for those calls.
  Keep the check user unprivileged, retain `NoNewPrivileges` and filesystem
  isolation, and never execute extracted files.
- Keep updater downloads in the unprivileged check service. Before root package
  processing, copy every staged asset into a newly created root-owned inode,
  remove the unprivileged source, and repeat both Manifest and package signature
  verification. Changing ownership does not revoke an already open descriptor.
- The root updater stage must independently resolve the current Ubuntu HWE
  candidate and require an exact source-version and Release-tag match. A signed
  Manifest proves authenticity but does not by itself authorize rollout order.
- The updater may prune only superseded project kernels after a verified update,
  according to `PROJECT_KERNEL_HISTORY=1|2|3`. Always preserve the newly
  installed kernel, the running kernel, every official Ubuntu kernel, and the
  HWE meta-package. Never restart automatically; preserve dpkg contention as a
  deferred state and change GRUB only after package installation succeeds.
- Name every root-owned trust-boundary directory explicitly in installer calls;
  automatically created parent directories can inherit a broader default mode.
- The Manager UI may refresh typed read-only snapshots but must never
  submit executable paths, shell fragments, arbitrary systemd units, block
  devices, or package directories. Privileged installation actions require an
  installed root-owned helper with fixed subcommands and structured results.
- Keep the Linux Manager desktop name exactly
  `io.github.xiaoyueyoqwq.secure-hibernate-manager.desktop` and keep the
  installed `.desktop` base filename identical. GNOME Wayland uses this match
  to group the Flutter window and resolve its Dock icon.
- Manager raw diagnostics may preserve output only from fixed, read-only native
  backend preflight sources. Never accept UI-provided commands or include
  private keys, credentials, LUKS passphrases, or TPM key material.
- Manager installation compatibility is based on the parsed running Linux
  kernel version (`>= 7.0.0`), not a hard-coded Ubuntu release name. Keep OS
  release detection informational only.
- Do not expose Manager options that the backend cannot enforce. The current
  updater supports exactly `manual`, `check-and-notify`, and
  `automatic-install`, checks daily when enabled, and retains 1, 2, or 3
  historical project kernels as configured. A running older project kernel may
  temporarily exceed that count. Official Ubuntu kernels are not part of
  project-kernel retention.
- Restrict Manager setup simulations to injected test backends. The production
  Flutter entry point must always use the fixed native backend and must never
  advance through simulated success.
- Treat a Manager setup checkpoint only as a navigation hint. Store only fixed
  checkpoint identifiers, launch the fixed desktop ID on login, and re-read
  live security state before allowing post-reboot progress.
- Gate first-run routing on the persisted setup-state read so completed systems
  never flash the installer. If checkpoint recovery requires Polkit, render the
  checkpoint UI first and start the fixed live inspection after the first frame.
- Do not optimistically commit privileged Manager settings in the UI.
  Update the visible value only from an authoritative backend snapshot after
  Helper success; failure and cancellation retain the previous snapshot.
- A lock shared by the root updater and the download account must live under a
  root-owned parent directory. Giving the low-privilege account ownership of
  the lock inode is acceptable only when it cannot replace that inode.
- Development builds may unlock all existing wizard timeline nodes for visual
  inspection, but that navigation must not fabricate backend success or write
  reboot checkpoints. Production builds must retain ordered progression.
- After a fixed Helper starts a systemd job with `--no-block`, the Manager must
  not treat a pre-action terminal snapshot as the new result. Poll against the
  previous status and timestamp until the job publishes new state or a bounded
  startup timeout expires.
- Treat updater transfer phases as live only while either the fixed Manager
  check unit or scheduled check unit is active. Scope transfer polling and
  progress-button layers to the download wizard step; a stopped unit's last
  percentage must not leak into MOK or other step actions.
- Before downloading a candidate, re-verify and reuse the existing unprivileged
  `cache/staged` Release when it matches the current authorized version. The
  root stage must still copy it across the trust boundary and independently
  repeat all verification.
- Never fall back to executing the repository copy of `manager-helper.py` with
  root privileges. A missing native helper requires refreshing the reviewed,
  root-owned update-controller installation through Polkit.
- Treat UI setup completion as an untrusted request. The native backend must
  re-read the exact installed/running kernel and security prerequisites and
  require current-process recovery evidence before storing completion.
- Never use `mokutil --test-key` output or exit status as project MOK enrollment
  evidence; kernel-keyring failures make its behavior unreliable. Verify the
  installed project DER against its pinned SHA-256 fingerprint, then require
  its exact SHA-1 fingerprint in `mokutil --list-enrolled` before reporting the
  project MOK as enrolled.
- On native Manager startup, request one fixed `inspect-mok` operation after
  the first frame unless another MOK inspection has already started. Share one
  in-flight inspection across startup, wizard recovery, and page actions so
  concurrent paths cannot open duplicate Polkit prompts; render authorization
  wait as checking, while cancellation remains unknown and retryable.
- Generate new MokManager one-time passwords as three lowercase letters plus
  five digits, excluding ambiguous `i/l/o/0/1` characters. Continue accepting
  the legacy 12-character alphanumeric format while an older enrollment request
  may still be pending. Passive inspection must not revoke that request; expose
  an explicit Polkit-authorized regeneration action that replaces it before
  allowing restart.
- Treat the Flutter Manager as the maintained visual and interaction source of
  truth. Preserve its navigation, copy, spacing, colors, radii, icons, states,
  and test-backend behavior unless the user explicitly requests a redesign.
- Keep `manager/` as the sole Flutter application root. Do not reintroduce an
  Electron/Node runtime, a browser compatibility layer, or a migration
  subdirectory such as `manager/flutter_prototype/`.
- Keep Manager and kernel publication independent. `manager-v<pubspec version>`
  Releases may contain only the Manager package, checksum, descriptor, and
  provenance bundle; `ubuntu-*` Releases remain the signed kernel channel.
- Drive Manager publication from a new `pubspec.yaml` version on `main`. Skip an
  existing complete Release, refuse incomplete Releases or reused tags, and
  create the matching tag only after the package, checksum, and descriptor all
  pass one GitHub OIDC/Sigstore attestation. Never give this workflow the MOK
  private key or another long-lived signing secret.
- Do not launch Flutter, builds, screenshots, or visual tests
  for Manager UI work unless the user explicitly asks. The user owns visual
  verification, and no development process should remain running in the
  background.
- For Flutter mode-0600 state, autostart, and diagnostic writes, create the
  temporary file exclusively, restrict it before writing content, clean it on
  every failure, and rename it only after flushing.
- Flutter Widget tests run in separate FakeAsync zones. Cache resolved immutable
  assets such as `TranslationCatalog`, never a Future created by another test.
- Flutter Debian packaging must include the exact public controller resources,
  including `config/s4lockdown-update.conf`, while excluding private keys and
  unrelated desktop-runtime resources. Reject configuration symlinks and
  normalize staged directories, data files, and scripts to explicit package
  modes instead of preserving working-tree permissions.
- Any packaged encrypted-root workflow must declare and verify the actual
  initramfs unlock path, including the executable or generator required by the
  selected dracut/initramfs implementation. Dracut's systemd path can unlock
  through `systemd-cryptsetup` without installing the `cryptsetup` CLI in the
  image; require a generated unit and an actual unlock result instead of
  inferring success or failure from either executable's presence alone.
- Dracut's `73tpm2-tss` module is skipped when `/usr/bin/tpm2` is absent; TPM
  packages must provide `tpm2-tools`, `tpm-udev`, and the device TCTI runtime,
  and initramfs validation must require the TPM token plugin, device TCTI
  library, and `60-tpm-udev.rules`. A built-in `tpm_crb` driver is expected to
  have no `.ko` file and must not be reported as missing for that reason.
- Keep Flutter Debian builds independent of package-network availability after
  an explicit `flutter pub get`: require the lockfile and resolved package
  configuration, then invoke `flutter build` with `--no-pub`.
- Transfer local artifacts to `secure-hibernate-lab` with a temporary Python
  HTTP server bound only to the libvirt host bridge (`192.168.122.1`), never to
  `0.0.0.0`. Verify the artifact SHA-256 inside the guest and stop the foreground
  server with `Ctrl+C` immediately after transfer.
- Do not infer a VM virtual-NIC failure from a stale firmware/Plymouth frame or
  an ignored cooperative ACPI shutdown request. Check the libvirt DHCP lease,
  interface counters/errors, ICMP response, QEMU run state, and changing CPU,
  block, and balloon statistics before assigning the failure to networking or
  to the graphical path.
- The `secure-hibernate-lab` clean checkpoint is an external baseline, so it is
  absent from virt-manager's snapshot list. Restore only while powered off and
  restore the disk overlay, OVMF NVRAM, swtpm state, and inactive XML together.
  Move the previous active state to a timestamped recovery directory until the
  restored guest has booted successfully.
- During an active Manager VM acceptance cycle, a completed source fix defaults
  to advancing the Flutter package version, building and auditing the Debian
  package, and verifying its bridge-only HTTP URL. Skip that delivery step only
  when the user explicitly requests no build.
- Widgets shown through a Flutter `Navigator` overlay must not read page-local
  `ManagerScope` state from the dialog context. Capture required translations
  and callbacks before opening the route, and keep a Widget test that renders
  and dismisses the real dialog route.
- Manager preflight help belongs immediately after each check label, never next
  to the trailing status. Every help message must state both why the check
  matters and how the user can resolve or consciously accept the condition.
- Treat missing LUKS as a persistent security recommendation, not an install
  blocker. Skip TPM/recovery steps when LUKS is absent, but keep disk-backed
  Swap capacity mandatory. Automatic Swap repair may manage only `/swap.img`,
  must preserve every other Swap source, and must restore the previous file,
  `fstab`, and activation state on failure.
- Long-running privileged installation work must publish fixed milestones to a
  root-owned state file and expose them through a lightweight read-only Manager
  API. Do not poll the full hardware snapshot during package operations or run
  the same complete signature verification twice on unchanged root-owned
  Release inodes.
- Persist updater check failures with a fixed `failed_phase` value and render
  the error on that exact download-and-verification row. Keep completed prior
  rows successful, later rows pending, expose the bounded backend error, and
  use the first Release row only for legacy state files without a phase.
- Treat updater JSON and systemd liveness as one consistency boundary. A
  terminal state written by the check service must take precedence over a
  stale running phase; never classify `running phase + inactive service` as a
  real verification failure without a fresh terminal state or bounded liveness
  timeout.
- The installed project GRUB fragment must select the top-level Ubuntu entry
  and enforce `GRUB_TIMEOUT_STYLE=hidden`, `GRUB_TIMEOUT=0`, and
  `GRUB_RECORDFAIL_TIMEOUT=0`. Advanced Options remains available through the
  GRUB reveal key, but normal boots must not stop at the menu.
- When restoring `secure-hibernate-lab`, copy the baseline `swtpm/tpm2` tree
  into `/var/lib/libvirt/swtpm/<domain-uuid>/tpm2` and set it to
  `swtpm:swtpm` with directory mode `0700` and state-file mode `0600` before
  starting the domain. Hash equality of the external baseline alone does not
  verify that libvirt can access the vTPM state.
- A filled Wizard action button is already the active progress indicator. While
  download or installation progress is visible, show only the fill and numeric
  percentage; do not overlay a spinner or phase label. Keep phase details in
  the status rows below the action.
- Keep the installation page's existing component rows when visualizing live
  work. Reuse the download page's success/loading/pending behavior on those
  rows; do not replace them with backend phase rows or expose individual
  kernel-module and package-internal iteration details.
- When converting the lab VM root filesystem to LUKS offline, use a private
  mount namespace and an isolated tmpfs for the guest chroot `/run`; never
  recursively bind the host `/run` below that chroot. Keep an independent
  unencrypted `/boot`, and retain the test passphrase, LUKS header backup, and
  partition-table backup until password boot, mount layout, and later TPM
  enrollment/reboot acceptance have all passed.
- Treat updater check-state metadata as a report, not proof that staged Release
  files still exist. A Manager installation with no staged or root-owned
  Release must recover it through the fixed unprivileged check service, merge
  that download and verification into the installation progress, and then
  continue installation without another authorization request. Do not display
  retained installation progress until `install_updated_at` changes for the
  current Polkit-authorized action.
- After starting the fixed updater service with `systemctl --no-block`, do not
  treat a single inactive observation as terminal, even after a new `indexing`
  state appears. systemd can briefly report inactive while the job is queued;
  require a bounded sequence of consecutive inactive polls or an explicit
  terminal check state before failing recovery.
- For offline guest maintenance, never recursively bind the host `/run` into a
  chroot whose path is itself below `/run`; use a private tmpfs for the guest
  `/run` and make all bind mounts private before entering the chroot. Shared
  recursive mounts can propagate into long-lived service namespaces and keep
  guest block devices busy after the maintenance process exits.
- During in-place LUKS conversion, keep the sole recovery passphrase in a
  separate mode-0600 host file until offline validation and one successful
  guest boot both complete. A generic failure cleanup must never destroy the
  only keyslot credential before the converted guest is accepted.
- A graphical Manager must not wait on `systemd-ask-password --no-tty` unless
  it also provides a visible desktop agent. Collect LUKS recovery passwords in
  the application, pass mutable UTF-8 bytes only through anonymous stdin to a
  fixed Polkit-authorized Helper mode, never argv/environment/logs/files, and
  clear both caller and Helper buffers in `finally`. Cancellation must start no
  privileged action, and every exit path must clear the visible busy state.
- Keep TPM inspection and TPM enrollment as separate explicit Manager actions.
  Entering the wizard step must not open Polkit automatically; `verify-tpm`
  must never request or receive a LUKS password, and only a confirmed missing or
  unusable token may change the next action to password-backed TPM enrollment.
- Any Manager change to `/etc/crypttab` must rebuild the encrypted-root
  initramfs with the fixed crypt/dm/systemd-cryptsetup modules and exact root
  and LUKS UUIDs, verify the candidate with `lsinitrd`, and atomically replace
  the installed image only after validation. Preserve the previous image and
  restore `crypttab` on every failed rebuild.
- The disposable `secure-hibernate-lab` LUKS baseline uses the fixed test-only
  passphrase `12345678` so repeated manual acceptance runs remain practical.
  Never reuse this weak credential on a real machine, production image, or any
  VM containing data that must remain confidential.
- A full `secure-hibernate-lab` reset must combine shutdown, complete baseline
  restoration, LUKS conversion, offline cleanliness checks, and final start in
  one reviewed Polkit transaction. Before authorization, inspect stale mount
  references as an unprivileged user; after all live mountinfo references are
  gone, do not block the independent active overlay on a deferred mapping that
  points to an already-unlinked discarded inode. The reset conversion uses a
  separate NBD device and must verify its own active path.
- When animating a Manager control from transparent to a visible color, keep
  the target RGB values in the transparent endpoint and animate only alpha.
  `Colors.transparent` is transparent black and produces a dark intermediate
  flash when interpolated toward a light hover background.
- Keep the Manager software check automatic. Show no persistent recheck action
  when the installed version is current; show a trusted Release update action
  only for a newer `manager-v*` Release, and include that state in the overview
  attention summary.
- Icon-only destructive Manager actions must reveal an explicit confirmation
  label before execution. Keep the icon and label in one control and animate
  the control width so the confirmation state is understandable without
  relying on an undocumented second-click convention.
