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

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
data_root=${XDG_DATA_HOME:-${HOME}/.local/share}
[[ $data_root == /* && $data_root != / ]] ||
	fail 'XDG_DATA_HOME must be a specific absolute directory'
applications_directory=$data_root/applications
desktop_target=$applications_directory/$application_id.desktop
icon_target=$data_root/icons/hicolor/256x256/apps/$application_id.png
icon_source=$project_root/linux/resources/app-icon.png
legacy_desktop_target=$applications_directory/$legacy_application_id.desktop

removed_desktop=false
if [[ -e $desktop_target || -L $desktop_target ]]; then
	[[ -f $desktop_target && ! -L $desktop_target ]] ||
		fail "refusing to remove a non-regular desktop entry: $desktop_target"
	if ! grep -Fxq 'X-SecureHibernate-Development=true' "$desktop_target" ||
		! grep -Fxq 'X-SecureHibernate-FlutterDevelopment=true' "$desktop_target"; then
		fail "refusing to remove a desktop entry not created by the Flutter development script: $desktop_target"
	fi
	unlink "$desktop_target"
	removed_desktop=true
fi

if [[ $removed_desktop == true && -e $icon_target ]]; then
	[[ -f $icon_target && ! -L $icon_target ]] ||
		fail "refusing to remove a non-regular icon: $icon_target"
	if [[ ! -f $icon_source ]] || ! cmp -s -- "$icon_source" "$icon_target"; then
		fail "refusing to remove a modified user icon: $icon_target"
	fi
	unlink "$icon_target"
fi

if [[ -f $legacy_desktop_target && ! -L $legacy_desktop_target ]] &&
	grep -Fxq 'Comment=Flutter visual prototype for Secure Hibernate Manager' "$legacy_desktop_target" &&
	grep -Fxq "StartupWMClass=$legacy_application_id" "$legacy_desktop_target"; then
	unlink "$legacy_desktop_target"
fi

if [[ -d $applications_directory ]] && command -v update-desktop-database >/dev/null 2>&1; then
	update-desktop-database "$applications_directory" >/dev/null
fi

printf 'Removed obsolete Flutter development desktop artifacts.\n'
