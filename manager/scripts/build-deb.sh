#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
flutter_root=$(cd "$script_dir/.." && pwd)
repo_root=$(cd "$flutter_root/.." && pwd)

package_name=secure-hibernate-manager
application_id=io.github.xiaoyueyoqwq.secure-hibernate-manager
architecture=amd64
app_root=/opt/$package_name

for command in flutter dpkg-deb install cp find mktemp rm sed head chmod; do
	command -v "$command" >/dev/null || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done

version=$(sed -n 's/^version:[[:space:]]*//p' "$flutter_root/pubspec.yaml" | head -n 1)
if [[ ! $version =~ ^[0-9]+([.][0-9]+)*([+~-][0-9A-Za-z.+~-]+)?$ ]]; then
	printf 'Invalid Flutter package version: %s\n' "$version" >&2
	exit 1
fi
if [[ ! -f $flutter_root/pubspec.lock || ! -f $flutter_root/.dart_tool/package_config.json ]]; then
	printf 'Flutter dependencies are unresolved; run flutter pub get first.\n' >&2
	exit 1
fi

output_dir=${OUTPUT_DIR:-$flutter_root/dist}
artifact="$output_dir/${package_name}_${version}_${architecture}.deb"
build_root=$(mktemp -d "${TMPDIR:-/tmp}/secure-hibernate-manager-deb.XXXXXX")
cleanup() {
	rm -rf "$build_root"
}
trap cleanup EXIT

printf 'Building Flutter Linux release bundle...\n'
(
	cd "$flutter_root"
	flutter build linux --release --no-pub \
		--dart-define="MANAGER_VERSION=$version"
)

bundle="$flutter_root/build/linux/x64/release/bundle"
for required in "$bundle/secure-hibernate-manager" "$bundle/data" "$bundle/lib" \
	"$flutter_root/linux/resources/$application_id.desktop" \
	"$flutter_root/linux/resources/app-icon.png"; do
	[[ -e $required ]] || {
		printf 'Flutter build output is missing: %s\n' "$required" >&2
		exit 1
	}
done

package_root="$build_root/package"
install -d -m 0755 \
	"$package_root/DEBIAN" \
	"$package_root$app_root" \
	"$package_root$app_root/resources/backend/scripts" \
	"$package_root$app_root/resources/backend/certs" \
	"$package_root$app_root/resources/backend/config" \
	"$package_root$app_root/resources/licenses" \
	"$package_root/usr/bin" \
	"$package_root/usr/share/applications" \
	"$package_root/usr/share/icons/hicolor/256x256/apps"

# Keep the runtime bundle independent from the build tree and its CMake files.
install -m 0755 "$bundle/secure-hibernate-manager" "$package_root$app_root/secure-hibernate-manager"
cp -a "$bundle/data" "$package_root$app_root/"
cp -a "$bundle/lib" "$package_root$app_root/"
install -m 0644 "$flutter_root/linux/resources/app-icon.png" "$package_root$app_root/app-icon.png"

ln -s "$app_root/secure-hibernate-manager" \
	"$package_root/usr/bin/secure-hibernate-manager"
install -m 0644 "$flutter_root/linux/resources/$application_id.desktop" \
	"$package_root/usr/share/applications/$application_id.desktop"
install -m 0644 "$flutter_root/linux/resources/app-icon.png" \
	"$package_root/usr/share/icons/hicolor/256x256/apps/$application_id.png"

# The controller installer derives its repository root from this backend tree.
# Copy only the reviewed public resources required by that installer.
scripts=(
	extract-module-signature.pl
	install-signed-packages.sh
	install-system-config.sh
	install-update-controller.sh
	manager-helper.py
	release-manifest.py
	resolve-version.sh
	set-default-kernel.sh
	update-local.py
	update-local.sh
	verify-module-signatures.sh
)
for script in "${scripts[@]}"; do
	install -m 0755 "$repo_root/scripts/$script" \
		"$package_root$app_root/resources/backend/scripts/$script"
done

if [[ -n $(find "$repo_root/config" -type l -print -quit) ]]; then
	printf 'Refusing symbolic links in the packaged configuration tree.\n' >&2
	exit 1
fi

for certificate in secure-hibernate-project.pem secure-hibernate-project.der; do
	install -m 0644 "$repo_root/certs/$certificate" \
		"$package_root$app_root/resources/backend/certs/$certificate"
done

cp -a "$repo_root/config/." "$package_root$app_root/resources/backend/config/"

# Working-tree group bits must not become writable package resources.
find "$package_root$app_root/resources/backend" -type d -exec chmod 0755 {} +
find "$package_root$app_root/resources/backend" -type f -exec chmod 0644 {} +
for script in "${scripts[@]}"; do
	chmod 0755 "$package_root$app_root/resources/backend/scripts/$script"
done

find "$package_root" -type d -exec chmod 0755 {} +

install -m 0644 "$repo_root/LICENSE" \
	"$package_root$app_root/resources/licenses/project-GPL-2.0.txt"
install -m 0644 "$flutter_root/assets/fonts/UFL.txt" \
	"$package_root$app_root/resources/licenses/Ubuntu-Font-Licence.txt"
install -m 0644 "$flutter_root/assets/licenses/Linux-Icon-CC0.txt" \
	"$package_root$app_root/resources/licenses/Linux-Icon-CC0.txt"
install -m 0644 "$flutter_root/assets/licenses/App-Icon-CC0.txt" \
	"$package_root$app_root/resources/licenses/App-Icon-CC0.txt"

cat >"$package_root/DEBIAN/control" <<EOF
Package: $package_name
Version: $version
Section: admin
Priority: optional
Architecture: $architecture
Maintainer: Secure Hibernate Kernel Project <xiaoyueyoqwq@users.noreply.github.com>
Depends: apt, cryptsetup-bin, dpkg, dracut-core, grub2-common, kmod, libgtk-3-0t64 | libgtk-3-0, libtss2-tcti-device0t64 | libtss2-tcti-device0, mokutil, openssl, passwd, perl, pkexec, polkitd, psmisc, python3, sbsigntool, systemd, systemd-cryptsetup, tpm-udev, tpm2-tools, util-linux, xz-utils, zstd
Description: Secure Hibernate Manager
 Flutter desktop manager for the signed Secure Hibernate project kernel.
 The package includes the reviewed local update controller and its public
 configuration resources. Kernel installation and other privileged actions
 remain guarded by the installed root-owned helper and Polkit.
EOF

cat >"$package_root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = configure ]; then
    /opt/secure-hibernate-manager/resources/backend/scripts/install-update-controller.sh
fi

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
EOF
chmod 0755 "$package_root/DEBIAN/postinst"

mkdir -p "$output_dir"
rm -f "$artifact"
dpkg-deb --build --root-owner-group "$package_root" "$artifact" >/dev/null
printf 'Built: %s\n' "$artifact"
