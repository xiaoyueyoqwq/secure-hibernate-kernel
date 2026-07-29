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
- Generate and CMS-sign `release-manifest.json` only inside the protected
  signing job. The publish job must re-verify it against the repository-pinned
  project certificate and must never regenerate Release metadata.
- `ubuntu-7.0.0-28.28` is the only legacy Release allowed without a signed
  Manifest. Do not add assets to it; every later tag requires both
  `release-manifest.json` and `release-manifest.p7s`.
- Keep updater downloads in the unprivileged check service. Before root package
  processing, copy every staged asset into a newly created root-owned inode,
  remove the unprivileged source, and repeat both Manifest and package signature
  verification. Changing ownership does not revoke an already open descriptor.
- The root updater stage must independently resolve the current Ubuntu HWE
  candidate and require an exact source-version and Release-tag match. A signed
  Manifest proves authenticity but does not by itself authorize rollout order.
- The updater must never prune kernels or restart automatically. Preserve dpkg
  contention as a deferred state, record installation atomically, and change
  GRUB only through the verified package installer after dpkg succeeds.
- Name every root-owned trust-boundary directory explicitly in installer calls;
  automatically created parent directories can inherit a broader default mode.
