#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

cp "$repo_root/config/systemd/s4lockdown-grub-reboot.service" \
	"$repo_root/config/systemd/s4lockdown-update-check.service" \
	"$repo_root/config/systemd/s4lockdown-update-manager-check.service" \
	"$repo_root/config/systemd/s4lockdown-update.service" \
	"$repo_root/config/systemd/s4lockdown-update.timer" "$temp_dir/"
sed -i 's|^ExecStart=.*|ExecStart=/bin/true|' "$temp_dir/"*.service

SYSTEMD_UNIT_PATH="$temp_dir:/usr/lib/systemd/system:/lib/systemd/system" \
	systemd-analyze verify \
		"$temp_dir/s4lockdown-grub-reboot.service" \
		"$temp_dir/s4lockdown-update-check.service" \
		"$temp_dir/s4lockdown-update-manager-check.service" \
		"$temp_dir/s4lockdown-update.service" \
		"$temp_dir/s4lockdown-update.timer"

printf 'systemd unit tests passed\n'
