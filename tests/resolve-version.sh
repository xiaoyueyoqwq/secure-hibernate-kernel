#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
resolver="$repo_root/scripts/resolve-version.sh"

assert_output() {
	local version=$1
	local expected_abi=$2
	local expected_local=$3
	local expected_tag=$4
	local patches_dir=$5
	local output

	output=$(PATCHES_DIR="$patches_dir" "$resolver" "$version" auto)
	grep -Fxq -- "abi_version=$expected_abi" <<< "$output"
	grep -Fxq -- "local_version=$expected_local" <<< "$output"
	grep -Fxq -- "marker_tag=$expected_tag" <<< "$output"
}

fixture_dir=$(mktemp -d)
empty_fixture=$(mktemp -d)
trap 'rm -rf "$fixture_dir" "$empty_fixture"' EXIT
: > "$fixture_dir/0001-hibernate-base.patch"
: > "$fixture_dir/0002-vmstat-fix-race.patch"

assert_output \
	7.0.0-28.28 \
	7.0.0-28 \
	-28-hibernate \
	ubuntu-7.0.0-28.28 \
	"$empty_fixture"
assert_output \
	6.14.0-37.37~24.04.1 \
	6.14.0-37 \
	-37-hibernate \
	ubuntu-6.14.0-37.37_24.04.1 \
	"$empty_fixture"
assert_output \
	7.0.0-29.31 \
	7.0.0-29 \
	-29-vmstat-hibernate \
	ubuntu-7.0.0-29.31-vmstat \
	"$fixture_dir"

if "$resolver" 7.0-28.28 auto >/dev/null 2>&1; then
	printf 'Invalid source version was accepted.\n' >&2
	exit 1
fi

printf 'resolve-version tests passed\n'
