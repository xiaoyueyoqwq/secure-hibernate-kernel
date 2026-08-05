#!/usr/bin/env bash
set -euo pipefail

application_id=io.github.xiaoyueyoqwq.secure-hibernate-manager

fail() {
	printf 'flutter-dev: %s\n' "$*" >&2
	exit 1
}

warn() {
	printf 'flutter-dev: warning: %s\n' "$*" >&2
}

[[ $# -eq 0 ]] || fail 'this command accepts no arguments'
(( EUID != 0 )) || fail 'run this command as the desktop user, not root'

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
flutter_command=$(command -v flutter) || fail 'flutter is not installed or is not on PATH'
[[ -x $flutter_command && $flutter_command == /* ]] ||
	fail 'flutter did not resolve to an absolute executable path'

# Older versions installed a user-level entry under the production desktop ID.
# Remove only artifacts that still match the development script's exact markers.
data_root=${XDG_DATA_HOME:-${HOME}/.local/share}
[[ $data_root == /* && $data_root != / ]] ||
	fail 'XDG_DATA_HOME must be a specific absolute directory'
applications_directory=$data_root/applications
desktop_target=$applications_directory/$application_id.desktop
icon_target=$data_root/icons/hicolor/256x256/apps/$application_id.png
icon_source=$project_root/linux/resources/app-icon.png

removed_desktop=false
if [[ -e $desktop_target || -L $desktop_target ]]; then
	if [[ -f $desktop_target && ! -L $desktop_target ]] &&
		grep -Fxq 'X-SecureHibernate-Development=true' "$desktop_target" &&
		grep -Fxq 'X-SecureHibernate-FlutterDevelopment=true' "$desktop_target"; then
		unlink "$desktop_target"
		removed_desktop=true
	else
		warn "preserving unrecognized user desktop entry: $desktop_target"
	fi
fi

if [[ $removed_desktop == true && -e $icon_target ]]; then
	if [[ -f $icon_target && ! -L $icon_target && -f $icon_source ]] &&
		cmp -s -- "$icon_source" "$icon_target"; then
		unlink "$icon_target"
	else
		warn "preserving modified or non-regular user icon: $icon_target"
	fi
fi

if [[ $removed_desktop == true && -d $applications_directory ]] &&
	command -v update-desktop-database >/dev/null 2>&1; then
	update-desktop-database "$applications_directory" >/dev/null
fi

cd -- "$project_root"
exec "$flutter_command" run -d linux
