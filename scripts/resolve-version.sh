#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: resolve-version.sh [SOURCE_PACKAGE_VERSION|auto] [LOCAL_VERSION|auto]

With "auto", resolves the current Ubuntu HWE kernel source version and derives
an ABI-specific local suffix such as -28-hibernate.
EOF
}

if [[ $# -gt 2 ]]; then
	usage >&2
	exit 2
fi

requested_source=${1:-auto}
requested_local=${2:-auto}
meta_package=${KERNEL_META_PACKAGE:-linux-image-generic-hwe-26.04}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

candidate_version() {
	local package=$1
	local candidate

	candidate=$(LC_ALL=C apt-cache policy "$package" \
		| awk '$1 == "Candidate:" { print $2; exit }')
	if [[ -z $candidate || $candidate == "(none)" ]]; then
		printf 'No candidate version is available for %s.\n' "$package" >&2
		return 1
	fi
	printf '%s\n' "$candidate"
}

if [[ $requested_source == auto ]]; then
	command -v apt-cache >/dev/null || {
		printf 'Required command not found: apt-cache\n' >&2
		exit 1
	}
	meta_version=$(candidate_version "$meta_package")
	source_name=${meta_version%%-*}
	source_package_version=$(candidate_version "linux-source-$source_name")
	if [[ $source_package_version != "$meta_version" ]]; then
		printf 'HWE meta version %s does not match source version %s.\n' \
			"$meta_version" "$source_package_version" >&2
		exit 1
	fi
else
	source_package_version=$requested_source
fi

if [[ $source_package_version =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)\.[0-9]+([.+~][0-9A-Za-z.+~-]+)?$ ]]; then
	source_name=${BASH_REMATCH[1]}
	abi_number=${BASH_REMATCH[2]}
else
	printf 'Unsupported Ubuntu kernel package version: %s\n' "$source_package_version" >&2
	exit 2
fi

abi_version="${source_name}-${abi_number}"
local_version=$requested_local

if [[ $local_version == auto ]]; then
	patch_tags=$("$repo_root/scripts/patch-tags.sh")
	local_version="-${abi_number}${patch_tags}-hibernate"
fi
if [[ ! $local_version =~ ^-[a-zA-Z0-9][a-zA-Z0-9.+~-]*$ ]]; then
	printf 'LOCAL_VERSION must begin with "-" and contain package-safe characters.\n' >&2
	exit 2
fi

printf 'source_package_version=%s\n' "$source_package_version"
printf 'source_name=%s\n' "$source_name"
printf 'abi_version=%s\n' "$abi_version"
printf 'abi_number=%s\n' "$abi_number"
printf 'local_version=%s\n' "$local_version"
printf 'marker_tag=ubuntu-%s\n' "${source_package_version//\~/_}"
