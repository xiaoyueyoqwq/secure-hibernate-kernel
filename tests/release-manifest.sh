#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT
mock_repo="$temp_dir/repo"
release_dir="$temp_dir/release"
source_version=7.0.0-29.29
kernel_release=7.0.13-ubuntu29-s4lockdown
local_version=-ubuntu29-s4lockdown
release_tag=ubuntu-7.0.0-29.29
git_commit=0123456789abcdef0123456789abcdef01234567
package_version="1${local_version}+ubuntu${source_version}"

for command in dpkg-deb openssl python3; do
	command -v "$command" >/dev/null || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done

mkdir -p "$mock_repo/scripts" "$mock_repo/certs" "$release_dir"
cp "$repo_root/scripts/release-manifest.py" "$mock_repo/scripts/"

openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
	-subj '/CN=Release Manifest Test/' \
	-addext 'basicConstraints=critical,CA:TRUE' \
	-addext 'keyUsage=critical,digitalSignature,keyCertSign' \
	-keyout "$temp_dir/test.priv" \
	-out "$mock_repo/certs/secure-hibernate-project.pem" >/dev/null 2>&1
chmod 0600 "$temp_dir/test.priv"
openssl x509 -in "$mock_repo/certs/secure-hibernate-project.pem" \
	-outform DER -out "$release_dir/secure-hibernate-project.der"
cp "$mock_repo/certs/secure-hibernate-project.pem" \
	"$release_dir/secure-hibernate-project.pem"

build_package() {
	local package_name=$1
	local output_name=$2
	local root="$temp_dir/package-$package_name"

	mkdir -p "$root/DEBIAN" "$root/usr/share/doc/$package_name"
	printf '%s\n' \
		"Package: $package_name" \
		"Version: $package_version" \
		'Architecture: amd64' \
		'Maintainer: Release Manifest Test <nobody@example.invalid>' \
		'Description: Minimal release manifest regression fixture' \
		> "$root/DEBIAN/control"
	printf 'fixture\n' > "$root/usr/share/doc/$package_name/fixture"
	dpkg-deb --build --root-owner-group "$root" "$release_dir/$output_name" \
		>/dev/null
}

headers_name="linux-headers-${kernel_release}_${package_version}_amd64.deb"
image_name="linux-image-${kernel_release}_${package_version}_amd64.deb"
signed_name="signed-linux-image-${kernel_release}_${package_version}_amd64.deb"
build_package "linux-headers-$kernel_release" "$headers_name"
build_package "linux-image-$kernel_release" "$image_name"
cp "$release_dir/$image_name" "$release_dir/$signed_name"
printf '%s\n' "$kernel_release" > "$release_dir/kernel-release.txt"
printf '%s\n' "$local_version" > "$release_dir/local-version.txt"
printf '%s\n' "$source_version" > "$release_dir/ubuntu-source-package-version.txt"

manifest_tool="$mock_repo/scripts/release-manifest.py"
"$manifest_tool" create "$release_dir" \
	--source-version "$source_version" \
	--kernel-release "$kernel_release" \
	--release-tag "$release_tag" \
	--git-commit "$git_commit" \
	--private-key "$temp_dir/test.priv" >/dev/null
"$manifest_tool" verify "$release_dir" \
	--expected-release-tag "$release_tag" \
	--expected-git-commit "$git_commit" \
	--minimum-source-version "$source_version" >/dev/null

assert_rejected() {
	local label=$1
	shift
	if "$@" >/dev/null 2>&1; then
		printf 'Accepted %s.\n' "$label" >&2
		exit 1
	fi
}

cp -a "$release_dir" "$temp_dir/tampered-manifest"
printf ' ' >> "$temp_dir/tampered-manifest/release-manifest.json"
assert_rejected 'a tampered Manifest' \
	"$manifest_tool" verify "$temp_dir/tampered-manifest"

cp "$mock_repo/certs/secure-hibernate-project.pem" "$temp_dir/correct.pem"
openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
	-subj '/CN=Wrong Release Manifest Test/' \
	-keyout "$temp_dir/wrong.priv" \
	-out "$mock_repo/certs/secure-hibernate-project.pem" >/dev/null 2>&1
