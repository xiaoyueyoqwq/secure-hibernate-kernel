#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: build-kernel.sh SOURCE_PACKAGE_VERSION [LOCAL_VERSION|auto] [OUTPUT_DIR]

Example:
  scripts/build-kernel.sh 7.0.0-28.28 auto "$PWD/dist"
EOF
}

if [[ $# -lt 1 || $# -gt 3 ]]; then
	usage >&2
	exit 2
fi

source_package_version=$1
local_version=${2:-auto}
output_dir=${3:-"$PWD/dist"}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=${WORK_DIR:-"$repo_root/work"}

if [[ $source_package_version =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)\.[0-9]+([.+~][0-9A-Za-z.+~-]+)?$ ]]; then
	source_name=${BASH_REMATCH[1]}
	abi_number=${BASH_REMATCH[2]}
else
	printf 'Unsupported Ubuntu kernel package version: %s\n' "$source_package_version" >&2
	exit 2
fi

abi_version="${source_name}-${abi_number}"

if [[ $local_version == auto ]]; then
	local_version="-${abi_number}-hibernate"
fi

if [[ ! $local_version =~ ^-[a-zA-Z0-9][a-zA-Z0-9.+~-]*$ ]]; then
	printf 'LOCAL_VERSION must begin with "-" and contain package-safe characters.\n' >&2
	exit 2
fi

for command in apt-get dpkg-deb find gawk make patch tar; do
	command -v "$command" >/dev/null || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done

source_package="linux-source-$source_name"
config_package="linux-headers-${abi_version}-generic"

rm -rf "$work_dir"
mkdir -p "$work_dir/downloads" "$work_dir/source-package" \
	"$work_dir/config-package" "$output_dir"

(
	cd "$work_dir/downloads"
	apt-get download "${source_package}=${source_package_version}"
	apt-get download "${config_package}=${source_package_version}"
)

source_deb=$(find "$work_dir/downloads" -maxdepth 1 -type f \
	-name "${source_package}_*.deb" -print -quit)
config_deb=$(find "$work_dir/downloads" -maxdepth 1 -type f \
	-name "${config_package}_*.deb" -print -quit)

if [[ -z $source_deb || -z $config_deb ]]; then
	printf 'Could not resolve the requested source or config package.\n' >&2
	exit 1
fi

dpkg-deb -x "$source_deb" "$work_dir/source-package"
dpkg-deb -x "$config_deb" "$work_dir/config-package"

source_archive=$(find "$work_dir/source-package/usr/src" -type f \
	-name "linux-source-${source_name}.tar.*" -print -quit)
base_config="$work_dir/config-package/usr/src/linux-headers-${abi_version}-generic/.config"

if [[ -z $source_archive || ! -f $base_config ]]; then
	printf 'The Ubuntu packages do not contain the expected source archive or config.\n' >&2
	exit 1
fi

tar -xf "$source_archive" -C "$work_dir"
source_tree="$work_dir/linux-source-$source_name"

patch -d "$source_tree" -p1 --forward \
	< "$repo_root/patches/0001-power-hibernate-allow-lockdown-opt-in.patch"
cp "$base_config" "$source_tree/.config"

"$source_tree/scripts/config" --file "$source_tree/.config" \
	--set-str LOCALVERSION "$local_version" \
	--disable LOCALVERSION_AUTO \
	--enable HIBERNATION_ALLOW_LOCKDOWN \
	--set-str SYSTEM_TRUSTED_KEYS "" \
	--set-str SYSTEM_REVOCATION_KEYS ""

make -C "$source_tree" olddefconfig

export KBUILD_BUILD_USER=github-actions
export KBUILD_BUILD_HOST=github.com
export KDEB_CHANGELOG_DIST=ubuntu
export KDEB_PKGVERSION="1${local_version}+ubuntu${source_package_version}"
export DEB_BUILD_PROFILES=pkg.linux-upstream.nokerneldbg

make -C "$source_tree" -j"${JOBS:-$(nproc)}" bindeb-pkg

find "$work_dir" -maxdepth 1 -type f \
		\( -name 'linux-headers-*.deb' -o \
			\( -name 'linux-image-*.deb' ! -name '*-dbg_*' \) \) \
		-exec cp -v {} "$output_dir/" \;

kernel_release=$(make -s -C "$source_tree" kernelrelease)
printf '%s\n' "$kernel_release" > "$output_dir/kernel-release.txt"
printf '%s\n' "$source_package_version" > "$output_dir/ubuntu-source-package-version.txt"
printf '%s\n' "$local_version" > "$output_dir/local-version.txt"

if ! find "$output_dir" -maxdepth 1 -type f -name 'linux-image-*.deb' -print -quit | grep -q .; then
	printf 'The build completed without producing a linux-image package.\n' >&2
	exit 1
fi

printf 'Build artifacts are in %s\n' "$output_dir"
