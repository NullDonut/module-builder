#!/usr/bin/env bash
# module-builder - build hooks
#
# Hooks are optional trusted shell scripts. They can live in:
#   hooks/<phase>.d/*.sh
#   plugins/hooks/<phase>.d/*.sh
# or be named per app with the <phase>-hook config key.
#
# Phases: pre-build, post-patch, post-module
#
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck shell=bash

run_hook_file() {
	local hook=$1
	[ -f "$hook" ] || abort "Hook not found: '${hook}'"
	[ -x "$hook" ] || chmod +x "$hook" 2>/dev/null || :
	pr "Running hook: ${hook}"
	if ! bash "$hook"; then
		abort "Hook failed: ${hook}"
	fi
}

run_hook_dir() {
	local dir=$1 file
	[ -d "$dir" ] || return 0
	for file in "$dir"/*.sh; do
		[ -f "$file" ] || continue
		run_hook_file "$file"
	done
}

# Arguments:
#   $1 phase (pre-build|post-patch|post-module)
#   $2 table
#   $3 app name
#   $4 package name
#   $5 version
#   $6 arch
#   $7 build mode
#   $8 stock apk
#   $9 patched apk
#   ${10} module dir
#   ${11} module zip
#   ${12} module id
#   ${13} rv brand
#   ${14} patcher args
run_hooks() {
	local phase=$1 table=$2 app_name=$3 pkg_name=$4 version=$5 arch=$6
	local build_mode=$7 stock_apk=$8 patched_apk=$9 module_dir=${10-}
	local module_zip=${11-} module_id=${12-} rv_brand=${13-} patcher_args=${14-}
	local hook

	if [ "$(config_bool "$table" hooks-enabled "${HOOKS_ENABLED:-true}")" != "true" ]; then
		return 0
	fi

	export MB_PROJECT_ROOT="$MB_ROOT"
	export MB_CONFIG_FILE="$CFG_FILE"
	export MB_PHASE="$phase"
	export MB_TABLE="$table"
	export MB_APP_NAME="$app_name"
	export MB_PKG_NAME="$pkg_name"
	export MB_VERSION="$version"
	export MB_ARCH="$arch"
	export MB_BUILD_MODE="$build_mode"
	export MB_STOCK_APK="$stock_apk"
	export MB_PATCHED_APK="$patched_apk"
	export MB_MODULE_DIR="$module_dir"
	export MB_MODULE_ZIP="$module_zip"
	export MB_MODULE_ID="$module_id"
	export MB_RV_BRAND="$rv_brand"
	export MB_PATCHER_ARGS="$patcher_args"

	run_hook_dir "${HOOKS_DIR}/${phase}.d"
	run_hook_dir "${PLUGIN_DIR}/hooks/${phase}.d"

	while IFS= read -r hook; do
		[ -n "$hook" ] || continue
		run_hook_file "$hook"
	done < <(config_list "$table" "${phase}-hook" "")

	while IFS= read -r hook; do
		[ -n "$hook" ] || continue
		run_hook_file "$hook"
	done < <(config_list "$table" "extra-hooks" "")
}
