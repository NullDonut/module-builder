#!/usr/bin/env bash
# module-builder - configuration loading, defaults, inheritance and validation
#
# Supports TOML (via the bundled `tq`) and JSON config files. The config format
# is backwards compatible with revanced-morphe-builder's config.toml.
#
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck shell=bash

CFG_FILE=""
CFG_JSON=""
CFG_MAIN_JSON=""
CFG_TABLES=()

config_load() {
	local file=$1 ext

	if [ ! -f "$file" ]; then
		epr "Config file not found: '$file'"
		return 1
	fi
	ext=${file##*.}
	case "$ext" in
	toml)
		if [ -z "${TOML_BIN-}" ]; then
			epr "No TOML parser found (expected bin/toml/tq-* or tq on PATH)"
			return 1
		fi
		if ! CFG_JSON=$("$TOML_BIN" --output json --file "$file" . 2>/dev/null); then
			epr "Could not parse TOML config '$file'"
			return 1
		fi
		;;
	json)
		if ! CFG_JSON=$(jq -c . "$file" 2>/dev/null); then
			epr "Could not parse JSON config '$file'"
			return 1
		fi
		;;
	*)
		epr "Unsupported config extension '${ext}' (use .toml or .json)"
		return 1
		;;
	esac

	if ! jq -e 'type == "object"' <<<"$CFG_JSON" >/dev/null 2>&1; then
		epr "Config root must be a table/object"
		return 1
	fi

	CFG_FILE=$file
	CFG_JSON=$(jq -c . <<<"$CFG_JSON")
	CFG_MAIN_JSON=$(jq -c 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$CFG_JSON")
	mapfile -t CFG_TABLES < <(jq -r 'to_entries[] | select(.value | type == "object") | .key' <<<"$CFG_JSON")
	return 0
}

config_table_exists() {
	jq -e --arg t "$1" '.[$t] | type == "object"' <<<"$CFG_JSON" >/dev/null 2>&1
}

# Read a scalar from the raw app table (no inheritance) or from main.
config_get_raw() {
	local table=${1-} key=$2 obj
	if [ -n "$table" ]; then
		obj=$(jq -c --arg t "$table" '.[$t] // {}' <<<"$CFG_JSON") || return 1
	else
		obj=$CFG_MAIN_JSON
	fi
	jq -er --arg k "$key" '
		.[$k]
		| select(. != null)
		| if type == "string" or type == "number" or type == "boolean" then tostring else empty end
	' <<<"$obj"
}

# Resolve inheritance for a table (deep merge: parents first, child wins).
# Arguments: <table> [stack]
config_resolve_table() {
	local table=$1 stack=${2-}
	local parents parent merged='{}' own pj

	case " $stack " in
	*" $table "*) abort "Config inheritance cycle: ${stack} -> ${table}" ;;
	esac

	if ! config_table_exists "$table"; then
		abort "Config table '${table}' does not exist"
	fi

	if parents=$(config_get_raw "$table" inherits 2>/dev/null); then
		:
	elif parents=$(config_get_raw "$table" extends 2>/dev/null); then
		:
	else
		parents=""
	fi

	while IFS= read -r parent; do
		[ -n "$parent" ] || continue
		if ! config_table_exists "$parent"; then
			abort "Config table '${table}' inherits from unknown table '${parent}'"
		fi
		pj=$(config_resolve_table "$parent" "$stack $table") || return 1
		merged=$(jq -c --argjson p "$pj" '. * $p' <<<"$merged") || return 1
	done < <(split_list "$parents")

	own=$(jq -c --arg t "$table" '.[$t] // {}' <<<"$CFG_JSON") || return 1
	merged=$(jq -c --argjson o "$own" '. * $o' <<<"$merged") || return 1
	printf '%s' "$merged"
}

# Read a scalar from an app table after inheritance, or from main.
config_get() {
	local table=${1-} key=$2 obj
	if [ -n "$table" ]; then
		obj=$(config_resolve_table "$table") || return 1
	else
		obj=$CFG_MAIN_JSON
	fi
	jq -er --arg k "$key" '
		.[$k]
		| select(. != null)
		| if type == "string" or type == "number" or type == "boolean" then tostring else empty end
	' <<<"$obj"
}

# App value -> main value -> caller supplied default.
config_get_effective() {
	local table=$1 key=$2 default=${3-} out
	if out=$(config_get "$table" "$key"); then
		printf '%s\n' "$out"
		return 0
	fi
	if out=$(config_get "" "$key"); then
		printf '%s\n' "$out"
		return 0
	fi
	printf '%s\n' "$default"
}

config_bool() {
	local table=$1 key=$2 default=$3 out
	out=$(config_get_effective "$table" "$key" "$default")
	validate_bool "$out" "$key"
	printf '%s' "$out"
}

