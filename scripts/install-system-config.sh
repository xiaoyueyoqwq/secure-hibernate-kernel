#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
	printf 'Usage: install-system-config.sh\n' >&2
	exit 2
fi
if (( EUID != 0 )); then
	printf 'This script must run as root.\n' >&2
	exit 1
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

install -d -o root -g root -m 0755 /etc/dracut.conf.d /etc/systemd/logind.conf.d
install -d -o root -g root -m 0755 /etc/systemd/system/systemd-hibernate.service.d
install -d -o root -g polkitd -m 0750 /etc/polkit-1/rules.d
install -o root -g root -m 0644 \
	"$repo_root/config/dracut/90-s4lockdown-resume.conf" \
	/etc/dracut.conf.d/90-s4lockdown-resume.conf
install -o root -g root -m 0644 \
	"$repo_root/config/logind/90-s4lockdown-lid.conf" \
	/etc/systemd/logind.conf.d/90-s4lockdown-lid.conf
install -o root -g root -m 0644 \
	"$repo_root/config/polkit/10-enable-local-hibernate.rules" \
	/etc/polkit-1/rules.d/10-enable-local-hibernate.rules
install -o root -g root -m 0755 \
	"$repo_root/config/systemd/s4lockdown-grub-reboot" \
	/usr/local/sbin/s4lockdown-grub-reboot
install -o root -g root -m 0644 \
	"$repo_root/config/systemd/s4lockdown-grub-reboot.service" \
	/etc/systemd/system/s4lockdown-grub-reboot.service
install -o root -g root -m 0644 \
	"$repo_root/config/systemd/systemd-hibernate.service.d/10-s4lockdown-grub-reboot.conf" \
	/etc/systemd/system/systemd-hibernate.service.d/10-s4lockdown-grub-reboot.conf

if [[ -L /etc/systemd/system/hibernate.target.requires/s4lockdown-grub-reboot.service ]]; then
	unlink /etc/systemd/system/hibernate.target.requires/s4lockdown-grub-reboot.service
fi
systemctl daemon-reload

running_kernel=$(uname -r)
if [[ $running_kernel == *-s4lockdown ]]; then
	dracut --force "/boot/initrd.img-$running_kernel" "$running_kernel"
fi

printf 'System configuration installed. Lid policy takes effect after the next reboot.\n'
