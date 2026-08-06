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
	"$repo_root/scripts/patch-tags.sh" \
	"$repo_root/scripts/resolve-version.sh" "$mock_repo/scripts/"
chmod 0755 "$mock_repo/scripts/"*
# The installed controller carries an explicit empty patch set until the
# variant scenario below adds a source-style patches directory.
printf '\n' > "$mock_repo/patch-tags.txt"
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
if [[ ${1:-} != --install-only ]]; then
	printf 'Updater did not request the verified install-only path.\n' >&2
	exit 2
fi
printf 'install %s\n' "$2" >> "$S4LOCKDOWN_TEST_PACKAGE_LOG"
if [[ ${S4LOCKDOWN_TEST_INSTALL_FAIL:-0} == 1 ]]; then
	printf 'precise package configuration failure\n' >&2
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

cat > "$mock_bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -z ${S4LOCKDOWN_TEST_INSTALLED_SOURCE_VERSION:-} ]]; then
	exec /usr/bin/dpkg-query "$@"
fi
if [[ $* == *'${Version}'* ]]; then
	printf 'ii \tlinux-image-7.0.14-30-hibernate\t1-30-hibernate+ubuntu%s\n' \
		"$S4LOCKDOWN_TEST_INSTALLED_SOURCE_VERSION"
else
	printf 'linux-image-7.0.14-30-hibernate\tii \n'
fi
EOF
chmod 0755 "$mock_bin/dpkg-query"

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
	local release_tag=${5:-ubuntu-$source_version}
	local release_dir="$temp_dir/release-$source_version${release_tag#ubuntu-"$source_version"}"
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
		--release-tag "$release_tag" \
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
		S4LOCKDOWN_TEST_IGNORE_SYSTEM_PACKAGES="${S4LOCKDOWN_TEST_IGNORE_SYSTEM_PACKAGES:-1}" \
		S4LOCKDOWN_TEST_APT_VERSION="$expected_source_version" \
		S4LOCKDOWN_TEST_PACKAGE_TOOL="$package_tool" \
		S4LOCKDOWN_TEST_PACKAGE_LOG="$temp_dir/package.log" \
		"$mock_repo/scripts/update-local.py" "$@"
}

release_29=$(create_release \
	7.0.0-29.29 7.0.13-29-hibernate -29-hibernate \
	1111111111111111111111111111111111111111)
