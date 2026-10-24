#!/usr/bin/env bash
# module-builder - entry point
#
# Builds patched APKs and flashable Magisk/KernelSU modules from a TOML/JSON
# config. Inspired by revanced-morphe-builder.
#
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
shopt -s nullglob

MB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$MB_ROOT"

# shellcheck source=lib/core.sh
source lib/core.sh
# shellcheck source=lib/config.sh
source lib/config.sh
# shellcheck source=lib/net.sh
source lib/net.sh
# shellcheck source=lib/sources.sh
source lib/sources.sh
# shellcheck source=lib/hooks.sh
source lib/hooks.sh
# shellcheck source=lib/module.sh
source lib/module.sh
# shellcheck source=lib/apk.sh
source lib/apk.sh
# shellcheck source=lib/update.sh
source lib/update.sh

usage() {
	cat <<EOF
module-builder - build patched APKs and Magisk/KernelSU modules

Usage:
  ./build.sh [config.toml|config.json] [options]
  ./build.sh clean

Options:
  --app <table>          Build only this app table (may be repeated)
  --jobs <n>             Override parallel-jobs
  --check, --validate    Validate the config and print the build plan
  --list                 Print effective settings for every app
  --dry-run              Print the plan without downloading or patching
  --config-update        Print a JSON config when patches/CLI changed
  --no-hooks             Disable all build hooks
  --verbose              Verbose command output
  -h, --help             Show this help

Examples:
  ./build.sh
  ./build.sh config.toml --check
  ./build.sh --app YouTube-Morphe --verbose
  ./build.sh config.toml --config-update > config.json
EOF
}

# ---------------------------------------------------------------------------
# Command-line parsing
# ---------------------------------------------------------------------------

CONFIG_FILE=""
MODE=build
APPS=()
JOBS_OVERRIDE=""
DRY_RUN=false

while [ "$#" -gt 0 ]; do
	case "$1" in
	clean)
		MODE=clean
		shift
		;;
	--config-update)
		MODE=config-update
		shift
		;;
	--check | --validate)
		MODE=check
		shift
		;;
	--list)
		MODE=list
		shift
		;;
	--app)
		[ "$#" -ge 2 ] || abort "--app requires a table name"
		APPS+=("$2")
		shift 2
		;;
	--jobs)
		[ "$#" -ge 2 ] || abort "--jobs requires a number"
		JOBS_OVERRIDE=$2
		shift 2
		;;
	--dry-run)
		DRY_RUN=true
		shift
		;;
	--no-hooks)
		HOOKS_ENABLED=false
		shift
		;;
	--verbose)
		MB_VERBOSE=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--*)
		abort "Unknown option '${1}' (try --help)"
		;;
	*)
		if [ -z "$CONFIG_FILE" ]; then
			CONFIG_FILE=$1
			shift
		else
			abort "Only one config file may be specified"
		fi
		;;
	esac
done

if [ "$MODE" = clean ]; then
	rm -rf "$TEMP_DIR" "$BUILD_DIR" "$BUILD_LOG"
	pr "Cleaned '${TEMP_DIR}', '${BUILD_DIR}' and '${BUILD_LOG}'"
	exit 0
fi

CONFIG_FILE=${CONFIG_FILE:-config.toml}

require_cmd jq "install it with 'pkg install jq' or equivalent"
require_cmd java "install a JDK with 'pkg install openjdk-21' or equivalent"
require_cmd zip "install it with 'pkg install zip' or equivalent"
require_cmd unzip "install it with 'pkg install unzip' or equivalent"
require_cmd curl "install it with 'pkg install curl' or equivalent"

detect_tools

if ! config_load "$CONFIG_FILE"; then
	abort "Could not load config '${CONFIG_FILE}'"
fi
load_sources
config_validate_all

# ---------------------------------------------------------------------------
# Global defaults
# ---------------------------------------------------------------------------

