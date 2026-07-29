#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
decision="$repo_root/scripts/release-decision.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT
assets="$temp_dir/assets"

: > "$assets"
[[ $("$decision" schedule false "$assets") == build=true ]]

cat > "$assets" <<'EOF'
SHA256SUMS
kernel-release.txt
local-version.txt
ubuntu-source-package-version.txt
secure-hibernate-project.der
secure-hibernate-project.pem
linux-headers-test_amd64.deb
linux-image-test_amd64.deb
signed-linux-image-test_amd64.deb
release-manifest.json
release-manifest.p7s
EOF
[[ $("$decision" schedule true "$assets" ubuntu-7.0.0-29.29) == build=false ]]
if "$decision" workflow_dispatch true "$assets" >/dev/null 2>&1; then
	printf 'Manual dispatch accepted an existing complete Release.\n' >&2
	exit 1
fi

sed -i '/release-manifest/d' "$assets"
if "$decision" schedule true "$assets" ubuntu-7.0.0-29.29 >/dev/null 2>&1; then
	printf 'Accepted a new Release without a signed Manifest.\n' >&2
	exit 1
fi
[[ $("$decision" schedule true "$assets" ubuntu-7.0.0-28.28) == build=false ]]

sed -i '/signed-linux-image/d' "$assets"
if "$decision" schedule true "$assets" >/dev/null 2>&1; then
	printf 'Scheduled build accepted an incomplete existing Release.\n' >&2
	exit 1
fi

printf 'release decision tests passed\n'