chmod 0600 "$temp_dir/wrong.priv"
assert_rejected 'a Manifest under the wrong pinned certificate' \
	"$manifest_tool" verify "$release_dir"
mv "$temp_dir/correct.pem" "$mock_repo/certs/secure-hibernate-project.pem"

cp -a "$release_dir" "$temp_dir/missing-signature"
rm "$temp_dir/missing-signature/release-manifest.p7s"
assert_rejected 'a Release with a missing detached signature' \
	"$manifest_tool" verify "$temp_dir/missing-signature"

cp -a "$release_dir" "$temp_dir/missing-asset"
rm "$temp_dir/missing-asset/$headers_name"
assert_rejected 'a Release with a missing asset' \
	"$manifest_tool" verify "$temp_dir/missing-asset"

cp -a "$release_dir" "$temp_dir/extra-asset"
printf 'extra\n' > "$temp_dir/extra-asset/extra.txt"
assert_rejected 'a Release with an extra asset' \
	"$manifest_tool" verify "$temp_dir/extra-asset"

cp -a "$release_dir" "$temp_dir/symlink-asset"
mv "$temp_dir/symlink-asset/$headers_name" \
	"$temp_dir/symlink-asset/headers-target"
ln -s headers-target "$temp_dir/symlink-asset/$headers_name"
assert_rejected 'a symbolic-link Release asset' \
	"$manifest_tool" verify "$temp_dir/symlink-asset"

cp -a "$release_dir" "$temp_dir/size-mismatch"
printf 'extra\n' >> "$temp_dir/size-mismatch/$image_name"
assert_rejected 'a Release asset with a size mismatch' \
	"$manifest_tool" verify "$temp_dir/size-mismatch"

cp -a "$release_dir" "$temp_dir/hash-mismatch"
printf 'X' | dd of="$temp_dir/hash-mismatch/$image_name" \
	bs=1 seek=0 conv=notrunc status=none
assert_rejected 'a Release asset with a SHA-256 mismatch' \
	"$manifest_tool" verify "$temp_dir/hash-mismatch"

assert_rejected 'a downgraded Ubuntu source version' \
	"$manifest_tool" verify "$release_dir" \
	--minimum-source-version 7.0.0-30.30
assert_rejected 'an unexpected Release tag' \
	"$manifest_tool" verify "$release_dir" \
	--expected-release-tag ubuntu-7.0.0-30.30
assert_rejected 'an unexpected Git commit' \
	"$manifest_tool" verify "$release_dir" \
	--expected-git-commit fedcba9876543210fedcba9876543210fedcba98

cp -a "$release_dir" "$temp_dir/unsafe-create"
rm "$temp_dir/unsafe-create/release-manifest.json" \
	"$temp_dir/unsafe-create/release-manifest.p7s" \
	"$temp_dir/unsafe-create/SHA256SUMS"
printf 'unsafe\n' > "$temp_dir/unsafe-create/bad name"
assert_rejected 'an unsafe Release asset filename' \
	"$manifest_tool" create "$temp_dir/unsafe-create" \
	--source-version "$source_version" \
	--kernel-release "$kernel_release" \
	--release-tag "$release_tag" \
	--git-commit "$git_commit" \
	--private-key "$temp_dir/test.priv"

cp -a "$release_dir" "$temp_dir/wrong-key-create"
rm "$temp_dir/wrong-key-create/release-manifest.json" \
	"$temp_dir/wrong-key-create/release-manifest.p7s" \
	"$temp_dir/wrong-key-create/SHA256SUMS"
assert_rejected 'a Manifest signed by a key that does not match the certificate' \
	"$manifest_tool" create "$temp_dir/wrong-key-create" \
	--source-version "$source_version" \
	--kernel-release "$kernel_release" \
	--release-tag "$release_tag" \
	--git-commit "$git_commit" \
	--private-key "$temp_dir/wrong.priv"
for partial_file in SHA256SUMS release-manifest.json release-manifest.p7s; do
	if [[ -e $temp_dir/wrong-key-create/$partial_file ]]; then
		printf 'Failed Manifest creation left partial metadata: %s\n' \
			"$partial_file" >&2
		exit 1
	fi
done

printf 'release manifest tests passed\n'