release_30=$(create_release \
	7.0.0-30.30 7.0.14-30-hibernate -30-hibernate \
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

run_update check --source-version 7.0.0-29.29 --source-dir "$release_29" \
	--installed-source-version 7.0.0-28.28 >/dev/null
[[ $(json_value "$test_root/var/cache/s4lockdown-update/check-state.json" status) == already-staged ]]
[[ -d $test_root/var/cache/s4lockdown-update/staged ]]

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
[[ $(json_value "$state_file" install_phase) == complete ]]
[[ $(json_value "$state_file" install_progress) == 100 ]]
[[ $(json_value "$state_file" installed_source_version) == 7.0.0-29.29 ]]
[[ -f $test_root/run/reboot-required ]]
grep -Fxq linux-image-7.0.13-29-hibernate \
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
[[ $(json_value "$state_file" install_phase) == failed ]]
[[ $(json_value "$state_file" install_progress) == 78 ]]
[[ $(json_value "$state_file" last_install_error) == \
	'precise package configuration failure' ]]
[[ $(json_value "$state_file" installed_source_version) == 7.0.0-29.29 ]]
[[ -d $test_root/var/lib/s4lockdown-update/available ]]

rm -rf -- "$test_root/var/lib/s4lockdown-update/available"
S4LOCKDOWN_TEST_IGNORE_SYSTEM_PACKAGES=0 \
	S4LOCKDOWN_TEST_INSTALLED_SOURCE_VERSION=7.0.0-30.30 \
	run_update check --force --source-version 7.0.0-30.30 \
		--source-dir "$release_30" >/dev/null
[[ $(json_value "$test_root/var/cache/s4lockdown-update/check-state.json" status) == verified ]]
[[ -d $test_root/var/cache/s4lockdown-update/staged ]]

S4LOCKDOWN_TEST_IGNORE_SYSTEM_PACKAGES=0 \
	S4LOCKDOWN_TEST_INSTALLED_SOURCE_VERSION=7.0.0-30.30 \
	run_update install >/dev/null
[[ $(json_value "$state_file" last_check_status) == installed-reboot-required ]]
[[ $(json_value "$state_file" install_phase) == complete ]]
[[ $(json_value "$state_file" installed_source_version) == 7.0.0-30.30 ]]
[[ -z $(json_value "$state_file" last_install_error) ]]
[[ ! -d $test_root/var/lib/s4lockdown-update/available ]]

printf 'POLICY=manual\n' > "$test_root/etc/s4lockdown-update.conf"
run_update check --source-version 7.0.0-30.30 --source-dir "$release_30" \
	--installed-source-version 7.0.0-29.29 >/dev/null
[[ $(json_value "$test_root/var/cache/s4lockdown-update/check-state.json" status) == manual ]]

empty_install_root="$temp_dir/empty-install-root"
mkdir -p "$empty_install_root/etc"
printf 'POLICY=automatic-install\n' > "$empty_install_root/etc/s4lockdown-update.conf"
set +e
S4LOCKDOWN_TEST_ROOT="$empty_install_root" \
	PATH="$mock_bin:$PATH" \
	S4LOCKDOWN_TEST_IGNORE_SYSTEM_PACKAGES=1 \
	S4LOCKDOWN_TEST_APT_VERSION=7.0.0-30.30 \
	S4LOCKDOWN_TEST_PACKAGE_TOOL="$package_tool" \
	S4LOCKDOWN_TEST_PACKAGE_LOG="$temp_dir/package.log" \
	"$mock_repo/scripts/update-local.py" install --force >/dev/null 2>&1
empty_install_status=$?
set -e
if (( empty_install_status == 0 )); then
	printf 'Updater accepted an installation without a verified Release.\n' >&2
	exit 1
fi
[[ $(json_value "$empty_install_root/var/lib/s4lockdown-update/state.json" install_phase) == failed ]]

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
mkdir -p "$state_failure_root/var/lib"
ln -s /proc "$state_failure_root/var/lib/s4lockdown-update"
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

printf 'local update controller tests passed\n'

# Same-source patch-variant Release: an installed base kernel must be
# offered the variant (e.g. -29-hibernate -> -29-vmstat-hibernate) even
# though the Ubuntu source version is unchanged.
variant_root="$temp_dir/variant-root"
mkdir -p "$variant_root/etc"
printf 'POLICY=automatic-install\n' > "$variant_root/etc/s4lockdown-update.conf"
run_update_root() {
	env \
		PATH="$mock_bin:$PATH" \
		S4LOCKDOWN_TEST_ROOT="$variant_root" \
		S4LOCKDOWN_TEST_IGNORE_SYSTEM_PACKAGES=1 \
		S4LOCKDOWN_TEST_APT_VERSION=7.0.0-29.29 \
		S4LOCKDOWN_TEST_PACKAGE_TOOL="$package_tool" \
		S4LOCKDOWN_TEST_PACKAGE_LOG="$temp_dir/package.log" \
		"$mock_repo/scripts/update-local.py" "$@"
}
run_update_root check --source-version 7.0.0-29.29 \
	--source-dir "$release_29" >/dev/null
run_update_root install >/dev/null
[[ $(json_value "$variant_root/var/lib/s4lockdown-update/state.json" \
	installed_kernel_release) == 7.0.13-29-hibernate ]]

# From here the mock repository declares the vmstat patch, so the
# resolver derives the variant Release tag and manifest validation
# accepts it.
mkdir -p "$mock_repo/patches"
: > "$mock_repo/patches/0001-hibernate-base.patch"
: > "$mock_repo/patches/0002-vmstat-fix-race.patch"
variant_dir=$(create_release \
	7.0.0-29.29 7.0.13-29-vmstat-hibernate -29-vmstat-hibernate \
	4444444444444444444444444444444444444444 \
	ubuntu-7.0.0-29.29-vmstat)

S4LOCKDOWN_TEST_ROOT="$variant_root" \
	PATH="$mock_bin:$PATH" \
	S4LOCKDOWN_TEST_IGNORE_SYSTEM_PACKAGES=1 \
	S4LOCKDOWN_TEST_APT_VERSION=7.0.0-29.29 \
	S4LOCKDOWN_TEST_PACKAGE_TOOL="$package_tool" \
	S4LOCKDOWN_TEST_PACKAGE_LOG="$temp_dir/package.log" \
	S4LOCKDOWN_TEST_VARIANT_RELEASE="$variant_dir" \
	"$mock_repo/scripts/update-local.py" check \
	--source-version 7.0.0-29.29 --source-dir "$variant_dir" >/dev/null
[[ $(json_value "$variant_root/var/cache/s4lockdown-update/check-state.json" \
	status) == verified ]]
[[ $(json_value "$variant_root/var/cache/s4lockdown-update/check-state.json" \
	release_tag) == ubuntu-7.0.0-29.29-vmstat ]]

run_update_root install >/dev/null
[[ $(json_value "$variant_root/var/lib/s4lockdown-update/state.json" \
	installed_kernel_release) == 7.0.13-29-vmstat-hibernate ]]
[[ $(json_value "$variant_root/var/lib/s4lockdown-update/state.json" \
	installed_source_version) == 7.0.0-29.29 ]]

# Without a variant Release the same installed base kernel is current.
run_update_root check --source-version 7.0.0-29.29 \
	--source-dir "$release_29" >/dev/null
[[ $(json_value "$variant_root/var/cache/s4lockdown-update/check-state.json" \
	status) == current ]]

printf 'variant Release tests passed\n'
