#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'Usage: install-update-controller.sh\n'
}

if [[ $# -ne 0 ]]; then
	usage >&2
	exit 2
fi
if (( EUID != 0 )); then
	printf 'This script must run as root.\n' >&2
	exit 1
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
install_root=/usr/local/lib/s4lockdown-update
update_user=s4lockdown-update

for command in apt-cache awk dpkg dpkg-deb dpkg-query find flock fuser getent \
	install modinfo nproc openssl perl python3 sbverify systemctl systemd-analyze \
	useradd wall xz zstd; do
	command -v "$command" >/dev/null || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done

if getent passwd "$update_user" >/dev/null; then
	IFS=: read -r _ _ update_uid update_gid _ update_home update_shell \
		< <(getent passwd "$update_user")
	if (( update_uid >= 1000 )) || [[ $update_home != /nonexistent ]] ||
		[[ $update_shell != /usr/sbin/nologin ]]; then
		printf 'Existing account is not the expected system user: %s\n' \
			"$update_user" >&2
		exit 1
	fi
	IFS=: read -r update_group _ installed_group_gid _ \
		< <(getent group "$update_gid")
	if [[ $update_group != "$update_user" || $installed_group_gid != "$update_gid" ]]; then
		printf 'Existing account does not use the expected private group: %s\n' \
			"$update_user" >&2
		exit 1
	fi
else
	useradd --system --user-group --no-create-home --home-dir /nonexistent \
		--shell /usr/sbin/nologin "$update_user"
fi

for directory in /var/cache/s4lockdown-update /var/lib/s4lockdown-update \
	"$install_root" "$install_root/scripts" "$install_root/certs"; do
	if [[ -L $directory ]]; then
		printf 'Refusing a symbolic-link installation directory: %s\n' \
			"$directory" >&2
		exit 1
	fi
done

install -d -o "$update_user" -g "$update_user" -m 0750 \
	/var/cache/s4lockdown-update
lock_file=/var/cache/s4lockdown-update/update.lock
if [[ -L $lock_file || ( -e $lock_file && ! -f $lock_file ) ]]; then
	printf 'Refusing a non-regular updater lock file: %s\n' "$lock_file" >&2
	exit 1
fi
exec 9<> "$lock_file"
if ! flock -n 9; then
	printf 'Another s4lockdown update operation is active.\n' >&2
	exit 1
fi
chown "$update_user:$update_user" "$lock_file"
chmod 0600 "$lock_file"

install -d -o root -g root -m 0755 \
	"$install_root" "$install_root/scripts" "$install_root/certs"
for script in extract-module-signature.pl install-signed-packages.sh \
	release-manifest.py resolve-version.sh set-default-kernel.sh \
	update-local.py update-local.sh verify-module-signatures.sh; do
	install -o root -g root -m 0755 "$repo_root/scripts/$script" \
		"$install_root/scripts/$script"
done
install -o root -g root -m 0644 \
	"$repo_root/certs/secure-hibernate-project.pem" \
	"$install_root/certs/secure-hibernate-project.pem"

install -d -o root -g root -m 0755 /etc/systemd/system
for unit in s4lockdown-update-check.service s4lockdown-update.service \
	s4lockdown-update.timer; do
	install -o root -g root -m 0644 "$repo_root/config/systemd/$unit" \
		"/etc/systemd/system/$unit"
done
if [[ ! -e /etc/s4lockdown-update.conf ]]; then
	install -o root -g root -m 0644 "$repo_root/config/s4lockdown-update.conf" \
		/etc/s4lockdown-update.conf
fi

install -d -o root -g root -m 0755 /var/lib/s4lockdown-update

/usr/bin/python3 -m py_compile "$install_root/scripts/release-manifest.py" \
	"$install_root/scripts/update-local.py"
bash -n "$install_root/scripts/"*.sh
"$install_root/scripts/update-local.sh" status >/dev/null
systemd-analyze verify \
	/etc/systemd/system/s4lockdown-update-check.service \
	/etc/systemd/system/s4lockdown-update.service \
	/etc/systemd/system/s4lockdown-update.timer
systemctl daemon-reload
systemctl enable --now s4lockdown-update.timer

printf 'Installed updater with policy: %s\n' \
	"$(sed -n 's/^POLICY=//p' /etc/s4lockdown-update.conf)"
printf 'The timer checks daily and never restarts the system automatically.\n'
