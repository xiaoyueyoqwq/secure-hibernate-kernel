#!/usr/bin/env bash
set -euo pipefail

# Emits the patch feature tags (e.g. "-vmstat") that describe which extra
# project patches are present. The kernel local version is built from these
# tags so that "uname -r" makes the applied patch set obvious at a glance.
#
# Patch files must follow the layout patches/NNNN-<tag>-<description>.patch.
# The special tag "hibernate" names the project's own kernel flavor and is
# always placed at the end of the local version instead.

patches_dir=${PATCHES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/patches}

if [[ ! -d $patches_dir ]]; then
	exit 0
fi

tags=
for patch_file in "$patches_dir"/*.patch; do
	[[ -f $patch_file ]] || continue
	base=$(basename "$patch_file")
	if [[ $base =~ ^[0-9]+-([a-zA-Z0-9]+)- ]]; then
		tag=${BASH_REMATCH[1]}
		[[ $tag == hibernate ]] && continue
		tags="${tags}-${tag}"
	fi
done
printf '%s\n' "$tags"
