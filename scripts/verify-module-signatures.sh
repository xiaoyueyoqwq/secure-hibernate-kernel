#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'Usage: verify-module-signatures.sh CERTIFICATE MODULE...\n'
}

if [[ $# -lt 2 ]]; then
	usage >&2
	exit 2
fi

certificate=$(realpath "$1")
shift
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
extractor="$repo_root/scripts/extract-module-signature.pl"

for command in mktemp openssl perl realpath xz zstd; do
	command -v "$command" >/dev/null || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done
[[ -f $certificate ]] || {
	printf 'Certificate does not exist: %s\n' "$certificate" >&2
	exit 1
}
[[ -x $extractor ]] || {
	printf 'Module signature extractor is missing or not executable: %s\n' \
		"$extractor" >&2
	exit 1
}
openssl x509 -in "$certificate" -noout >/dev/null

temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

for module in "$@"; do
	module=$(realpath "$module")
	case $module in
		*.ko)
			uncompressed_module=$module
			;;
		*.ko.xz)
			uncompressed_module="$temp_dir/module.ko"
			xz --decompress --stdout "$module" > "$uncompressed_module"
			;;
		*.ko.zst)
			uncompressed_module="$temp_dir/module.ko"
			zstd --decompress --stdout --quiet "$module" > "$uncompressed_module"
			;;
		*)
			printf 'Unsupported module compression: %s\n' "$module" >&2
			exit 1
			;;
	esac

	if ! perl "$extractor" "$uncompressed_module" \
		"$temp_dir/module.content" "$temp_dir/module.p7s"; then
		printf 'Unable to extract module signature: %s\n' "$module" >&2
		exit 1
	fi
	if ! openssl cms -verify -binary -inform DER \
		-in "$temp_dir/module.p7s" \
		-content "$temp_dir/module.content" \
		-nointern -certfile "$certificate" \
		-CAfile "$certificate" -no-CApath -no-CAstore \
		-purpose any -out /dev/null 2> "$temp_dir/openssl-error"; then
		printf 'Cryptographic module signature verification failed: %s\n' \
			"$module" >&2
		cat "$temp_dir/openssl-error" >&2
		exit 1
	fi
done
