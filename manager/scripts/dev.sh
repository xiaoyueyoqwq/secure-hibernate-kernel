#!/usr/bin/env bash
set -euo pipefail

application_id=io.github.xiaoyueyoqwq.secure-hibernate-manager
legacy_application_id=$application_id-flutter-prototype

fail() {
	printf 'flutter-dev: %s\n' "$*" >&2
	exit 1
}

[[ $# -eq 0 ]] || fail 'this command accepts no arguments'
(( EUID != 0 )) || fail 'run this command as the desktop user, not root'

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
flutter_command=$(command -v flutter) || fail 'flutter is not installed or is not on PATH'
icon_source=$project_root/linux/resources/app-icon.png

[[ -f $icon_source && ! -L $icon_source ]] || fail 'the application icon is unavailable'
[[ -x $flutter_command && $flutter_command == /* ]] ||
	fail 'flutter did not resolve to an absolute executable path'
[[ $project_root =~ ^/[A-Za-z0-9_@+.,/:=-]+$ ]] ||
	fail 'the Flutter project path contains characters unsupported by the development desktop entry'
[[ $flutter_command =~ ^/[A-Za-z0-9_@+.,/:=-]+$ ]] ||
	fail 'the Flutter path contains characters unsupported by the development desktop entry'

data_root=${XDG_DATA_HOME:-${HOME}/.local/share}
[[ $data_root == /* && $data_root != / ]] ||
	fail 'XDG_DATA_HOME must be a specific absolute directory'
applications_directory=$data_root/applications
icon_directory=$data_root/icons/hicolor/256x256/apps
desktop_target=$applications_directory/$application_id.desktop
icon_target=$icon_directory/$application_id.png
legacy_desktop_target=$applications_directory/$legacy_application_id.desktop

/usr/bin/install -d -m 0755 -- "$applications_directory" "$icon_directory"
if [[ -e $legacy_desktop_target || -L $legacy_desktop_target ]]; then
	if [[ -f $legacy_desktop_target && ! -L $legacy_desktop_target ]] &&
		grep -Fxq 'Comment=Flutter visual prototype for Secure Hibernate Manager' "$legacy_desktop_target" &&
		grep -Fxq "Path=$project_root" "$legacy_desktop_target" &&
		grep -Fxq "StartupWMClass=$legacy_application_id" "$legacy_desktop_target"; then
		unlink "$legacy_desktop_target"
	fi
fi
if [[ -e $desktop_target || -L $desktop_target ]]; then
	[[ -f $desktop_target && ! -L $desktop_target ]] ||
		fail "refusing a non-regular desktop entry: $desktop_target"
	grep -Fxq 'X-SecureHibernate-Development=true' "$desktop_target" ||
		fail "refusing to replace a desktop entry not created by this project: $desktop_target"
fi
if [[ -e $icon_target || -L $icon_target ]]; then
	[[ -f $icon_target && ! -L $icon_target ]] ||
		fail "refusing a non-regular icon target: $icon_target"
fi

temporary_entry=$(mktemp --suffix=.desktop "$applications_directory/.$application_id.XXXXXX")
cleanup() {
	[[ ! -e $temporary_entry ]] || unlink "$temporary_entry"
}
trap cleanup EXIT

{
	printf '%s\n' '[Desktop Entry]'
	printf '%s\n' 'Type=Application'
	printf '%s\n' 'Version=1.0'
	printf '%s\n' 'Name=Secure Hibernate (Flutter Development)'
	printf '%s\n' 'Comment=Run the local Secure Hibernate Manager Flutter build'
	printf 'Exec=%s run -d linux\n' "$flutter_command"
	printf 'Path=%s\n' "$project_root"
	printf 'Icon=%s\n' "$application_id"
	printf '%s\n' 'Terminal=true'
	printf '%s\n' 'Categories=System;'
	printf '%s\n' 'StartupNotify=true'
	printf 'StartupWMClass=%s\n' "$application_id"
	printf '%s\n' 'X-SecureHibernate-Development=true'
	printf '%s\n' 'X-SecureHibernate-FlutterDevelopment=true'
} > "$temporary_entry"
chmod 0644 "$temporary_entry"

if command -v desktop-file-validate >/dev/null 2>&1; then
	desktop-file-validate "$temporary_entry"
fi
mv -f -- "$temporary_entry" "$desktop_target"
/usr/bin/install -m 0644 -- "$icon_source" "$icon_target"

if command -v update-desktop-database >/dev/null 2>&1; then
	update-desktop-database "$applications_directory" >/dev/null
fi

cd -- "$project_root"
exec "$flutter_command" run -d linux
