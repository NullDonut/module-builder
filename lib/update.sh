#!/usr/bin/env bash
# module-builder - CI config update
#
# Prints a JSON config to stdout when a configured patches/CLI release is not
# present in build.md (the previous release log). Prints nothing when a rebuild
# is unnecessary. Diagnostics go to stderr.
#
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck shell=bash

declare -A __UPDATE_ASSET_CACHE=()

# Print the normalised asset name for a release.
release_asset_name() {
	local kind=$1 src=$2 ver=$3
	local cache_key="${kind}:${src}:${ver}"
	local rv_rel resp tag_name asset name ext

	if [ -n "${__UPDATE_ASSET_CACHE[$cache_key]+x}" ]; then
		printf '%s' "${__UPDATE_ASSET_CACHE[$cache_key]}"
		return 0
	fi

	rv_rel="https://api.github.com/repos/${src}/releases"
	if [ "$ver" = "dev" ]; then
		resp=$(gh_req "$rv_rel" -) || return 1
		ver=$(jq -e -r '.[] | .tag_name' <<<"$resp" | get_highest_ver) || return 1
	fi
	if [ "$ver" = "latest" ]; then
		rv_rel+="/latest"
	else
		rv_rel+="/tags/${ver}"
	fi

	resp=$(gh_req "$rv_rel" -) || return 1
	tag_name=$(jq -er '.tag_name' <<<"$resp") || return 1

	# Pick a single non-checksum asset. Prefer a non-dev asset if the release
	# contains several.
	asset=$(jq -r '
		.assets
		| map(select(.name | (endswith("asc") or endswith("json")) | not))
		| (map(select(.name | contains("-dev") | not)) | if length == 1 then . else empty end)
		// .
		| .[0].name // empty
	' <<<"$resp")
	if [ -z "$asset" ]; then
		epr "No asset found for ${src}/${ver}"
		return 1
	fi

	if [ "$kind" = "patches" ]; then
		ext=${asset##*.}
		name="patches-${tag_name#v}.${ext}"
	elif [ "$kind" = "cli" ]; then
		name=$asset
	else
		abort "Unsupported release kind '${kind}'"
	fi

	__UPDATE_ASSET_CACHE[$cache_key]=$name
	printf '%s' "$name"
}

config_update() {
	local table patches_src patches_ver cli_src cli_ver
	local patches_name cli_name patches_line cli_line
	local -a updated=() all=()

	if [ ! -f "$BUILD_LOG" ]; then
		epr "build.md is not available; cannot check for updates"
		return 1
	fi

	for table in "${CFG_TABLES[@]}"; do
		if config_is_preset "$table"; then
			continue
		fi
		if [ "$(config_bool "$table" enabled true)" = false ]; then
			continue
		fi

		patches_src=$(config_get_effective "$table" patches-source "${DEF_PATCHES_SRC:-ReVanced/revanced-patches}")
		patches_ver=$(config_get_effective "$table" patches-version "${DEF_PATCHES_VER:-latest}")
		cli_src=$(config_get_effective "$table" cli-source "${DEF_CLI_SRC:-ReVanced/revanced-cli}")
		cli_ver=$(config_get_effective "$table" cli-version "${DEF_CLI_VER:-latest}")

		if ! patches_name=$(release_asset_name patches "$patches_src" "$patches_ver"); then
			wpr "Could not resolve patches release for '${table}'"
			continue
		fi
		patches_line="Patches: ${patches_src}/${patches_name}"

		# CLI failures are non-fatal: the patches release is the primary
		# rebuild trigger, matching the original builder's behavior.
		if cli_name=$(release_asset_name cli "$cli_src" "$cli_ver" 2>/dev/null); then
			cli_line="CLI: ${cli_src}/${cli_name}"
		else
			cli_line=""
		fi

		if ! grep -qFx -- "$patches_line" "$BUILD_LOG"; then
			updated+=("$table")
		elif [ -n "$cli_line" ] && ! grep -qFx -- "$cli_line" "$BUILD_LOG"; then
			updated+=("$table")
		fi
	done

	if [ "${#updated[@]}" -eq 0 ]; then
		return 0
	fi

	# Include inherited presets so the generated config remains self-contained.
	for table in "${updated[@]}"; do
		while IFS= read -r parent; do
			[ -n "$parent" ] || continue
			all+=("$parent")
		done < <(config_ancestors "$table")
	done
	all+=("${updated[@]}")

	mapfile -t all < <(printf '%s\n' "${all[@]}" | awk 'NF && !seen[$0]++')
	config_to_json "${all[@]}"
}
