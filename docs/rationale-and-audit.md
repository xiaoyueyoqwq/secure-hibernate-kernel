# Rationale, measurements, and audit boundary

## Problem statement

Some modern systems expose only suspend-to-idle and omit ACPI S3. When their
platform firmware or devices fail to reach S0ix, suspend-to-idle can consume
several watts even though the machine appears asleep. Traditional hibernation
is then the only kernel-supported low-power state between an ordinary shutdown
and a defective suspend-to-idle implementation.

Linux already contains the complete suspend-to-disk and resume implementation.
The relevant Ubuntu kernels also build it with `CONFIG_HIBERNATION=y`. Integrity
lockdown rejects that existing path at runtime through
`security_locked_down(LOCKDOWN_HIBERNATION)`.

This project adds a default-off `CONFIG_HIBERNATION_ALLOW_LOCKDOWN` policy
option. When explicitly enabled at build time, it permits the existing
hibernation path while lockdown remains active. It does not implement a new
sleep state, emulate ACPI S3, or disable Secure Boot.

## Reference-system evidence

The reference system is a Dell Inspiron 13 5310 running Ubuntu 26.04, Dell BIOS
2.42.0, and Secure Boot integrity lockdown.

- Firmware exposes only `[s2idle]` in `/sys/power/mem_sleep`; ACPI S3 is not
  available to the operating system.
- A controlled 70 minute 54 second suspend-to-idle interval accumulated no
  SLP_S0, S0i2, or S0i3 residency. Battery use was approximately 2.97 Wh, or
  2.5 W average.
- An older Ubuntu kernel reproduced the failed S0ix entry with the current
  firmware, so the result was not specific to one tested Ubuntu ABI.
- The signed patched kernel completed two suspend-to-disk and resume cycles
  under Secure Boot integrity lockdown.
- The longer S4 interval lasted 9 hours 33 minutes 31 seconds. Reported battery
  charge changed from 25% to 24%, bounding image creation, powered-off time,
  and early resume to about 0.33 Wh or 34 mW average. Actual powered-off S4
  residency consumption is lower than that coarse upper bound.
- Resume restored the same boot ID, consumed the EFI `HibernateLocation`, and
  produced the expected ACPI S4/NVS save and restore sequence without storage,
  filesystem, or power-management callback failures.
- After persistent deployment, a physical lid close invoked the required
  same-kernel GRUB helper, entered ACPI S4, resumed without a LUKS password
  prompt, consumed `HibernateLocation`, and restored the original boot ID.
  This verified the complete lid, TPM, boot-loader, initramfs, and kernel path.

These measurements demonstrate the operational value on one affected system;
they are not universal power guarantees.

## Security statement

The resulting system retains Secure Boot, signed kernel and module loading,
and integrity lockdown for ordinary operation. It explicitly removes the
lockdown prohibition on an unauthenticated hibernation image.

The reference configuration stores its swap file inside a LUKS-encrypted root
volume. This protects the powered-off image from an offline party that cannot
unlock the volume. It does not authenticate the image against an attacker with
privileged write access while the encrypted volume is open. Such an attacker
could modify a future image and obtain arbitrary kernel state after resume.

Audit reports should therefore state all of the following:

- Secure Boot remains enabled.
- Kernel and module signature enforcement remains enabled.
- Integrity lockdown remains active.
- Unauthenticated suspend-to-disk and resume are explicitly permitted.
- The hibernation-image integrity guarantee is outside the selected threat
  model.

The shared project MOK is an additional supply-chain trust anchor. Every system
that enrolls it accepts kernels signed by the project key. The key is scoped to
an isolated GitHub Actions signing environment, while build and release-upload
jobs run without it. This separation limits accidental exposure but does not
eliminate the impact of a signing-key or signing-workflow compromise.

## Upstream positioning

An upstream proposal should present this as an expert policy choice, not as
authenticated hibernation. The option should remain default-off, document the
lost guarantee, leave all existing configurations unchanged, and emit a clear
warning when hibernation proceeds under lockdown. Restricting it with
`depends on EXPERT` would make the opt-in nature clearer.

Linux power-management and security maintainers are the appropriate first
reviewers. Ubuntu adoption should follow upstream discussion. Even if the
option is accepted upstream, a distribution may reasonably leave it disabled
in its generic kernel; a separate opt-in kernel flavor would preserve a more
accurate security contract than enabling it for every Secure Boot system.
