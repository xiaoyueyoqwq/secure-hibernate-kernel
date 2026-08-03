#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'Usage: set-default-kernel.sh [--check-only] KERNEL_RELEASE\n'
}

check_only=false
if [[ ${1:-} == --check-only ]]; then
	check_only=true
	shift
fi
if [[ $# -ne 1 ]]; then
	usage >&2
	exit 2
fi
if (( EUID != 0 )); then
	printf 'This script must run as root.\n' >&2
	exit 1
fi

kernel_release=$1
if [[ $kernel_release != *-s4lockdown ]]; then
	printf 'Refusing a kernel without the -s4lockdown suffix: %s\n' "$kernel_release" >&2
	exit 2
fi
if [[ ! -f /boot/vmlinuz-$kernel_release || ! -f /boot/initrd.img-$kernel_release ]]; then
	printf 'Kernel or initramfs is missing for %s.\n' "$kernel_release" >&2
	exit 1
fi

root_uuid=$(findmnt -n -o UUID /)
simple_id="gnulinux-simple-${root_uuid}"
submenu_id="gnulinux-advanced-${root_uuid}"
kernel_id="gnulinux-${kernel_release}-advanced-${root_uuid}"
if ! grep -Fq "'$submenu_id'" /boot/grub/grub.cfg ||
	! grep -Fq "'$kernel_id'" /boot/grub/grub.cfg; then
	printf 'GRUB does not contain the expected submenu and kernel IDs: %s\n' \
		"$submenu_id>$kernel_id" >&2
	exit 1
fi
if ! awk -v id="'$simple_id'" -v image="/vmlinuz-$kernel_release" '
	index($0, id) { in_entry = 1 }
	in_entry && index($0, image) { found = 1 }
	in_entry && /^}/ { exit(found ? 0 : 1) }
	END { if (!in_entry || !found) exit 1 }
' /boot/grub/grub.cfg; then
	printf 'The top-level Ubuntu entry does not load %s.\n' "$kernel_release" >&2
	exit 1
fi
if $check_only; then
	printf 'Validated top-level Ubuntu and exact kernel entries for %s\n' \
		"$kernel_release"
	exit 0
fi

temp_file=$(mktemp)
trap 'rm -f -- "$temp_file"' EXIT
{
	printf '# Boot the top-level Ubuntu entry and keep the normal path menu-free.\n'
	printf 'GRUB_DEFAULT="%s"\n' "$simple_id"
	printf 'GRUB_TIMEOUT_STYLE=hidden\n'
	printf 'GRUB_TIMEOUT=0\n'
	printf 'GRUB_RECORDFAIL_TIMEOUT=0\n'
} > "$temp_file"

install -o root -g root -m 0644 "$temp_file" /etc/default/grub.d/99-s4lockdown.cfg
if [[ -e /etc/default/grub.d/99-s4lockdown-test.cfg ]]; then
	backup="/etc/default/grub.d/99-s4lockdown-test.cfg.disabled.$(date +%s)"
	mv /etc/default/grub.d/99-s4lockdown-test.cfg "$backup"
	printf 'Preserved previous GRUB test configuration as %s\n' "$backup"
fi
update-grub
printf 'Persistent GRUB default is now the top-level Ubuntu entry (%s).\n' \
	"$kernel_release"
