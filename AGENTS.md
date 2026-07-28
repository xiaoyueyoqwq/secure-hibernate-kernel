# Project maintenance notes

- A saved GRUB submenu selection uses `submenu_id>kernel_id`, while
  `/boot/grub/grub.cfg` stores those IDs on separate lines. Validate each ID
  separately before passing the combined value to `GRUB_DEFAULT` or
  `grub-reboot`.
- Never upload a machine-specific MOK private key. The dedicated project key
  may exist only as the `PROJECT_MOK_PRIVATE_KEY_B64` secret in the
  `release-signing` GitHub environment. Build and publish jobs must not receive
  that environment or secret.
- In `.gitignore`, unignore public signing certificates by exact filename only;
  never use a wildcard exception for key-like extensions such as `*.pem`.
- Follow `docs/project-signing-key-lifecycle.md` for key generation, planned
  rotation, and compromise response. Never overwrite certificate assets in an
  already published tag.
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
- Run `bash -n`, ShellCheck, actionlint, `tests/resolve-version.sh`,
  `git diff --check`, systemd unit verification, and package signature checks
  after changing the maintenance chain.
- Keep release-policy and signing-security regression tests wired into the
  GitHub Actions script-check step; a test file that CI never invokes does not
  protect the release chain.
