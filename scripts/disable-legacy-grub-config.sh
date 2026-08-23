#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'Usage: disable-legacy-grub-config.sh [--path PATH]\n' >&2
}

legacy_config=/etc/default/grub.d/99-z-s4lockdown-experiment.cfg
if [[ ${1:-} == --path && $# -eq 2 ]]; then
	legacy_config=$2
elif [[ $# -ne 0 ]]; then
	usage
	exit 2
fi

if [[ ! -e $legacy_config ]]; then
	exit 0
fi
if [[ -L $legacy_config || ! -f $legacy_config ]]; then
	printf 'Refusing to disable a non-regular legacy GRUB configuration: %s\n' \
		"$legacy_config" >&2
	exit 1
fi
if ! grep -Fq 'elan100k A/B experiment layout' "$legacy_config"; then
	printf 'Refusing to disable an unrecognized legacy GRUB configuration: %s\n' \
		"$legacy_config" >&2
	exit 1
fi

backup="${legacy_config}.disabled.$(date +%Y%m%d-%H%M%S)"
suffix=0
while [[ -e $backup ]]; do
	suffix=$((suffix + 1))
	backup="${legacy_config}.disabled.$(date +%Y%m%d-%H%M%S).$suffix"
done
mv -- "$legacy_config" "$backup"
printf 'Preserved and disabled the legacy GRUB experiment configuration as %s\n' \
	"$backup"
