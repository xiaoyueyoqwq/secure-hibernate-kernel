#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

sign_file=$("$repo_root/scripts/resolve-sign-file.sh")
printf '#!/usr/bin/env bash\nexit 99\n' > "$temp_dir/sign-file"
chmod 0755 "$temp_dir/sign-file"
if "$repo_root/scripts/resolve-sign-file.sh" "$temp_dir/sign-file" \
	>/dev/null 2>&1; then
	printf 'Accepted an untrusted signing helper.\n' >&2
	exit 1
fi

openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
	-subj '/CN=Module signature regression test/' \
	-keyout "$temp_dir/test.priv" -out "$temp_dir/test.pem" >/dev/null 2>&1
chmod 0600 "$temp_dir/test.priv"
printf 'module signature regression fixture\n' > "$temp_dir/test.ko"
"$sign_file" sha256 "$temp_dir/test.priv" "$temp_dir/test.pem" \
	"$temp_dir/test.ko"

"$repo_root/scripts/verify-module-signatures.sh" \
	"$temp_dir/test.pem" "$temp_dir/test.ko"
cp "$temp_dir/test.ko" "$temp_dir/test-xz.ko"
cp "$temp_dir/test.ko" "$temp_dir/test-zstd.ko"
xz --keep "$temp_dir/test-xz.ko"
zstd --quiet "$temp_dir/test-zstd.ko" -o "$temp_dir/test-zstd.ko.zst"
"$repo_root/scripts/verify-module-signatures.sh" \
	"$temp_dir/test.pem" \
	"$temp_dir/test-xz.ko.xz" "$temp_dir/test-zstd.ko.zst"

module_size=$(stat -c '%s' "$temp_dir/test.ko")
perl -e '
	use strict;
	use warnings;
	my ($path, $offset) = @ARGV;
	open my $file, "+<:raw", $path or die "$path: $!\n";
	seek $file, $offset, 0 or die "$path: $!\n";
	read($file, my $byte, 1) == 1 or die "$path: short read\n";
	seek $file, $offset, 0 or die "$path: $!\n";
	print {$file} chr(ord($byte) ^ 1) or die "$path: $!\n";
' "$temp_dir/test.ko" "$((module_size - 41))"

if "$repo_root/scripts/verify-module-signatures.sh" \
	"$temp_dir/test.pem" "$temp_dir/test.ko" >/dev/null 2>&1; then
	printf 'Accepted a module with a corrupted PKCS#7 signature.\n' >&2
	exit 1
fi

printf 'signing security tests passed\n'
