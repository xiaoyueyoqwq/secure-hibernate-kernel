#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: sign-packages.sh ARTIFACT_DIR PRIVATE_KEY CERTIFICATE [OUTPUT_DIR]

Signs the PE kernel image and every loadable module in each linux-image .deb.
The private key remains local and is never required by GitHub Actions.
EOF
}

if [[ $# -lt 3 || $# -gt 4 ]]; then
	usage >&2
	exit 2
fi

artifact_dir=$(realpath "$1")
private_key=$(realpath "$2")
certificate=$(realpath "$3")
output_dir=${4:-"$artifact_dir/signed"}
sign_file="$artifact_dir/sign-file"

for command in dpkg-deb find md5sum openssl realpath sbsign xz zstd; do
	command -v "$command" >/dev/null || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done

[[ -x $sign_file ]] || {
	printf 'Missing executable signing helper: %s\n' "$sign_file" >&2
	exit 1
}

[[ -f $private_key && -f $certificate ]] || {
	printf 'The private key or certificate does not exist.\n' >&2
	exit 1
}

key_mode=$(stat -c '%a' "$private_key")
if (( (8#$key_mode & 077) != 0 )); then
	printf 'Refusing a private key readable by users other than its owner.\n' >&2
	exit 1
fi

mkdir -p "$output_dir"
mapfile -d '' image_packages < <(find "$artifact_dir" -maxdepth 1 -type f \
	-name 'linux-image-*.deb' ! -name '*dbg*' -print0)

if (( ${#image_packages[@]} == 0 )); then
	printf 'No linux-image package found in %s\n' "$artifact_dir" >&2
	exit 1
fi

sign_module() {
	local module=$1
	local unpacked

	case $module in
		*.ko)
			"$sign_file" sha256 "$private_key" "$certificate" "$module"
			;;
		*.ko.xz)
			unpacked=${module%.xz}
			xz --decompress --keep "$module"
			"$sign_file" sha256 "$private_key" "$certificate" "$unpacked"
			xz --force "$unpacked"
			;;
		*.ko.zst)
			unpacked=${module%.zst}
			zstd --decompress --keep --quiet "$module" -o "$unpacked"
			"$sign_file" sha256 "$private_key" "$certificate" "$unpacked"
			zstd --force --quiet "$unpacked" -o "$module"
			rm -f "$unpacked"
			;;
		*)
			printf 'Unsupported module compression: %s\n' "$module" >&2
			return 1
			;;
	esac
}

for package in "${image_packages[@]}"; do
	package_name=$(basename "$package")
	temp_dir=$(mktemp -d)
	trap 'rm -rf -- "$temp_dir"' EXIT
	package_root="$temp_dir/root"
	dpkg-deb -R "$package" "$package_root"

	while IFS= read -r -d '' module; do
		sign_module "$module"
	done < <(find "$package_root/lib/modules" -type f \
		\( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' \) -print0)

	while IFS= read -r -d '' kernel; do
		signed_kernel="$kernel.signed"
		sbsign --key "$private_key" --cert "$certificate" \
			--output "$signed_kernel" "$kernel"
		mv "$signed_kernel" "$kernel"
	done < <(find "$package_root/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -print0)

	(
		cd "$package_root"
		find . -type f ! -path './DEBIAN/*' -printf '%P\0' \
			| sort -z | xargs -0 md5sum > DEBIAN/md5sums
	)

	dpkg-deb --build --root-owner-group "$package_root" \
		"$output_dir/signed-$package_name"
	rm -rf "$temp_dir"
	trap - EXIT
done

for package in "$artifact_dir"/linux-headers-*.deb; do
	[[ -e $package ]] || continue
	cp -v "$package" "$output_dir/"
done

openssl x509 -in "$certificate" -noout -fingerprint -sha256
printf 'Signed packages are in %s\n' "$output_dir"
