#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: deploy-system.sh LUKS_DEVICE HEADER_BACKUP [KERNEL_RELEASE]

Installs hibernation integration, backs up the LUKS2 header without
overwriting an existing file, and selects the signed custom kernel. It does
not enroll or remove LUKS/TPM tokens.
EOF
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
	usage >&2
	exit 2
fi
if (( EUID != 0 )); then
	printf 'This script must run as root.\n' >&2
	exit 1
fi

luks_device=$(realpath "$1")
header_backup=$(realpath -m "$2")
kernel_release=${3:-$(uname -r)}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ ! -b $luks_device ]]; then
	printf 'LUKS target is not a block device: %s\n' "$luks_device" >&2
	exit 1
fi
if [[ $(cryptsetup luksDump "$luks_device" 2>/dev/null | awk '$1 == "Version:" { print $2; exit }') != 2 ]]; then
	printf 'Target is not a readable LUKS2 device: %s\n' "$luks_device" >&2
	exit 1
fi
if [[ -e $header_backup || -e $header_backup.sha256 ]]; then
	printf 'Refusing to overwrite existing header backup or checksum: %s\n' \
		"$header_backup" >&2
	exit 1
fi
"$repo_root/scripts/set-default-kernel.sh" --check-only "$kernel_release"

backup_parent=$(dirname "$header_backup")
if [[ ! -d $backup_parent ]]; then
	printf 'Backup parent directory does not exist: %s\n' "$backup_parent" >&2
	exit 1
fi
backup_owner=$(stat -c '%u:%g' "$backup_parent")

cryptsetup luksHeaderBackup "$luks_device" --header-backup-file "$header_backup"
chown "$backup_owner" "$header_backup"
chmod 0600 "$header_backup"
sha256sum "$header_backup" > "$header_backup.sha256"
chown "$backup_owner" "$header_backup.sha256"
chmod 0600 "$header_backup.sha256"

"$repo_root/scripts/install-system-config.sh"
"$repo_root/scripts/set-default-kernel.sh" "$kernel_release"

printf '\nDeployment completed without changing TPM tokens.\n'
printf 'LUKS header backup: %s\n' "$header_backup"
printf 'Next, enroll an additional TPM token while booted into %s.\n' "$kernel_release"
