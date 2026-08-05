#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
dev_script=$repo_root/manager/scripts/dev.sh
application_id=io.github.xiaoyueyoqwq.secure-hibernate-manager
temporary_root=$(mktemp -d)

cleanup() {
	rm -rf -- "$temporary_root"
}
trap cleanup EXIT

unprivileged_uid=$(id -u nobody 2>/dev/null || printf '65534\n')
unprivileged_gid=$(id -g nobody 2>/dev/null || printf '65534\n')

run_dev_script() {
	if (( EUID == 0 )); then
		# Container checks run as root, but dev.sh requires the desktop user.
		setpriv --reuid="$unprivileged_uid" --regid="$unprivileged_gid" \
			--clear-groups -- "$@"
	else
		"$@"
	fi
}

fake_bin=$temporary_root/bin
data_root=$temporary_root/data
applications_directory=$data_root/applications
icon_directory=$data_root/icons/hicolor/256x256/apps
mkdir -p -- "$fake_bin" "$applications_directory" "$icon_directory"
if (( EUID == 0 )); then
	chmod 0777 "$temporary_root"
	chmod -R a+rwX "$fake_bin" "$data_root"
fi

cat >"$fake_bin/flutter" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$PWD" >"$FLUTTER_TEST_RESULT"
printf '%s\n' "$@" >>"$FLUTTER_TEST_RESULT"
EOF
chmod 0755 "$fake_bin/flutter"

desktop_target=$applications_directory/$application_id.desktop
icon_target=$icon_directory/$application_id.png
cat >"$desktop_target" <<'EOF'
[Desktop Entry]
X-SecureHibernate-Development=true
X-SecureHibernate-FlutterDevelopment=true
EOF
cp -- "$repo_root/manager/linux/resources/app-icon.png" "$icon_target"

result=$temporary_root/flutter-result
run_dev_script env PATH=$fake_bin:/usr/bin:/bin XDG_DATA_HOME=$data_root \
	FLUTTER_TEST_RESULT=$result "$dev_script"

[[ ! -e $desktop_target ]]
[[ ! -e $icon_target ]]
mapfile -t invocation <"$result"
[[ ${invocation[0]} == "$repo_root/manager" ]]
[[ ${invocation[1]} == run ]]
[[ ${invocation[2]} == -d ]]
[[ ${invocation[3]} == linux ]]

printf '%s\n' '[Desktop Entry]' 'Name=User override' >"$desktop_target"
run_dev_script env PATH=$fake_bin:/usr/bin:/bin XDG_DATA_HOME=$data_root \
	FLUTTER_TEST_RESULT=$result "$dev_script" 2>"$temporary_root/warning"

[[ -f $desktop_target ]]
grep -Fq 'preserving unrecognized user desktop entry' "$temporary_root/warning"

if grep -Eq 'mv -f|install -m 0644|> *"*\$desktop_target' "$dev_script"; then
	printf 'Development script must not install a desktop entry.\n' >&2
	exit 1
fi

printf 'Manager development launcher checks passed.\n'
