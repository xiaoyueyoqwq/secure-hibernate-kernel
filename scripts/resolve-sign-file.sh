#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'Usage: resolve-sign-file.sh [SIGN_FILE]\n'
}

if [[ $# -gt 1 ]]; then
	usage >&2
	exit 2
fi

for command in dpkg-query find realpath sort stat; do
	command -v "$command" >/dev/null || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done

validate_sign_file() {
	local candidate=$1
	local mode owner path status uid

	path=$(realpath -e "$candidate") || return 1
	[[ -f $path && -x $path ]] || return 1
	[[ $path == /usr/src/linux-headers-*/scripts/sign-file ]] || return 1

	owner=$(dpkg-query -S "$path" 2>/dev/null | awk -v path="$path" '
		{
			suffix = ": " path
			if (length($0) >= length(suffix) &&
			    substr($0, length($0) - length(suffix) + 1) == suffix) {
				print substr($0, 1, length($0) - length(suffix))
				exit
			}
		}
	')
	[[ $owner == linux-headers-* ]] || return 1
	status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$owner" 2>/dev/null) || return 1
	[[ $status == 'ii ' ]] || return 1

	uid=$(stat -c '%u' "$path")
	mode=$(stat -c '%a' "$path")
	(( uid == 0 )) || return 1
	(( (8#$mode & 022) == 0 )) || return 1

	printf '%s\n' "$path"
}

if [[ $# -eq 1 ]]; then
	if ! validate_sign_file "$1"; then
		printf 'Signing helper is not an installed, root-owned Ubuntu headers file: %s\n' \
			"$1" >&2
		exit 1
	fi
	exit 0
fi

mapfile -t candidates < <(find /usr/src -type f \
	-path '*/linux-headers-*-generic/scripts/sign-file' -print | sort -Vr)
for candidate in "${candidates[@]}"; do
	if validate_sign_file "$candidate" 2>/dev/null; then
		exit 0
	fi
done

printf 'No trusted sign-file from an installed Ubuntu generic headers package was found.\n' >&2
exit 1
