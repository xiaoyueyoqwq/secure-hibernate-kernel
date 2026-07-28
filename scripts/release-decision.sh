#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'Usage: release-decision.sh EVENT_NAME RELEASE_EXISTS RELEASE_ASSET_FILE\n'
}

if [[ $# -ne 3 ]]; then
	usage >&2
	exit 2
fi

event_name=$1
release_exists=$2
release_assets=$3

if [[ $event_name != schedule && $event_name != workflow_dispatch ]]; then
	printf 'Unsupported GitHub event: %s\n' "$event_name" >&2
	exit 2
fi
if [[ $release_exists != true && $release_exists != false ]]; then
	printf 'RELEASE_EXISTS must be true or false.\n' >&2
	exit 2
fi
if [[ ! -f $release_assets ]]; then
	printf 'Release asset list does not exist: %s\n' "$release_assets" >&2
	exit 1
fi

if [[ $release_exists == false ]]; then
	printf 'build=true\n'
	exit 0
fi

release_complete=false
if grep -Fxq SHA256SUMS "$release_assets" &&
	grep -Fxq kernel-release.txt "$release_assets" &&
	grep -Fxq local-version.txt "$release_assets" &&
	grep -Fxq ubuntu-source-package-version.txt "$release_assets" &&
	grep -Fxq secure-hibernate-project.der "$release_assets" &&
	grep -Fxq secure-hibernate-project.pem "$release_assets" &&
	grep -Eq '^linux-headers-.*_amd64\.deb$' "$release_assets" &&
	grep -Eq '^linux-image-.*_amd64\.deb$' "$release_assets" &&
	grep -Eq '^signed-linux-image-.*_amd64\.deb$' "$release_assets"; then
	release_complete=true
fi

if [[ $event_name == schedule && $release_complete == true ]]; then
	printf 'build=false\n'
	exit 0
fi

if [[ $release_complete == true ]]; then
	printf 'Refusing to replace immutable assets in an existing Release.\n' >&2
else
	printf 'Existing Release is incomplete; repair it under a new tag.\n' >&2
fi
exit 1