apply_global_config() {
	COMPRESSION_LEVEL=$(config_get_effective "" compression-level "9")
	PARALLEL_JOBS=$(config_get_effective "" parallel-jobs "1")
	REMOVE_RV_INTEGRATIONS_CHECKS=$(config_bool "" remove-rv-integrations-checks true)
	DEF_PATCHES_VER=$(config_get_effective "" patches-version "latest")
	DEF_CLI_VER=$(config_get_effective "" cli-version "latest")
	DEF_PATCHES_SRC=$(config_get_effective "" patches-source "ReVanced/revanced-patches")
	DEF_CLI_SRC=$(config_get_effective "" cli-source "ReVanced/revanced-cli")
	DEF_RV_BRAND=$(config_get_effective "" rv-brand "ReVanced")
	ENABLE_MODULE_UPDATE=$(config_bool "" enable-module-update true)
	HOOKS_ENABLED=$(config_bool "" hooks-enabled "${HOOKS_ENABLED:-true}")
	VERIFY_SIGNATURE=$(config_bool "" verify-signature true)

	SIGNING_KEYSTORE=$(config_get_effective "" keystore "ks.keystore")
	SIGNING_KEYSTORE_PASSWORD=$(config_get_effective "" keystore-password "123456789")
	SIGNING_ENTRY_PASSWORD=$(config_get_effective "" keystore-entry-password "$SIGNING_KEYSTORE_PASSWORD")
	SIGNING_SIGNER=$(config_get_effective "" signer "jhc")
	SIGNING_ENTRY_ALIAS=$(config_get_effective "" keystore-entry-alias "jhc")

	MERGE_KEYSTORE=$(config_get_effective "" merge-keystore "ks-p12.keystore")
	MERGE_KEYSTORE_PASSWORD=$(config_get_effective "" merge-keystore-password "123456789")
	MERGE_KEY_PASSWORD=$(config_get_effective "" merge-key-password "123456789")
	MERGE_KEY_ALIAS=$(config_get_effective "" merge-keystore-alias "jhc")

	APK_NAME_FORMAT=$(config_get_effective "" apk-name-format "{app}-{brand}-v{version}-{arch}.apk")
	MODULE_NAME_FORMAT=$(config_get_effective "" module-name-format "{app}-{brand}-module-v{version}-{arch}.zip")

	if [ -n "$JOBS_OVERRIDE" ]; then
		PARALLEL_JOBS=$JOBS_OVERRIDE
	fi
	if ! [[ $PARALLEL_JOBS =~ ^[0-9]+$ ]] || ((PARALLEL_JOBS < 1)); then
		abort "parallel-jobs must be a positive integer (got '${PARALLEL_JOBS}')"
	fi

	if [ "$ENABLE_MODULE_UPDATE" = true ] && [ -z "${GITHUB_REPOSITORY-}" ]; then
		wpr "Building locally. Module updates will not be enabled."
		ENABLE_MODULE_UPDATE=false
	fi
}

apply_global_config

# ---------------------------------------------------------------------------
# Helpers for inspection modes
# ---------------------------------------------------------------------------

app_selected() {
	local table=$1 app
	if [ "${#APPS[@]}" -eq 0 ]; then
		return 0
	fi
	for app in "${APPS[@]}"; do
		[ "$app" = "$table" ] && return 0
	done
	return 1
}

validate_app_selection() {
	local app table found
	for app in "${APPS[@]}"; do
		found=false
		for table in "${CFG_TABLES[@]}"; do
			[ "$table" = "$app" ] && found=true && break
		done
		if [ "$found" = false ]; then
			abort "No app table named '${app}'"
		fi
	done
}

print_sources_for() {
	local table=$1 src url
	while IFS= read -r src; do
		[ -n "$src" ] || continue
		url=$(source_url "$table" "$src")
		printf '    %-10s %s\n' "$src" "${url:-(missing dlurl)}"
	done < <(source_names_for "$table")
}

