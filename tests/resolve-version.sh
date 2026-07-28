#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
resolver="$repo_root/scripts/resolve-version.sh"

assert_output() {
	local version=$1
	local expected_abi=$2
	local expected_local=$3
	local expected_tag=$4
	local output

	output=$("$resolver" "$version" auto)
	grep -Fxq -- "abi_version=$expected_abi" <<< "$output"
	grep -Fxq -- "local_version=$expected_local" <<< "$output"
	grep -Fxq -- "marker_tag=$expected_tag" <<< "$output"
}

assert_output \
	7.0.0-28.28 \
	7.0.0-28 \
	-ubuntu28-s4lockdown \
	ubuntu-7.0.0-28.28
assert_output \
	6.14.0-37.37~24.04.1 \
	6.14.0-37 \
	-ubuntu37-s4lockdown \
	ubuntu-6.14.0-37.37_24.04.1
assert_output \
	7.0.0-29.31 \
	7.0.0-29 \
	-ubuntu29-s4lockdown \
	ubuntu-7.0.0-29.31

if "$resolver" 7.0-28.28 auto >/dev/null 2>&1; then
	printf 'Invalid source version was accepted.\n' >&2
	exit 1
fi

printf 'resolve-version tests passed\n'