# Print one list item per line.
config_list() {
	local table=$1 key=$2 default=${3-}
	split_list "$(config_get_effective "$table" "$key" "$default")"
}

config_is_preset() {
	local table=$1 preset type
	if preset=$(config_get_raw "$table" preset 2>/dev/null); then
		[ "$preset" = "true" ] && return 0
	fi
	if type=$(config_get_raw "$table" type 2>/dev/null); then
		[ "$type" = "preset" ] && return 0
	fi
	return 1
}

# Print the table and all of its ancestors, one per line.
config_ancestors() {
	local table=$1 stack=${2-} parents parent
	case " $stack " in
	*" $table "*) return 0 ;;
	esac
	printf '%s\n' "$table"
	if parents=$(config_get_raw "$table" inherits 2>/dev/null); then
		:
	elif parents=$(config_get_raw "$table" extends 2>/dev/null); then
		:
	else
		return 0
	fi
	while IFS= read -r parent; do
		[ -n "$parent" ] || continue
		config_ancestors "$parent" "$stack $table"
	done < <(split_list "$parents")
}

# Emit a JSON config containing main keys plus the named tables.
config_to_json() {
	local keep_json
	if [ "$#" -eq 0 ]; then
		jq -c 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$CFG_JSON"
		return
	fi
	keep_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
	jq -c --argjson keep "$keep_json" '
		to_entries
		| map(select((.key as $k | $keep | index($k)) or (.value | type != "object")))
		| from_entries
	' <<<"$CFG_JSON"
}

config_validate_globals() {
	local compression parallel src
	compression=$(config_get_effective "" compression-level "9")
	if ! [[ $compression =~ ^[0-9]+$ ]] || ((compression > 9)); then
		abort "compression-level must be within 0-9 (got '${compression}')"
	fi
	parallel=$(config_get_effective "" parallel-jobs "1")
	if ! [[ $parallel =~ ^[0-9]+$ ]] || ((parallel < 1)); then
		abort "parallel-jobs must be a positive integer (got '${parallel}')"
	fi
	config_bool "" enable-module-update true >/dev/null
	config_bool "" remove-rv-integrations-checks true >/dev/null

	while IFS= read -r src; do
		[ -n "$src" ] || continue
		if [ -z "${SOURCE_FILE_MAP[$src]+x}" ]; then
			abort "Unknown download source '${src}' in download-sources"
		fi
	done < <(config_list "" download-sources "")
}

config_validate_table() {
	local table=$1 template hooks
	local build_mode include_stock arch version module_id enabled

	enabled=$(config_bool "$table" enabled true)
	if [ "$enabled" = false ]; then
		return 0
	fi

	build_mode=$(config_get_effective "$table" build-mode "apk")
	if ! isoneof "$build_mode" both apk module; then
		abort "ERROR: build-mode '${build_mode}' is not valid for '${table}': use 'both', 'apk' or 'module'"
	fi

	include_stock=$(config_get_effective "$table" include-stock "merged")
	if ! isoneof "$include_stock" disable merged split; then
		abort "ERROR: include-stock '${include_stock}' is not valid for '${table}': use 'disable', 'merged' or 'split'"
	fi

	arch=$(config_get_effective "$table" arch "all")
	if ! isoneof "$arch" both all arm64-v8a arm-v7a x86_64 x86; then
		abort "ERROR: arch '${arch}' is not valid for '${table}'"
	fi

	version=$(config_get_effective "$table" version "auto")
	if [ -z "$version" ]; then
		abort "ERROR: version must not be empty for '${table}'"
	fi

	config_bool "$table" exclusive-patches false >/dev/null
	config_bool "$table" enable-update-checks false >/dev/null
	config_bool "$table" enable-module-update true >/dev/null
	config_bool "$table" hooks-enabled true >/dev/null

	module_id=$(config_get_effective "$table" module-id \
		"$(config_get_effective "$table" module-prop-name "$(sanitize_name "$table")-shivanshbansal")")
	if ! [[ $module_id =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
		abort "ERROR: module-id/module-prop-name '${module_id}' is not valid for '${table}'"
	fi

	template=$(config_get_effective "$table" module-template "${MODULE_TEMPLATE_DIR}")
	if [ ! -d "$template" ]; then
		abort "ERROR: module-template '${template}' for '${table}' does not exist"
	fi

	while IFS= read -r hooks; do
		[ -n "$hooks" ] || continue
		if [ ! -f "$hooks" ] && [ ! -d "$hooks" ]; then
			abort "ERROR: hook '${hooks}' for '${table}' does not exist"
		fi
	done < <(config_list "$table" "extra-hooks" "")
}

config_validate_all() {
	local table
	config_validate_globals
	for table in "${CFG_TABLES[@]}"; do
		if config_is_preset "$table"; then
			continue
		fi
		config_validate_table "$table"
	done
}
