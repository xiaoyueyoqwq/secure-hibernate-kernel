# Ubuntu Secure Boot hibernation kernel

This project builds a narrowly patched Ubuntu kernel that permits traditional
hibernation while kernel integrity lockdown is active. It keeps the signing
key off GitHub: Actions produces unsigned Debian packages, then
`scripts/sign-packages.sh` signs the kernel image and modules on the target
machine with a locally held MOK key.

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

## Build in GitHub Actions

Run the `Build Ubuntu hibernation kernel` workflow and specify the exact
Ubuntu source package version. The default currently targets
`7.0.0-28.28` from Ubuntu Resolute and generates a kernel release ending in
`-s4lockdown`.

The workflow downloads the matching `linux-source` and generic kernel config
from Ubuntu, applies the patch, builds Debian packages, and publishes them as a
14-day Actions artifact. The artifact contains the image, modules, headers,
local signing helper, and checksums; it excludes the optional multi-gigabyte
kernel debug-symbol package. The full Linux source tree is not committed here.

With GitHub CLI, a completed artifact can be downloaded with:

```bash
gh run download RUN_ID --dir artifacts
```

## Sign locally

Install the local tooling once:

```bash
sudo apt install sbsigntool zstd xz-utils openssl
```

Then sign an extracted Actions artifact. Keep the private key outside this
repository and restrict it to mode `0600`:

```bash
scripts/sign-packages.sh \
  artifacts/ubuntu-hibernation-kernel-7.0.0-28.28 \
  /path/to/MOK.priv /path/to/MOK.pem
```

The script signs every kernel module, signs the EFI-stub kernel image, and
rebuilds the image package. Header packages are copied unchanged. It does not
install packages, enroll a MOK, edit GRUB, alter initramfs, or change TPM/LUKS
configuration.

## Updating

Normal Ubuntu updates remain enabled, including official kernel packages. A
new custom kernel must be rebuilt when adopting a newer Ubuntu kernel security
update: dispatch the workflow with the new exact source package version, sign
the artifact locally, and install it after validation. Always retain at least
one official Ubuntu kernel as a recovery boot option.

## License

GPL-2.0-only. The Linux kernel source downloaded during the build is governed
by its own copyright notices and license files.
