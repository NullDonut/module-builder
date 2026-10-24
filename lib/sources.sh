#!/usr/bin/env bash
# module-builder - download source registry
#
# A source is a small shell file in sources/ (or plugins/sources/) that sets
#   SOURCE_NAME=<name>
#   SOURCE_PRIORITY=<number>            # optional, lower runs first
#   SOURCE_ALIAS_LIST="alias ..."        # optional
# and implements:
#   source_<name>_resp <url>          # fetch metadata into __SOURCE_* globals
#   source_<name>_pkg_name            # print package name
#   source_<name>_versions            # print one version per line
#   source_<name>_download <url> <version> <output> <arch> <dpi>
#
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck shell=bash

DEFAULT_SOURCE_LIST=()

load_sources() {
	local file base name order alias
	local -a resolved=()

	DL_SRCS=()
	unset SOURCE_FILE_MAP SOURCE_PRIORITY_MAP SOURCE_ALIAS_MAP
	declare -gA SOURCE_FILE_MAP=()
	declare -gA SOURCE_PRIORITY_MAP=()
	declare -gA SOURCE_ALIAS_MAP=()

	for file in "$SOURCES_DIR"/*.sh "$PLUGIN_DIR"/sources/*.sh; do
		[ -f "$file" ] || continue
		unset SOURCE_NAME SOURCE_PRIORITY SOURCE_ALIAS_LIST
		# shellcheck disable=SC1090
		. "$file" || abort "Could not load source plugin '$file'"
		name=${SOURCE_NAME:-$(basename "$file" .sh)}
		name=${name#*-}
		order=${SOURCE_PRIORITY:-100}
		if ! declare -F "source_${name}_resp" >/dev/null ||
			! declare -F "source_${name}_pkg_name" >/dev/null ||
			! declare -F "source_${name}_versions" >/dev/null ||
			! declare -F "source_${name}_download" >/dev/null; then
			abort "Source plugin '${file}' is missing one of: resp, pkg_name, versions, download"
		fi
		SOURCE_FILE_MAP["$name"]=$file
		SOURCE_PRIORITY_MAP["$name"]=$order
		for alias in ${SOURCE_ALIAS_LIST-}; do
			SOURCE_ALIAS_MAP["$alias"]=$name
		done
	done

	mapfile -t resolved < <(
		for name in "${!SOURCE_FILE_MAP[@]}"; do
			printf '%s %s\n' "${SOURCE_PRIORITY_MAP[$name]}" "$name"
		done | sort -n -k1,1 -k2,2 | awk '{print $2}'
	)
	DEFAULT_SOURCE_LIST=("${resolved[@]}")
	if [ "${#DEFAULT_SOURCE_LIST[@]}" -eq 0 ]; then
		abort "No download source plugins found in '${SOURCES_DIR}'"
	fi
}

source_canonical() {
	local name=$1
	if [ -n "${SOURCE_FILE_MAP[$name]+x}" ]; then
		printf '%s' "$name"
	elif [ -n "${SOURCE_ALIAS_MAP[$name]+x}" ]; then
		printf '%s' "${SOURCE_ALIAS_MAP[$name]}"
	else
		return 1
	fi
}

# Print the source names to try for an app, in priority order. Only sources
# with a configured <source>-dlurl are returned unless a source is explicitly
# named in download-sources.
source_names_for() {
	local table=$1 configured raw src url
	if configured=$(config_get_effective "$table" download-sources "" 2>/dev/null); then
		if [ -n "$configured" ]; then
			while IFS= read -r raw; do
				[ -n "$raw" ] || continue
				if ! src=$(source_canonical "$raw"); then
					abort "Unknown download source '${raw}' for '${table}'"
				fi
				printf '%s\n' "$src"
			done < <(split_list "$configured")
			return 0
		fi
	fi

	for src in "${DEFAULT_SOURCE_LIST[@]}"; do
		url=$(config_get_effective "$table" "${src}-dlurl" "")
		[ -n "$url" ] && printf '%s\n' "$src"
	done
}

source_has_url() {
	local table=$1 src=$2
	local url
	url=$(config_get_effective "$table" "${src}-dlurl" "")
	[ -n "$url" ]
}

source_url() {
	local table=$1 src=$2 url
	url=$(config_get_effective "$table" "${src}-dlurl" "")
	normalize_dlurl "$src" "$url"
}

normalize_dlurl() {
	local src=$1 url=$2
	url=${url%/}
	case "$src" in
	apkmirror | apkpure)
		url=${url%download}
		url=${url%/}
		;;
	esac
	printf '%s' "$url"
}

source_call() {
	local src=$1 action=$2
	shift 2
	local fn="source_${src}_${action}"
	if ! declare -F "$fn" >/dev/null; then
		epr "Source '${src}' does not implement '${action}'"
		return 1
	fi
	"$fn" "$@"
}

source_resp() {
	local src=$1
	shift
	source_call "$src" resp "$@"
}
source_pkg_name() {
	local src=$1
	shift
	source_call "$src" pkg_name "$@"
}
source_versions() {
	local src=$1
	shift
	source_call "$src" versions "$@"
}
source_download() {
	local src=$1
	shift
	source_call "$src" download "$@"
}

# Print a human-readable list of available sources and whether they are
# configured for an app.
source_report() {
	local table=$1 src url
	for src in "${DEFAULT_SOURCE_LIST[@]}"; do
		url=$(config_get_effective "$table" "${src}-dlurl" "" 2>/dev/null || :)
		if [ -n "$url" ]; then
			printf '    %-10s %s\n' "$src" "$url"
		else
			printf '    %-10s (not configured)\n' "$src"
		fi
	done
}
