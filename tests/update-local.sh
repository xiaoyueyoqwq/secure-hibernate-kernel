#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT
mock_repo="$temp_dir/repo"
test_root="$temp_dir/root"
package_tool="$temp_dir/package-tool"
signing_key="$temp_dir/test.priv"
mock_bin="$temp_dir/bin"

for command in dpkg-deb flock openssl python3; do
	command -v "$command" >/dev/null || {
		printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	}
done

mkdir -p "$mock_repo/scripts" "$mock_repo/certs" "$test_root/etc" "$mock_bin"
cp "$repo_root/scripts/update-local.py" \
	"$repo_root/scripts/release-manifest.py" \
	"$repo_root/scripts/resolve-version.sh" "$mock_repo/scripts/"
chmod 0755 "$mock_repo/scripts/"*
openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
	-subj '/CN=Local Update Test/' \
	-addext 'basicConstraints=critical,CA:TRUE' \
	-addext 'keyUsage=critical,digitalSignature,keyCertSign' \
	-keyout "$signing_key" \
	-out "$mock_repo/certs/secure-hibernate-project.pem" >/dev/null 2>&1
chmod 0600 "$signing_key"

cat > "$package_tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --check-only ]]; then
	printf 'check %s\n' "$2" >> "$S4LOCKDOWN_TEST_PACKAGE_LOG"
	exit 0
fi
printf 'install %s\n' "$1" >> "$S4LOCKDOWN_TEST_PACKAGE_LOG"
if [[ ${S4LOCKDOWN_TEST_INSTALL_FAIL:-0} == 1 ]]; then
	exit 42
fi
EOF
chmod 0755 "$package_tool"

cat > "$mock_bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 || $1 != policy ]]; then
	printf 'Unexpected apt-cache invocation.\n' >&2
	exit 2
fi
printf '%s\n' \
	"$2:" \
	'  Installed: (none)' \
	"  Candidate: $S4LOCKDOWN_TEST_APT_VERSION"
EOF
chmod 0755 "$mock_bin/apt-cache"

build_package() {
	local release_dir=$1
	local package_name=$2
	local package_version=$3
	local output_name=$4
	local package_root

	package_root=$(mktemp -d "$temp_dir/package.XXXXXXXX")
	mkdir -p "$package_root/DEBIAN" "$package_root/usr/share/doc/$package_name"
	printf '%s\n' \
		"Package: $package_name" \
		"Version: $package_version" \
		'Architecture: amd64' \
		'Maintainer: Local Update Test <nobody@example.invalid>' \
		'Description: Minimal local updater regression fixture' \
		> "$package_root/DEBIAN/control"
	printf 'fixture\n' > "$package_root/usr/share/doc/$package_name/fixture"
	dpkg-deb --build --root-owner-group "$package_root" \
		"$release_dir/$output_name" >/dev/null
	rm -rf -- "$package_root"
}

create_release() {
	local source_version=$1
	local kernel_release=$2
	local local_version=$3
	local git_commit=$4
	local release_dir="$temp_dir/release-$source_version"
	local package_version="1${local_version}+ubuntu${source_version}"
	local headers_name image_name signed_name

	mkdir "$release_dir"
	headers_name="linux-headers-${kernel_release}_${package_version}_amd64.deb"
	image_name="linux-image-${kernel_release}_${package_version}_amd64.deb"
	signed_name="signed-linux-image-${kernel_release}_${package_version}_amd64.deb"
	build_package "$release_dir" "linux-headers-$kernel_release" \
		"$package_version" "$headers_name"
	build_package "$release_dir" "linux-image-$kernel_release" \
		"$package_version" "$image_name"
	cp "$release_dir/$image_name" "$release_dir/$signed_name"
	printf '%s\n' "$kernel_release" > "$release_dir/kernel-release.txt"
	printf '%s\n' "$local_version" > "$release_dir/local-version.txt"
	printf '%s\n' "$source_version" \
		> "$release_dir/ubuntu-source-package-version.txt"
	cp "$mock_repo/certs/secure-hibernate-project.pem" \
		"$release_dir/secure-hibernate-project.pem"
	openssl x509 -in "$mock_repo/certs/secure-hibernate-project.pem" \
		-outform DER -out "$release_dir/secure-hibernate-project.der"
	"$mock_repo/scripts/release-manifest.py" create "$release_dir" \
		--source-version "$source_version" \
		--kernel-release "$kernel_release" \
		--release-tag "ubuntu-$source_version" \
		--git-commit "$git_commit" \
		--private-key "$signing_key" >/dev/null
	printf '%s\n' "$release_dir"
}

