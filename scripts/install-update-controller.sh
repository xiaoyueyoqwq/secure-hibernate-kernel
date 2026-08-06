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

for command in apt-cache awk cmp cryptsetup dpkg dpkg-deb dpkg-query dracut find \
	findmnt flock fuser getent grep install lsblk modinfo mokutil nproc openssl \
	mktemp mv perl python3 rm sbverify systemctl systemd-analyze systemd-ask-password \
	systemd-cryptenroll tpm2 update-grub useradd wall xz zstd; do
	command -v "$command" >/dev/null || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done
patch_tags=$("$repo_root/scripts/patch-tags.sh")

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
	"$install_root" "$install_root/scripts" "$install_root/certs" \
	"$install_root/config" "$install_root/config/dracut" \
	"$install_root/config/grub" "$install_root/config/logind" \
	"$install_root/config/polkit" "$install_root/config/systemd" \
	"$install_root/config/systemd/systemd-hibernate.service.d"; do
	if [[ -L $directory ]]; then
		printf 'Refusing a symbolic-link installation directory: %s\n' \
			"$directory" >&2
		exit 1
	fi
done

timer_was_active=false
if systemctl is-active --quiet s4lockdown-update.timer; then
	timer_was_active=true
fi
installation_complete=false
patch_tags_temp=
restore_timer_on_failure() {
	if [[ -n $patch_tags_temp ]]; then
		rm -f -- "$patch_tags_temp"
	fi
	if [[ $installation_complete != true && $timer_was_active == true ]]; then
		systemctl start s4lockdown-update.timer >/dev/null 2>&1 || true
	fi
}
trap restore_timer_on_failure EXIT

systemctl stop s4lockdown-update.timer >/dev/null 2>&1 || true
if systemctl is-active --quiet s4lockdown-update.timer; then
	printf 'Could not stop the updater timer before installation.\n' >&2
	exit 1
fi
for unit in s4lockdown-update-check.service \
	s4lockdown-update-manager-check.service s4lockdown-update.service; do
	if systemctl is-active --quiet "$unit"; then
		printf 'Updater operation is active; retry after it finishes: %s\n' "$unit" >&2
		exit 1
	fi
done

install -d -o root -g root -m 0755 /var/lib/s4lockdown-update

# Desktop users may read check-state.json; staged assets are separate mode-0700 trees.
install -d -o "$update_user" -g "$update_user" -m 0755 \
	/var/cache/s4lockdown-update
lock_file=/var/lib/s4lockdown-update/update.lock
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
	"$install_root" "$install_root/scripts" "$install_root/certs" \
	"$install_root/config" "$install_root/config/dracut" \
	"$install_root/config/grub" "$install_root/config/logind" \
	"$install_root/config/polkit" "$install_root/config/systemd" \
	"$install_root/config/systemd/systemd-hibernate.service.d"
patch_tags_temp=$(mktemp "$install_root/.patch-tags.XXXXXX")
printf '%s\n' "$patch_tags" > "$patch_tags_temp"
chown root:root "$patch_tags_temp"
chmod 0644 "$patch_tags_temp"
mv -fT -- "$patch_tags_temp" "$install_root/patch-tags.txt"
patch_tags_temp=
for script in extract-module-signature.pl install-signed-packages.sh \
	install-system-config.sh manager-helper.py patch-tags.sh \
	release-manifest.py resolve-version.sh set-default-kernel.sh \
	update-local.py update-local.sh verify-module-signatures.sh; do
	install -o root -g root -m 0755 "$repo_root/scripts/$script" \
		"$install_root/scripts/$script"
done
install -o root -g root -m 0644 \
	"$repo_root/certs/secure-hibernate-project.pem" \
	"$install_root/certs/secure-hibernate-project.pem"
install -o root -g root -m 0644 \
	"$repo_root/certs/secure-hibernate-project.der" \
	"$install_root/certs/secure-hibernate-project.der"

install -o root -g root -m 0644 \
	"$repo_root/config/dracut/90-s4lockdown-resume.conf" \
	"$install_root/config/dracut/90-s4lockdown-resume.conf"
install -o root -g root -m 0755 \
	"$repo_root/config/grub/11_s4lockdown_resume" \
	"$install_root/config/grub/11_s4lockdown_resume"
install -o root -g root -m 0644 \
	"$repo_root/config/logind/90-s4lockdown-lid.conf" \
	"$install_root/config/logind/90-s4lockdown-lid.conf"
install -o root -g root -m 0644 \
	"$repo_root/config/polkit/10-enable-local-hibernate.rules" \
	"$install_root/config/polkit/10-enable-local-hibernate.rules"
install -o root -g root -m 0755 \
	"$repo_root/config/systemd/s4lockdown-grub-reboot" \
	"$install_root/config/systemd/s4lockdown-grub-reboot"
install -o root -g root -m 0644 \
	"$repo_root/config/systemd/s4lockdown-grub-reboot.service" \
	"$install_root/config/systemd/s4lockdown-grub-reboot.service"
install -o root -g root -m 0644 \
	"$repo_root/config/systemd/systemd-hibernate.service.d/10-s4lockdown-grub-reboot.conf" \
	"$install_root/config/systemd/systemd-hibernate.service.d/10-s4lockdown-grub-reboot.conf"

install -d -o root -g root -m 0755 /etc/systemd/system
for unit in s4lockdown-update-check.service \
	s4lockdown-update-manager-check.service s4lockdown-update.service \
	s4lockdown-update.timer; do
	install -o root -g root -m 0644 "$repo_root/config/systemd/$unit" \
		"/etc/systemd/system/$unit"
done
if [[ ! -e /etc/s4lockdown-update.conf ]]; then
	install -o root -g root -m 0644 "$repo_root/config/s4lockdown-update.conf" \
		/etc/s4lockdown-update.conf
fi

/usr/bin/python3 -m py_compile "$install_root/scripts/manager-helper.py" \
	"$install_root/scripts/release-manifest.py" \
	"$install_root/scripts/update-local.py"
bash -n "$install_root/scripts/"*.sh
"$install_root/scripts/update-local.sh" status >/dev/null
systemd-analyze verify \
	/etc/systemd/system/s4lockdown-update-check.service \
	/etc/systemd/system/s4lockdown-update-manager-check.service \
	/etc/systemd/system/s4lockdown-update.service \
	/etc/systemd/system/s4lockdown-update.timer
systemctl daemon-reload
for unit in s4lockdown-update-check.service \
	s4lockdown-update-manager-check.service s4lockdown-update.service; do
	if systemctl is-failed --quiet "$unit"; then
		systemctl reset-failed "$unit"
	fi
done

installed_policy=$(sed -n 's/^POLICY=//p' /etc/s4lockdown-update.conf)
case $installed_policy in
	manual)
		systemctl disable --now s4lockdown-update.timer
		;;
	check-and-notify | automatic-install)
		systemctl enable --now s4lockdown-update.timer
		;;
	*)
		printf 'Unsupported updater policy: %s\n' "$installed_policy" >&2
		exit 1
		;;
esac
installation_complete=true

printf 'Installed updater with policy: %s\n' "$installed_policy"
if [[ $installed_policy == manual ]]; then
	printf 'The scheduled timer is disabled by the manual policy.\n'
else
	printf 'The timer checks after boot and at 10:00, 15:00, and 20:00 daily.\n'
fi
