#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: prepare-release.sh PRIVATE_KEY CERTIFICATE [SOURCE_VERSION|auto] [OUTPUT_ROOT]

Downloads an unsigned GitHub Release, verifies its checksums, and signs the
kernel and modules locally. It never uploads or copies the private key.
EOF
}

if [[ $# -lt 2 || $# -gt 4 ]]; then
	usage >&2
	exit 2
fi

private_key=$1
certificate=$2
requested_source=${3:-auto}
output_root=${4:-artifacts/releases}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
release_repo=${GITHUB_REPOSITORY:-xiaoyueyoqwq/secure-hibernate-kernel}

for command in gh sha256sum; do
	command -v "$command" >/dev/null || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done

version_data=$("$repo_root/scripts/resolve-version.sh" "$requested_source" auto)
source_package_version=$(awk -F= '$1 == "source_package_version" { print $2 }' <<< "$version_data")
marker_tag=$(awk -F= '$1 == "marker_tag" { print $2 }' <<< "$version_data")

output_root=$(realpath -m "$output_root")
release_dir="$output_root/$marker_tag"
if [[ -e $release_dir ]]; then
	printf 'Refusing to overwrite existing release directory: %s\n' "$release_dir" >&2
	exit 1
fi
mkdir -p "$output_root"
staging_dir=$(mktemp -d "$output_root/.${marker_tag}.XXXXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT

if ! gh release download "$marker_tag" --repo "$release_repo" --dir "$staging_dir"; then
	printf 'Release %s is unavailable. Dispatch a build with:\n' "$marker_tag" >&2
	printf '  gh workflow run build.yml -R %s -f source_package_version=%s\n' \
		"$release_repo" "$source_package_version" >&2
	exit 1
fi

(
	cd "$staging_dir"
	sha256sum --check SHA256SUMS
)

recorded_version=$(< "$staging_dir/ubuntu-source-package-version.txt")
if [[ $recorded_version != "$source_package_version" ]]; then
	printf 'Release metadata mismatch: expected %s, found %s.\n' \
		"$source_package_version" "$recorded_version" >&2
	exit 1
fi

"$repo_root/scripts/sign-packages.sh" \
	"$staging_dir" "$private_key" "$certificate" "$staging_dir/signed"

mv "$staging_dir" "$release_dir"
trap - EXIT

printf 'Locally signed packages are in %s\n' "$release_dir/signed"