print_app_summary() {
	local table=$1 enabled arch build_mode include_stock version rv_brand
	enabled=$(config_bool "$table" enabled true)
	arch=$(config_get_effective "$table" arch "all")
	build_mode=$(config_get_effective "$table" build-mode "apk")
	include_stock=$(config_get_effective "$table" include-stock "merged")
	version=$(config_get_effective "$table" version "auto")
	rv_brand=$(config_get_effective "$table" rv-brand "$DEF_RV_BRAND")

	printf '%s\n' "$table"
	printf '    app-name:      %s\n' "$(config_get_effective "$table" app-name "$table")"
	printf '    enabled:       %s\n' "$enabled"
	printf '    build-mode:    %s\n' "$build_mode"
	printf '    arch:          %s\n' "$arch"
	printf '    version:       %s\n' "$version"
	printf '    rv-brand:      %s\n' "$rv_brand"
	printf '    include-stock: %s\n' "$include_stock"
	printf '    patches:       %s @ %s\n' \
		"$(config_get_effective "$table" patches-source "$DEF_PATCHES_SRC")" \
		"$(config_get_effective "$table" patches-version "$DEF_PATCHES_VER")"
	printf '    cli:           %s @ %s\n' \
		"$(config_get_effective "$table" cli-source "$DEF_CLI_SRC")" \
		"$(config_get_effective "$table" cli-version "$DEF_CLI_VER")"
	printf '    module-id:     %s\n' "$(module_id_base "$table")"
	printf '    sources:\n'
	print_sources_for "$table"
}

validate_app_selection

case "$MODE" in
check | list)
	pr "Config: ${CONFIG_FILE}"
	pr "Apps: ${#CFG_TABLES[@]} table(s)"
	for table in "${CFG_TABLES[@]}"; do
		if config_is_preset "$table"; then
			printf '%s [preset]\n' "$table"
			continue
		fi
		if ! app_selected "$table"; then
			continue
		fi
		if [ "$(config_bool "$table" enabled true)" = false ]; then
			printf '%s [disabled]\n' "$table"
			continue
		fi
		if [ "$MODE" = list ]; then
			print_app_summary "$table"
		else
			printf '%s: %s, arch=%s, mode=%s\n' "$table" \
				"$(config_get_effective "$table" app-name "$table")" \
				"$(config_get_effective "$table" arch "all")" \
				"$(config_get_effective "$table" build-mode "apk")"
			print_sources_for "$table"
		fi
	done
	exit 0
	;;
config-update)
	config_update
	exit 0
	;;
esac

# ---------------------------------------------------------------------------
# Build mode
# ---------------------------------------------------------------------------

mkdir -p "$TEMP_DIR" "$BUILD_DIR"

if [ "$VERIFY_SIGNATURE" = true ] && [ ! -f sig.txt ]; then
	wpr "sig.txt not found; signature verification will be skipped."
fi
if [ "${GITHUB_REPOSITORY-}" ] && [ ! -f "${SIGNING_KEYSTORE}" ]; then
	abort "Signing keystore '${SIGNING_KEYSTORE}' not found"
fi
if [ ! -f "${SIGNING_KEYSTORE}" ]; then
	wpr "Signing keystore '${SIGNING_KEYSTORE}' not found; patching will likely fail."
fi

build_job_specs() {
	local table enabled arch
	local -n out=$1
	out=()
	for table in "${CFG_TABLES[@]}"; do
		if config_is_preset "$table"; then continue; fi
		if ! app_selected "$table"; then continue; fi
		enabled=$(config_bool "$table" enabled true)
		if [ "$enabled" = false ]; then continue; fi
		arch=$(config_get_effective "$table" arch "all")

		if [ "$arch" = "both" ]; then
			local -A a1=([table]="$table" [arch]="arm64-v8a" [label]="${table} (arm64-v8a)")
			local -A a2=([table]="$table" [arch]="arm-v7a" [label]="${table} (arm-v7a)")
			out+=("$(declare -p a1)")
			out+=("$(declare -p a2)")
		else
			local -A a=([table]="$table" [arch]="$arch" [label]="$table")
			out+=("$(declare -p a)")
		fi
	done
}

