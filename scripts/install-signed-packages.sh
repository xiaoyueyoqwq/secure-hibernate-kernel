#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'Usage: install-signed-packages.sh [--check-only|--install-only] SIGNED_PACKAGE_DIR CERTIFICATE\n'
}

check_only=false
install_only=false
case ${1:-} in
	--check-only)
		check_only=true
		shift
		;;
	--install-only)
		install_only=true
		shift
		;;
esac
if [[ $# -ne 2 ]]; then
	usage >&2
	exit 2
fi
if ! $check_only && (( EUID != 0 )); then
	printf 'This script must run as root.\n' >&2
	exit 1
fi

signed_dir=$(realpath "$1")
certificate=$(realpath "$2")
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

required_commands=(dpkg-deb find realpath sbverify)
if ! $install_only; then
	required_commands+=(modinfo nproc openssl sed sort tr wc xargs)
fi
for command in "${required_commands[@]}"; do
	command -v "$command" >/dev/null || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done

mapfile -t image_packages < <(find "$signed_dir" -maxdepth 1 -type f \
	\( -name 'signed-linux-image-*-s4lockdown_*_amd64.deb' -o \
		-name 'signed-linux-image-*-hibernate_*_amd64.deb' \) -print)
if (( ${#image_packages[@]} != 1 )); then
	printf 'Expected exactly one signed hibernation image package in %s.\n' "$signed_dir" >&2
	exit 1
fi
image_package=${image_packages[0]}
package_name=$(dpkg-deb -f "$image_package" Package)
kernel_release=${package_name#linux-image-}
header_package="$signed_dir/$(find "$signed_dir" -maxdepth 1 -type f \
	-name "linux-headers-${kernel_release}_*_amd64.deb" -printf '%f\n' -quit)"
if [[ ! -f $header_package ]]; then
	printf 'Matching headers package is missing for %s.\n' "$kernel_release" >&2
	exit 1
fi

if ! $install_only; then
	module_verifier="$repo_root/scripts/verify-module-signatures.sh"
	[[ -x $module_verifier ]] || {
		printf 'Module signature verifier is missing: %s\n' "$module_verifier" >&2
		exit 1
	}
	verify_jobs=${MODULE_VERIFY_JOBS:-$(nproc)}
	if [[ ! $verify_jobs =~ ^[1-9][0-9]*$ ]]; then
		printf 'MODULE_VERIFY_JOBS must be a positive integer.\n' >&2
		exit 2
	fi
	if (( verify_jobs > 4 )); then
		verify_jobs=4
	fi
	expected_signer=$(openssl x509 -in "$certificate" -noout -subject \
		-nameopt sep_multiline | sed -n 's/^[[:space:]]*CN=//p')
	if [[ -z $expected_signer || $expected_signer == *$'\n'* ]]; then
		printf 'Certificate must contain exactly one common name (CN).\n' >&2
		exit 1
	fi
	expected_sig_key=$(openssl x509 -in "$certificate" -noout -serial | sed 's/^serial=//')
	expected_sig_key=${expected_sig_key//:/}
	expected_sig_key=${expected_sig_key,,}

	temp_dir=$(mktemp -d)
	trap 'rm -rf -- "$temp_dir"' EXIT
	dpkg-deb -x "$image_package" "$temp_dir/root"
	sbverify --cert "$certificate" "$temp_dir/root/boot/vmlinuz-$kernel_release"

	module_root="$temp_dir/root/lib/modules/$kernel_release"
	module_count=$(find "$module_root" -type f \
		\( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) -printf . | wc -c)
	if (( module_count == 0 )); then
		printf 'No modules found for %s.\n' "$kernel_release" >&2
		exit 1
	fi
	if ! find "$module_root" -type f \
		\( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) -print0 \
		| xargs -0 -r -n 32 -P "$verify_jobs" \
			"$module_verifier" "$certificate"; then
		printf 'One or more module signatures failed cryptographic verification.\n' >&2
		exit 1
	fi
	signer_file="$temp_dir/module-signers"
	sig_key_file="$temp_dir/module-sig-keys"
	find "$module_root" -type f \
		\( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) \
		-exec modinfo -F signer {} + > "$signer_file"
	find "$module_root" -type f \
		\( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) \
		-exec modinfo -F sig_key {} + | tr -d ':' | tr '[:upper:]' '[:lower:]' \
		> "$sig_key_file"
	signer_count=$(wc -l < "$signer_file")
	sig_key_count=$(wc -l < "$sig_key_file")
	mapfile -t module_signers < <(sort -u "$signer_file")
	mapfile -t module_sig_keys < <(sort -u "$sig_key_file")
	if (( signer_count != module_count )) ||
		(( sig_key_count != module_count )) ||
		(( ${#module_signers[@]} != 1 )) ||
		(( ${#module_sig_keys[@]} != 1 )) ||
		[[ ${module_signers[0]:-} != "$expected_signer" ]] ||
		[[ ${module_sig_keys[0]:-} != "$expected_sig_key" ]]; then
		printf 'Module signatures do not all match certificate %s.\n' \
			"$expected_signer" >&2
		exit 1
	fi

	if $check_only; then
		printf 'Cryptographically validated signed image, %d modules, and matching headers for %s\n' \
			"$module_count" "$kernel_release"
		exit 0
	fi
fi

dpkg --install "$header_package" "$image_package"
sbverify --cert "$certificate" "/boot/vmlinuz-$kernel_release"
"$repo_root/scripts/set-default-kernel.sh" "$kernel_release"

printf 'Installed and selected signed kernel %s\n' "$kernel_release"
