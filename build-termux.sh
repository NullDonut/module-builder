#!/usr/bin/env bash
# module-builder - Termux bootstrap
#
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

set -e

REPO_URL="${REPO_URL:-https://github.com/NullDonut/module-builder}"
REPO_DIR="${REPO_DIR:-module-builder}"
OUT_DIR="${OUT_DIR:-/sdcard/Download/module-builder}"
CONFIG_BACKUP="${OUT_DIR}/config.toml"

pr() { printf '\033[0;32m[+] %s\033[0m\n' "$1"; }
warn() { printf '\033[0;33m[!] %s\033[0m\n' "$1" >&2; }
ask() {
	local y
	for ((n = 0; n < 3; n++)); do
		pr "$1 [y/n]"
		if read -r y; then
			if [ "$y" = y ]; then
				return 0
			elif [ "$y" = n ]; then
				return 1
			fi
		fi
		pr "Asking again..."
	done
	return 1
}

# Apps are disabled by default so a fresh clone does not build everything.
disable_apps() {
	sed -i '/^enabled.*/d; /^\[.*\]/a enabled = false' "$1"
}

pr "Ask for storage permission"
until
	yes | termux-setup-storage >/dev/null 2>&1
	ls /sdcard >/dev/null 2>&1
do sleep 1; done

if [ ! -f ~/.module_builder_"$(date '+%Y%m')" ]; then
	pr "Setting up environment..."
	yes "" | pkg update -y
	yes "" | pkg upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
	pkg install -y git curl jq zip unzip openjdk-21 aapt2
	: >~/.module_builder_"$(date '+%Y%m')"
fi

mkdir -p "$OUT_DIR"

if [ -d "${REPO_DIR}/.git" ]; then
	pr "Checking for module-builder updates"
	if ! git -C "$REPO_DIR" fetch --depth 1; then
		warn "Could not fetch updates; using the current checkout."
	elif git -C "$REPO_DIR" status -uno | grep -q 'is behind'; then
		pr "module-builder is not synced with upstream."
		pr "Cloning module-builder. config.toml will be preserved."

		# Preserve the current checkout's config before replacing it.
		config_backup=$(mktemp)
		have_backup=false
		if [ -f "${REPO_DIR}/config.toml" ]; then
			cp -f "${REPO_DIR}/config.toml" "$config_backup"
			have_backup=true
		fi

		rm -rf "$REPO_DIR"
		git clone "$REPO_URL" --depth 1 "$REPO_DIR"

		if [ "$have_backup" = true ]; then
			cp -f "$config_backup" "${REPO_DIR}/config.toml"
		elif [ -f "$CONFIG_BACKUP" ]; then
			cp -f "$CONFIG_BACKUP" "${REPO_DIR}/config.toml"
		else
			disable_apps "${REPO_DIR}/config.toml"
		fi
		rm -f "$config_backup"
	fi
else
	if [ -e "$REPO_DIR" ]; then
		warn "'${REPO_DIR}' exists but is not a git checkout."
		warn "Move it away (or set REPO_DIR) and run this script again."
		exit 1
	fi

	pr "Cloning module-builder."

	# Keep a config.toml downloaded next to this script, if present.
	local_config=$(mktemp)
	have_local_config=false
	if [ -f config.toml ]; then
		cp -f config.toml "$local_config"
		have_local_config=true
	fi

	git clone "$REPO_URL" --depth 1 "$REPO_DIR"

	if [ "$have_local_config" = true ]; then
		cp -f "$local_config" "${REPO_DIR}/config.toml"
	elif [ -f "$CONFIG_BACKUP" ]; then
		cp -f "$CONFIG_BACKUP" "${REPO_DIR}/config.toml"
	else
		disable_apps "${REPO_DIR}/config.toml"
	fi
	rm -f "$local_config"
fi

cd "$REPO_DIR"

# Termux git builds can flag the checkout as "dubious ownership".
if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$(pwd -P)"; then
	git config --global --add safe.directory "$(pwd -P)" 2>/dev/null || :
fi

if ask "Open 'config.toml' to configure builds?
All apps are disabled by default, enable the ones you want first"; then
	am start -a android.intent.action.VIEW -d "file://$(pwd -P)/config.toml" -t text/plain || :
fi

start_build=true
if ! ask "Start building?"; then
	start_build=false
fi

# Keep a copy in Downloads so the configuration survives re-clones. Do this
# after the editor prompt so the saved copy includes the user's changes.
mkdir -p "$(dirname "$CONFIG_BACKUP")"
cp -f config.toml "$CONFIG_BACKUP" 2>/dev/null || :

if [ "$start_build" = false ]; then
	pr "Cancelled."
	exit 0
fi

./build.sh

if [ ! -d build ] || [ -z "$(ls -A1 build 2>/dev/null || :)" ]; then
	warn "No build outputs were produced."
	exit 1
fi

for op in build/*; do
	[ -e "$op" ] || continue
	mv -f "$op" "$OUT_DIR/"
done

pr "Outputs are available in ${OUT_DIR}"
am start -a android.intent.action.VIEW -d "file://${OUT_DIR}" -t resource/folder || :