validate_build_sources() {
	local table=$1 src url stock_apk found=false
	stock_apk=$(config_get_effective "$table" stock-apk "")
	if [ -n "$stock_apk" ]; then
		case "$stock_apk" in
		/*) : ;;
		*) stock_apk="${MB_ROOT}/${stock_apk}" ;;
		esac
		[ -f "$stock_apk" ] && return 0
	fi
	while IFS= read -r src; do
		[ -n "$src" ] || continue
		url=$(source_url "$table" "$src")
		[ -n "$url" ] && found=true
	done < <(source_names_for "$table")
	if [ "$found" = false ]; then
		epr "No download URL configured for '${table}'"
		return 1
	fi
	return 0
}

run_jobs() {
	local -a specs=("$@")
	local status_dir="${TEMP_DIR}/jobs"
	local spec status_file rc idx=0 running=0 success=0 skipped=0 failed=0
	local -a failures=()
	local finished

	rm -rf "$status_dir"
	mkdir -p "$status_dir"

	can_wait_n=false
	if ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))); then
		can_wait_n=true
	fi

	if [ "$PARALLEL_JOBS" -gt 1 ] && [ "$can_wait_n" = true ] && [ "${#specs[@]}" -gt 1 ]; then
		pr "Running up to ${PARALLEL_JOBS} build jobs in parallel"
		for spec in "${specs[@]}"; do
			status_file="${status_dir}/$((idx++)).status"
			printf '1\n' >"$status_file"
			(
				set +e
				build_variant "$spec"
				printf '%s\n' "$?" >"$status_file"
			) &
			running=$((running + 1))
			if ((running >= PARALLEL_JOBS)); then
				wait -n -p finished || true
				running=$((running - 1))
			fi
		done
		wait || true
	else
		for spec in "${specs[@]}"; do
			status_file="${status_dir}/$((idx++)).status"
			printf '1\n' >"$status_file"
			(
				set +e
				build_variant "$spec"
				printf '%s\n' "$?" >"$status_file"
			)
		done
	fi

	for status_file in "${status_dir}"/*.status; do
		[ -f "$status_file" ] || continue
		rc=$(cat "$status_file" 2>/dev/null || echo 1)
		case "$rc" in
		0) success=$((success + 1)) ;;
		2) skipped=$((skipped + 1)) ;;
		*) failed=$((failed + 1)) && failures+=("$(basename "$status_file")") ;;
		esac
	done

	if ((failed > 0)); then
		wpr "${failed} build job(s) failed."
	fi
	if ((skipped > 0)); then
		wpr "${skipped} build job(s) were skipped."
	fi
	dpr "jobs: success=${success} skipped=${skipped} failed=${failed}"
}

declare -a SPECS=()
build_job_specs SPECS

if [ "${#SPECS[@]}" -eq 0 ]; then
	abort "No enabled apps selected"
fi

declare -a VALID_SPECS=()
for spec in "${SPECS[@]}"; do
	eval "declare -A __spec=${spec#*=}"
	if validate_build_sources "${__spec[table]}"; then
		VALID_SPECS+=("$spec")
	fi
	unset __spec
done
if [ "${#VALID_SPECS[@]}" -eq 0 ]; then
	abort "No app has a usable download source"
fi

if [ "$DRY_RUN" = true ]; then
	for spec in "${VALID_SPECS[@]}"; do
		eval "declare -A __spec=${spec#*=}"
		printf '%s: arch=%s\n' "${__spec[label]}" "${__spec[arch]}"
		print_sources_for "${__spec[table]}"
		unset __spec
	done
	pr "Dry run complete; nothing was downloaded or patched."
	exit 0
fi

# Start from a clean output directory so stale artifacts from a previous run
# cannot make a failed build look successful.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
: >"$BUILD_LOG"

run_jobs "${VALID_SPECS[@]}"
_clean_tmp

if [ -z "$(ls -A1 "$BUILD_DIR" 2>/dev/null || :)" ]; then
	abort "All builds failed."
fi

log ""
log "Install [ReVanced GmsCore](https://github.com/ReVanced/GmsCore/releases/latest) or [Morphe MicroG-RE](https://github.com/MorpheApp/MicroG-RE/releases/latest) for non-root YouTube and YouTube Music APKs"
log "(Optional) Use [zygisk-detach](https://github.com/j-hc/zygisk-detach/releases/latest) to detach YouTube and YouTube Music modules from the Play Store"
log ""
log "Built by module-builder - by shivanshbansal (https://github.com/NullDonut)"

pr "Done"
