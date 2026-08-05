#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper="$repo_root/config/systemd/s4lockdown-grub-reboot"
generator="$repo_root/config/grub/11_s4lockdown_resume"
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

# shellcheck disable=SC1090,SC1091
source "$helper"

[[ $(basename "$generator") == 11_s4lockdown_resume ]]
[[ -x $generator ]]
grep -Fq 'legacy_grub_generator=/etc/grub.d/09_s4lockdown_resume' \
	"$repo_root/scripts/install-system-config.sh"

if grep -Eq '^set -[^ ]*u' "$generator"; then
	printf 'GRUB generator enables nounset against grub-mkconfig_lib.\n' >&2
	exit 1
fi

kernel_release=7.0.12-28-hibernate
kernel_id="gnulinux-${kernel_release}-advanced-test-root"
cat > "$temp_dir/grub.cfg" <<EOF
submenu 'Advanced options' --id 'gnulinux-advanced-test-root' {
	menuentry 'Ubuntu test' --id '$kernel_id' {
		linux /vmlinuz-$kernel_release root=/dev/mapper/test-root ro quiet
		initrd /intel-ucode.img /initrd.img-$kernel_release
	}
}
EOF
mapfile -t paths < <(extract_kernel_paths "$temp_dir/grub.cfg" "$kernel_id")
[[ ${#paths[@]} -eq 2 ]]
[[ ${paths[0]} == "/vmlinuz-$kernel_release" ]]
[[ ${paths[1]} == "/intel-ucode.img /initrd.img-$kernel_release" ]]

printf 'BOOT_IMAGE=/vmlinuz-%s root=/dev/mapper/test-root ro quiet\n' \
	"$kernel_release" > "$temp_dir/cmdline"
[[ $(running_kernel_cmdline "$temp_dir/cmdline") == \
	'root=/dev/mapper/test-root ro quiet' ]]

cat > "$temp_dir/grub-mkconfig_lib" <<'EOF'
prepare_grub_to_access_device() {
	printf '%s\n' 'insmod part_gpt' 'insmod ext2' \
		'search --no-floppy --fs-uuid --set=root test-boot'
}
EOF
sed "s|^\. /usr/lib/grub/grub-mkconfig_lib$|. '$temp_dir/grub-mkconfig_lib'|" \
	"$generator" > "$temp_dir/generator"
GRUB_DEVICE_BOOT=/dev/test-boot sh "$temp_dir/generator" > "$temp_dir/entry.cfg"
grep -Fq -- "--id 's4lockdown-resume'" "$temp_dir/entry.cfg"
# shellcheck disable=SC2016
grep -Fq 'linux ${s4lockdown_linux} ${s4lockdown_cmdline}' \
	"$temp_dir/entry.cfg"
# shellcheck disable=SC2016
grep -Fq 'initrd ${s4lockdown_initrd}' "$temp_dir/entry.cfg"
grep -Fq 'search --no-floppy --fs-uuid --set=root test-boot' \
	"$temp_dir/entry.cfg"
if grep -Fq 'Advanced options' "$temp_dir/entry.cfg"; then
	printf 'Generated resume entry still depends on the Advanced submenu.\n' >&2
	exit 1
fi

# shellcheck disable=SC2016
grep -Fq 'grub-reboot "$entry_id"' "$helper"
grep -Fq 'GRUB_TIMEOUT_STYLE=hidden' "$repo_root/scripts/set-default-kernel.sh"
grep -Fq 'GRUB_TIMEOUT=0' "$repo_root/scripts/set-default-kernel.sh"
grep -Fq 'GRUB_RECORDFAIL_TIMEOUT=0' "$repo_root/scripts/set-default-kernel.sh"
printf 'GRUB resume-entry tests passed\n'
