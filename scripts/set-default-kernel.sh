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
if [[ $kernel_release != *-s4lockdown && $kernel_release != *-hibernate ]]; then
	printf 'Refusing a kernel without the project suffix: %s\n' "$kernel_release" >&2
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

validate_grub_entries() {
	local grub_config=$1
	if ! grep -Fq "'$submenu_id'" "$grub_config" ||
		! grep -Fq "'$kernel_id'" "$grub_config"; then
		printf 'GRUB does not contain the expected submenu and kernel IDs: %s\n' \
			"$submenu_id>$kernel_id" >&2
		return 1
	fi
	if ! awk -v id="'$simple_id'" -v image="/vmlinuz-$kernel_release" '
		index($0, id) { in_entry = 1 }
		in_entry && index($0, image) { found = 1 }
		in_entry && /^}/ { exit(found ? 0 : 1) }
		END { if (!in_entry || !found) exit 1 }
	' "$grub_config"; then
		printf 'The top-level Ubuntu entry does not load %s.\n' "$kernel_release" >&2
		return 1
	fi
}

if ! grep -Fq "'$submenu_id'" /boot/grub/grub.cfg ||
	! grep -Fq "'$kernel_id'" /boot/grub/grub.cfg; then
	printf 'GRUB does not contain the expected submenu and kernel IDs: %s\n' \
		"$submenu_id>$kernel_id" >&2
	exit 1
fi
if $check_only; then
	validate_grub_entries /boot/grub/grub.cfg
	printf 'Validated top-level Ubuntu and exact kernel entries for %s\n' \
		"$kernel_release"
	exit 0
fi

config_file=/etc/default/grub.d/99-s4lockdown.cfg
temp_dir=$(mktemp -d)
temp_file="$temp_dir/99-s4lockdown.cfg"
backup_file="$temp_dir/99-s4lockdown.cfg.previous"
config_existed=false
test_config_backup=
trap 'rm -rf -- "$temp_dir"' EXIT
if [[ -L $config_file || ( -e $config_file && ! -f $config_file ) ]]; then
	printf 'Refusing a non-regular GRUB configuration: %s\n' "$config_file" >&2
	exit 1
fi
if [[ -f $config_file ]]; then
	cp -a -- "$config_file" "$backup_file"
	config_existed=true
fi

restore_configuration() {
	if $config_existed; then
		cp -a -- "$backup_file" "$config_file"
	else
		rm -f -- "$config_file"
	fi
	if [[ -n $test_config_backup && -f $test_config_backup ]]; then
		mv -- "$test_config_backup" /etc/default/grub.d/99-s4lockdown-test.cfg
	fi
}

{
	printf '# Boot the top-level Ubuntu entry and keep the normal path menu-free.\n'
	printf 'GRUB_DEFAULT="%s"\n' "$simple_id"
	printf 'GRUB_TOP_LEVEL="/boot/vmlinuz-%s"\n' "$kernel_release"
	printf 'GRUB_TIMEOUT_STYLE=hidden\n'
	printf 'GRUB_TIMEOUT=0\n'
	printf 'GRUB_RECORDFAIL_TIMEOUT=0\n'
} > "$temp_file"

install -o root -g root -m 0644 "$temp_file" "$config_file"
if [[ -e /etc/default/grub.d/99-s4lockdown-test.cfg ]]; then
	test_config_backup="/etc/default/grub.d/99-s4lockdown-test.cfg.disabled.$(date +%s)"
	mv /etc/default/grub.d/99-s4lockdown-test.cfg "$test_config_backup"
	printf 'Preserved previous GRUB test configuration as %s\n' "$test_config_backup"
fi
if ! update-grub; then
	printf 'Could not regenerate GRUB for %s; restoring the previous configuration.\n' \
		"$kernel_release" >&2
	restore_configuration
	if ! update-grub; then
		printf 'GRUB regeneration also failed after restoring the previous configuration.\n' >&2
	fi
	exit 1
fi
if ! validate_grub_entries /boot/grub/grub.cfg; then
	printf 'Generated GRUB configuration did not select %s; restoring the previous configuration.\n' \
		"$kernel_release" >&2
	restore_configuration
	if ! update-grub; then
		printf 'GRUB regeneration failed after restoring the previous configuration.\n' >&2
	fi
	exit 1
fi
printf 'Persistent GRUB default is now the top-level Ubuntu entry (%s).\n' \
	"$kernel_release"
