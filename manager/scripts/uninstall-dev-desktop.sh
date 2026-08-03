#!/usr/bin/env bash
set -euo pipefail

application_id=io.github.xiaoyueyoqwq.secure-hibernate-manager
legacy_application_id=$application_id-flutter-prototype

fail() {
	printf 'flutter-uninstall-dev-desktop: %s\n' "$*" >&2
	exit 1
}

[[ $# -eq 0 ]] || fail 'this command accepts no arguments'
(( EUID != 0 )) || fail 'run this command as the desktop user, not root'

data_root=${XDG_DATA_HOME:-${HOME}/.local/share}
[[ $data_root == /* && $data_root != / ]] ||
	fail 'XDG_DATA_HOME must be a specific absolute directory'
applications_directory=$data_root/applications
desktop_target=$applications_directory/$application_id.desktop
icon_target=$data_root/icons/hicolor/256x256/apps/$application_id.png
legacy_desktop_target=$applications_directory/$legacy_application_id.desktop

if [[ -e $desktop_target || -L $desktop_target ]]; then
	[[ -f $desktop_target && ! -L $desktop_target ]] ||
		fail "refusing a non-regular desktop entry: $desktop_target"
	grep -Fxq 'X-SecureHibernate-FlutterDevelopment=true' "$desktop_target" ||
		fail "refusing to remove a desktop entry not created by the Flutter development script: $desktop_target"
fi
for target in "$desktop_target" "$icon_target"; do
	if [[ -L $target || ( -e $target && ! -f $target ) ]]; then
		fail "refusing to remove a non-regular target: $target"
	fi
	[[ ! -e $target ]] || unlink "$target"
done
if [[ -f $legacy_desktop_target && ! -L $legacy_desktop_target ]] &&
	grep -Fxq 'Comment=Flutter visual prototype for Secure Hibernate Manager' "$legacy_desktop_target" &&
	grep -Fxq "StartupWMClass=$legacy_application_id" "$legacy_desktop_target"; then
	unlink "$legacy_desktop_target"
fi

if [[ -d $applications_directory ]] && command -v update-desktop-database >/dev/null 2>&1; then
	update-desktop-database "$applications_directory" >/dev/null
fi

printf 'Removed Flutter development desktop identity %s.\n' "$application_id"