json_value() {
	local path=$1
	local key=$2
	python3 - "$path" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source).get(sys.argv[2])
if value is not None:
    print(value)
PY
}

run_update() {
	env \
		PATH="$mock_bin:$PATH" \
		S4LOCKDOWN_TEST_ROOT="$test_root" \
		S4LOCKDOWN_TEST_APT_VERSION="$expected_source_version" \
		S4LOCKDOWN_TEST_PACKAGE_TOOL="$package_tool" \
		S4LOCKDOWN_TEST_PACKAGE_LOG="$temp_dir/package.log" \
		"$mock_repo/scripts/update-local.py" "$@"
}

release_29=$(create_release \
	7.0.0-29.29 7.0.13-ubuntu29-s4lockdown -ubuntu29-s4lockdown \
	1111111111111111111111111111111111111111)
release_30=$(create_release \
	7.0.0-30.30 7.0.14-ubuntu30-s4lockdown -ubuntu30-s4lockdown \
	2222222222222222222222222222222222222222)
expected_source_version=7.0.0-29.29

printf 'POLICY=check-and-notify\n' > "$test_root/etc/s4lockdown-update.conf"
mkdir -p \
	"$test_root/var/cache/s4lockdown-update/.incoming.interrupted" \
	"$test_root/var/cache/s4lockdown-update/.staged.retired.123" \
	"$test_root/var/lib/s4lockdown-update/.incoming.123" \
	"$test_root/var/lib/s4lockdown-update/.available.retired.123"
run_update check --source-version 7.0.0-29.29 --source-dir "$release_29" \
	--installed-source-version 7.0.0-28.28 >/dev/null
[[ $(json_value "$test_root/var/cache/s4lockdown-update/check-state.json" status) == verified ]]
[[ -d $test_root/var/cache/s4lockdown-update/staged ]]
[[ ! -e $test_root/var/cache/s4lockdown-update/.incoming.interrupted ]]
[[ ! -e $test_root/var/cache/s4lockdown-update/.staged.retired.123 ]]

staged_manifest="$test_root/var/cache/s4lockdown-update/staged/release-manifest.json"
manifest_hash=$(sha256sum "$staged_manifest" | awk '{ print $1 }')
exec 8<> "$staged_manifest"
run_update install >/dev/null
printf 'tamper through retained download descriptor\n' >&8
exec 8>&-
state_file="$test_root/var/lib/s4lockdown-update/state.json"
[[ $(json_value "$state_file" last_check_status) == update-available ]]
[[ $(json_value "$state_file" available_source_version) == 7.0.0-29.29 ]]
[[ -d $test_root/var/lib/s4lockdown-update/available ]]
[[ $(sha256sum "$test_root/var/lib/s4lockdown-update/available/release-manifest.json" \
	| awk '{ print $1 }') == "$manifest_hash" ]]
[[ ! -e $test_root/var/lib/s4lockdown-update/.incoming.123 ]]
[[ ! -e $test_root/var/lib/s4lockdown-update/.available.retired.123 ]]
if grep -q '^install ' "$temp_dir/package.log"; then
	printf 'check-and-notify policy invoked the installer.\n' >&2
	exit 1
fi

printf 'POLICY=automatic-install\n' > "$test_root/etc/s4lockdown-update.conf"
run_update install >/dev/null
[[ $(json_value "$state_file" last_check_status) == installed-reboot-required ]]
[[ $(json_value "$state_file" installed_source_version) == 7.0.0-29.29 ]]
[[ -f $test_root/run/reboot-required ]]
grep -Fxq linux-image-7.0.13-ubuntu29-s4lockdown \
	"$test_root/run/reboot-required.pkgs"
grep -q '^install ' "$temp_dir/package.log"
[[ ! -d $test_root/var/lib/s4lockdown-update/available ]]

run_update check --source-version 7.0.0-29.29 --source-dir "$release_29" \
	--installed-source-version 7.0.0-29.29 >/dev/null
[[ $(json_value "$test_root/var/cache/s4lockdown-update/check-state.json" status) == current ]]
[[ ! -d $test_root/var/cache/s4lockdown-update/staged ]]

run_update check --source-version 7.0.0-28.28 --source-dir "$release_29" \
	--installed-source-version 7.0.0-29.29 >/dev/null
[[ $(json_value "$test_root/var/cache/s4lockdown-update/check-state.json" status) == downgrade-refused ]]
[[ ! -d $test_root/var/cache/s4lockdown-update/staged ]]

