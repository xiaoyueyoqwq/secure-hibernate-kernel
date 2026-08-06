#!/usr/bin/env bash
set -euo pipefail

# Emits the patch feature tags (e.g. "-vmstat") that describe which extra
# project patches are present. The kernel local version is built from these
# tags so that "uname -r" makes the applied patch set obvious at a glance.
#
# Patch files must follow the layout patches/NNNN-<tag>-<description>.patch.
# The special tag "hibernate" names the project's own kernel flavor and is
# always placed at the end of the local version instead.

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
patches_dir=${PATCHES_DIR:-$repo_root/patches}
tags_file=${PATCH_TAGS_FILE:-$repo_root/patch-tags.txt}

if [[ ! -d $patches_dir ]]; then
	if [[ -L $tags_file || ! -f $tags_file ]]; then
		printf 'Patch metadata is unavailable: %s\n' "$tags_file" >&2
		exit 1
	fi
	mapfile -t stored_tags < "$tags_file"
	if (( ${#stored_tags[@]} != 1 )) ||
		[[ ! ${stored_tags[0]} =~ ^(-[a-zA-Z0-9]+)*$ ]]; then
		printf 'Invalid patch metadata: %s\n' "$tags_file" >&2
		exit 1
	fi
	printf '%s\n' "${stored_tags[0]}"
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