cache_dir="$test_root/var/cache/s4lockdown-update"
exec 9> "$cache_dir/update.lock"
flock -n 9
set +e
run_update check --source-version 7.0.0-30.30 --source-dir "$release_30" \
	--installed-source-version 7.0.0-29.29 >/dev/null 2>&1
lock_status=$?
set -e
flock -u 9
exec 9>&-
if (( lock_status != 75 )); then
	printf 'Concurrent updater did not return temporary-failure status 75.\n' >&2
	exit 1
fi

run_update check --source-version 7.0.0-30.30 --source-dir "$release_30" \
	--installed-source-version 7.0.0-29.29 >/dev/null
expected_source_version=7.0.0-29.29
install_count_before=$(grep -c '^install ' "$temp_dir/package.log")
set +e
run_update install >/dev/null 2>&1
candidate_mismatch_status=$?
set -e
install_count_after=$(grep -c '^install ' "$temp_dir/package.log")
if (( candidate_mismatch_status == 0 || install_count_after != install_count_before )); then
	printf 'Root updater accepted a Release other than the current HWE candidate.\n' >&2
	exit 1
fi
[[ ! -d $test_root/var/cache/s4lockdown-update/staged ]]

expected_source_version=7.0.0-30.30
run_update check --source-version 7.0.0-30.30 --source-dir "$release_30" \
	--installed-source-version 7.0.0-29.29 >/dev/null
S4LOCKDOWN_TEST_DPKG_BUSY=1 run_update install >/dev/null
[[ $(json_value "$state_file" last_check_status) == package-manager-busy ]]
[[ $(json_value "$state_file" installed_source_version) == 7.0.0-29.29 ]]

set +e
S4LOCKDOWN_TEST_INSTALL_FAIL=1 run_update install >/dev/null 2>&1
install_status=$?
set -e
if (( install_status == 0 )); then
	printf 'Updater accepted a simulated package installation failure.\n' >&2
	exit 1
fi
[[ $(json_value "$state_file" last_check_status) == install-failed ]]
[[ $(json_value "$state_file" installed_source_version) == 7.0.0-29.29 ]]
[[ -d $test_root/var/lib/s4lockdown-update/available ]]

printf 'POLICY=manual\n' > "$test_root/etc/s4lockdown-update.conf"
run_update check --source-version 7.0.0-30.30 --source-dir "$release_30" \
	--installed-source-version 7.0.0-29.29 >/dev/null
[[ $(json_value "$test_root/var/cache/s4lockdown-update/check-state.json" status) == manual ]]

state_failure_root="$temp_dir/state-failure-root"
mkdir -p "$state_failure_root/etc"
printf 'POLICY=automatic-install\n' \
	> "$state_failure_root/etc/s4lockdown-update.conf"
S4LOCKDOWN_TEST_ROOT="$state_failure_root" \
	PATH="$mock_bin:$PATH" \
	S4LOCKDOWN_TEST_APT_VERSION=7.0.0-30.30 \
	S4LOCKDOWN_TEST_PACKAGE_TOOL="$package_tool" \
	S4LOCKDOWN_TEST_PACKAGE_LOG="$temp_dir/package.log" \
	"$mock_repo/scripts/update-local.py" check \
	--source-version 7.0.0-30.30 --source-dir "$release_30" \
	--installed-source-version 7.0.0-29.29 >/dev/null
mkdir -p "$state_failure_root/var/lib/s4lockdown-update"
chmod 0555 "$state_failure_root/var/lib/s4lockdown-update"
install_count_before=$(grep -c '^install ' "$temp_dir/package.log")
set +e
S4LOCKDOWN_TEST_ROOT="$state_failure_root" \
	PATH="$mock_bin:$PATH" \
	S4LOCKDOWN_TEST_APT_VERSION=7.0.0-30.30 \
	S4LOCKDOWN_TEST_PACKAGE_TOOL="$package_tool" \
	S4LOCKDOWN_TEST_PACKAGE_LOG="$temp_dir/package.log" \
	"$mock_repo/scripts/update-local.py" install >/dev/null 2>&1
state_failure_status=$?
set -e
install_count_after=$(grep -c '^install ' "$temp_dir/package.log")
if (( state_failure_status == 0 || install_count_after != install_count_before )); then
	printf 'State-directory failure did not stop before package installation.\n' >&2
	exit 1
fi
chmod 0755 "$state_failure_root/var/lib/s4lockdown-update"

printf 'local update controller tests passed\n'
