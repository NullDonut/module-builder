#!/usr/bin/env bash
# module-builder - core helpers and paths
#
# Inspired by revanced-morphe-builder by Peter Noël Muller.
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck shell=bash

# Project layout (all paths are absolute after this file is sourced).
MB_ROOT="${MB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CWD="$MB_ROOT"

TEMP_DIR="${TEMP_DIR:-temp}"
BUILD_DIR="${BUILD_DIR:-build}"
BIN_DIR="${BIN_DIR:-bin}"
MODULE_TEMPLATE_DIR="${MODULE_TEMPLATE_DIR:-module}"
SOURCES_DIR="${SOURCES_DIR:-sources}"
PLUGIN_DIR="${PLUGIN_DIR:-plugins}"
HOOKS_DIR="${HOOKS_DIR:-hooks}"
BUILD_LOG="${BUILD_LOG:-build.md}"

DL_SRCS=()
declare -A SOURCE_FILES=()
declare -A SOURCE_ORDER=()
declare -A SOURCE_ALIASES=()

OS=$(uname -o 2>/dev/null || uname -s)
MACHINE_ARCH=$(uname -m 2>/dev/null || :)

NEXT_VER_CODE="${NEXT_VER_CODE:-$(date +'%Y%m%d')}"

if [ -n "${GITHUB_TOKEN-}" ]; then
	GH_HEADER="Authorization: token ${GITHUB_TOKEN}"
else
	GH_HEADER=""
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

pr() { printf '\033[0;32m[+] %s\033[0m\n' "$1"; }
epr() {
	printf '\033[0;31m[-] %s\033[0m\n' "$1" >&2
	if [ -n "${GITHUB_REPOSITORY-}" ]; then
		printf '::error::module-builder [-] %s\n\n' "$1" >&2
	fi
}
wpr() {
	printf '\033[0;33m[!] %s\033[0m\n' "$1" >&2
	if [ -n "${GITHUB_REPOSITORY-}" ]; then
		printf '::warning::module-builder [!] %s\n\n' "$1" >&2
	fi
}
dpr() {
	if [ "${MB_VERBOSE:-false}" = true ]; then
		printf '\033[0;36m[.] %s\033[0m\n' "$1" >&2
	fi
}

# Append a line to the release/change log. Uses printf so patch names with
# backslashes are not mangled. Deduplicates identical lines.
log() {
	local line=$1
	if [ -f "$BUILD_LOG" ] && grep -qFx -- "$line" "$BUILD_LOG" 2>/dev/null; then
		return 0
	fi
	printf '%s\n' "$line" >>"$BUILD_LOG"
}

# ---------------------------------------------------------------------------
# Errors and clean-up
# ---------------------------------------------------------------------------

_clean_tmp() {
	rm -rf \
		"./${TEMP_DIR}"/*tmp.* \
		"./${TEMP_DIR}"/*tmp_* \
		"./${TEMP_DIR}"/*/*tmp.* \
		"./${TEMP_DIR}"/*-temporary-files \
		"./*-temporary-files" 2>/dev/null || :
}

abort() {
	epr "ABORT: ${1-}"
	_clean_tmp
	trap - SIGTERM SIGINT EXIT
	exit 1
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

isoneof() {
	local needle=$1 value
	shift
	for value in "$@"; do
		[ "$value" = "$needle" ] && return 0
	done
	return 1
}

trim() {
	local s=$1
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "$s"
}

# Lowercase and turn spaces into dashes. Keeps characters that are safe for
# filenames and module IDs.
sanitize_name() {
	local s=${1,,}
	s=${s// /-}
	s=${s//[^a-z0-9._-]/}
	printf '%s' "$s"
}

require_cmd() {
	local cmd=$1 hint=${2-}
	if ! command -v "$cmd" >/dev/null 2>&1; then
		abort "\`${cmd}\` is not installed.${hint:+ ${hint}}"
	fi
}

# Returns true when the value is a valid TOML-style boolean.
validate_bool() {
	local value=$1 name=${2:-value}
	if ! isoneof "$value" "true" "false"; then
		abort "ERROR: '${value}' is not a valid option for '${name}': only true or false is allowed"
	fi
}

# Print a value split into one line per item. Supports whitespace-separated
# values and simple TOML/JSON arrays such as ["a", "b"].
split_list() {
	local raw=$1 item
	raw=${raw#[}
	raw=${raw%]}
	raw=${raw//,/ }
	for item in $raw; do
		item=${item#\"}
		item=${item%\"}
		item=${item#\'}
		item=${item%\'}
		[ -n "$item" ] && printf '%s\n' "$item"
	done
}

# Turn a whitespace-separated list of quoted patch names into CLI arguments.
list_args() {
	tr -d '\t\r' <<<"$1" | tr -s ' ' | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :
}

join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }

# Quote a value for a POSIX-ish shell assignment.
sh_quote() {
	local v=$1
	printf "'%s'" "${v//\'/\'\\\'\'}"
}

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------

semver_validate() {
	local a="${1%-*}"
	a="${a#v}"
	local ac="${a//[.0-9]/}"
	[ ${#ac} = 0 ]
}

get_highest_ver() {
	local vers m
	vers=$(tee)
	m=$(head -1 <<<"$vers")
	if [ -z "$m" ]; then
		return 1
	fi
	if ! semver_validate "$m"; then
		echo "$m"
	else
		sort -s -t- -k1,1Vr <<<"$vers" | sed -n '1p'
	fi
}

# ---------------------------------------------------------------------------
# Toolchain detection
# ---------------------------------------------------------------------------

detect_tools() {
	local arch=$MACHINE_ARCH bin_arch
	case "$arch" in
	aarch64 | arm64) arch=arm64 ;;
	armv7* | armv8l) arch=arm ;;
	i?86) arch=x86 ;;
	x86_64 | amd64) arch=x64 ;;
	esac

	# The bundled binaries use different suffixes: arm/arm64 and x86_64
	# (not x64). Keep the x64 mapping for tools that may use it.
	bin_arch=$arch
	[ "$arch" = x64 ] && bin_arch=x86_64

	TOML_BIN="${BIN_DIR}/toml/tq-${bin_arch}"
	HTMLQ_BIN="${BIN_DIR}/htmlq/htmlq-${bin_arch}"
	AAPT2_BIN="${BIN_DIR}/aapt2/aapt2-${arch}"
	APKSIGNER_JAR="${BIN_DIR}/apksigner.jar"

	# Accept either suffix for locally renamed builds.
	if [ ! -x "$TOML_BIN" ] && [ -x "${BIN_DIR}/toml/tq-${arch}" ]; then
		TOML_BIN="${BIN_DIR}/toml/tq-${arch}"
	fi
	if [ ! -x "$HTMLQ_BIN" ] && [ -x "${BIN_DIR}/htmlq/htmlq-${arch}" ]; then
		HTMLQ_BIN="${BIN_DIR}/htmlq/htmlq-${arch}"
	fi
	if [ ! -x "$AAPT2_BIN" ] && [ -x "${BIN_DIR}/aapt2/aapt2-${bin_arch}" ]; then
		AAPT2_BIN="${BIN_DIR}/aapt2/aapt2-${bin_arch}"
	fi

	# Fall back to binaries on PATH when the bundled one is unavailable.
	if [ ! -x "$TOML_BIN" ]; then
		TOML_BIN=$(command -v tq || command -v tomlq || :)
	fi
	if [ ! -x "$HTMLQ_BIN" ]; then
		HTMLQ_BIN=$(command -v htmlq || :)
	fi
	if [ ! -x "$AAPT2_BIN" ]; then
		AAPT2_BIN=$(command -v aapt2 || :)
	fi

	if [ -n "${JAVA_HOME_25_X64-}" ]; then
		JAVA_CMD=(env -i "JAVA_HOME=${JAVA_HOME_25_X64}" "${JAVA_HOME_25_X64}/bin/java" --enable-native-access=ALL-UNNAMED)
	else
		JAVA_CMD=(java --enable-native-access=ALL-UNNAMED)
	fi

	dpr "tools: toml=${TOML_BIN:-missing} htmlq=${HTMLQ_BIN:-missing} aapt2=${AAPT2_BIN:-missing}"
}

java_cmd() { "${JAVA_CMD[@]}" "$@"; }

# ---------------------------------------------------------------------------
# Prebuilt CLI / patches configuration
# ---------------------------------------------------------------------------

# Resolve a prebuilt (patches or cli) JAR. Kept here because both the build and
# the config-update command need it.
#
# Arguments: <kind: patches|cli> <repo> <version>
# Prints the local path on stdout; diagnostics go to stderr.
resolve_prebuilt() {
	local kind=$1 src=$2 ver=${3-}
	local dir rv_rel name_ver resp tag_name asset name url file
	local cl_dir="${TEMP_DIR}/${src%/*}"
	cl_dir="${cl_dir,,}-rv"
	mkdir -p "$cl_dir"

	dir="${TEMP_DIR}/${src%/*}"
	dir="${dir,,}-rv"
	mkdir -p "$dir"

	rv_rel="https://api.github.com/repos/${src}/releases"
	if [ "$ver" = "dev" ]; then
		resp=$(gh_req "$rv_rel" -) || return 1
		ver=$(jq -e -r '.[] | .tag_name' <<<"$resp" | get_highest_ver) || return 1
	fi
	if [ "$ver" = "latest" ]; then
		rv_rel+="/latest"
		name_ver="*"
	else
		rv_rel+="/tags/${ver}"
		name_ver="$ver"
	fi

	if [ "$kind" = "cli" ]; then
		file=$(find "$dir" -maxdepth 1 \( -name "*cli-${name_ver#v}*.jar" -o -name "*desktop-${name_ver#v}*.jar" \) -type f 2>/dev/null | sed -n '1p')
	elif [ "$kind" = "patches" ]; then
		file=$(find "$dir" -maxdepth 1 \( -name "*patches-${name_ver#v}*.jar" -o -name "*patches-${name_ver#v}*.mpp" -o -name "*patches-${name_ver#v}*.apk" \) -type f 2>/dev/null | sed -n '1p')
	else
		abort "unreachable prebuilt kind: $kind"
	fi

	if [ -n "$file" ] && [ "$ver" = "latest" ]; then
		file=$(grep -v '/[^/]*dev[^/]*$' <<<"$file" | sed -n '1p')
	elif [ -n "$file" ]; then
		file=$(grep "/[^/]*${ver#v}[^/]*\$" <<<"$file" | sed -n '1p')
	fi

	if [ -z "$file" ]; then
		local matches tag_name_clean
		resp=$(gh_req "$rv_rel" -) || return 1
		tag_name=$(jq -r '.tag_name' <<<"$resp") || return 1
		matches=$(jq -e '.assets | map(select(.name | (endswith("asc") or endswith("json")) | not))' <<<"$resp") || return 1
		if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
			local matches_new
			matches_new=$(jq -e -r 'map(select(.name | contains("-dev") | not))' <<<"$matches" 2>/dev/null || :)
			if [ -n "$matches_new" ] && [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then
				matches=$matches_new
			fi
		fi
		if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
			epr "No asset was found for ${src}/${ver}"
			return 1
		elif [ "$(jq 'length' <<<"$matches")" -ne 1 ]; then
			wpr "More than 1 asset was found for ${src}/${ver}. Falling back to the first one found..."
		fi
		asset=$(jq -r '.[0]' <<<"$matches")
		url=$(jq -r '.url' <<<"$asset")
		name=$(jq -r '.name' <<<"$asset")
		tag_name_clean="${tag_name#v}"
		if [ "$kind" = "patches" ]; then
			local name_ext="${name##*.}"
			name="patches-${tag_name_clean}.${name_ext}"
		fi
		file="${dir}/${name}"
		gh_dl "$file" "$url" >&2 || return 1
	else
		name=$(basename "$file")
		tag_name=$(cut -d'-' -f2- <<<"$name")
		tag_name="v${tag_name%.*}"
	fi

	if [ "$kind" = "patches" ]; then
		if [ "${REMOVE_RV_INTEGRATIONS_CHECKS:-true}" = "true" ]; then
			local extensions_ext
			extensions_ext=$(unzip -l "${file}" "extensions/shared.*" 2>/dev/null | grep -o "shared\..*" | head -1)
			extensions_ext="${extensions_ext#*.}"
			if [ -n "$extensions_ext" ]; then
				(
					mkdir -p "${file}-zip" || return 1
					unzip -qo "${file}" -d "${file}-zip" || return 1
					java_cmd -cp "${BIN_DIR}/paccer.jar:${BIN_DIR}/dexlib2.jar" com.jhc.Main \
						"${file}-zip/extensions/shared.${extensions_ext}" \
						"${file}-zip/extensions/shared-patched.${extensions_ext}" || return 1
					mv -f "${file}-zip/extensions/shared-patched.${extensions_ext}" \
						"${file}-zip/extensions/shared.${extensions_ext}" || return 1
					rm -f "${file}"
					(
						cd "${file}-zip" || exit 1
						zip -0rq "${CWD}/${file}" . || return 1
					)
				) >&2
				rm -rf "${file}-zip"
			fi
		fi
	fi

	printf '%s\n' "$file"
}

# Upstream release notes (changelog) link for a resolved patches file.
#
# Arguments: <repo> <patches file>
# Prints the GitHub release URL for the patches version. Release tags in the
# supported patch repositories are v-prefixed, while the normalised asset name
# drops that prefix, so it is added back here.
patches_changelog_url() {
	local src=$1 patches_file=$2 base ver
	base=$(basename "$patches_file")
	# Strip only known asset extensions so a version without a dot is kept.
	case "$base" in
	*.jar | *.mpp | *.apk) base=${base%.*} ;;
	esac
	ver=${base#patches-}
	if [ -z "$ver" ] || [ "$ver" = "$base" ]; then
		return 1
	fi
	printf 'https://github.com/%s/releases/tag/v%s' "$src" "$ver"
}

# Resolve both prebuilts. Prints two lines: patches path, cli path.
get_prebuilts() {
	local cli_src=$1 cli_ver=$2 patches_src=$3 patches_ver=$4
	local patches_jar cli_jar
	pr "Getting prebuilts (${patches_src%/*})" >&2

	patches_jar=$(resolve_prebuilt patches "$patches_src" "$patches_ver") || return 1
	cli_jar=$(resolve_prebuilt cli "$cli_src" "$cli_ver") || return 1

	printf '%s\n%s\n' "$patches_jar" "$cli_jar"
}

# ---------------------------------------------------------------------------
# Patch listing helpers
# ---------------------------------------------------------------------------

patches_list_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 is_experimental=$4
	local cmd_base=("${JAVA_CMD[@]}" -jar "$cli_jar" list-versions)
	local cli_name op

	cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = "revanced" ]; then
		cmd_base+=(-b)
	elif [ "$is_experimental" = "true" ]; then
		cmd_base+=(-x)
	fi

	if op=$("${cmd_base[@]}" --patches="$patches_jar" -f "$pkg_name" 2>&1); then
		echo "$op"
		return
	fi
	if op=$("${cmd_base[@]}" "$patches_jar" -f "$pkg_name" 2>&1); then
		echo "$op"
		return
	fi

	epr "Could not list versions ($pkg_name) $cli_jar: '$op'"
	return 1
}

patches_list() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 is_experimental=$4
	local cmd op
	if op=$(java_cmd -jar "$cli_jar" list-patches -p "$patches_jar" --filter-package-name "$pkg_name" --versions --packages -b 2>&1); then
		echo "$op"
		return
	fi

	if [ "$is_experimental" = "true" ]; then
		if op=$(java_cmd -jar "$cli_jar" list-patches --patches "$patches_jar" -f "$pkg_name" --with-versions --with-packages -x 2>&1); then
			echo "$op"
			return
		fi
	else
		if op=$(java_cmd -jar "$cli_jar" list-patches --patches "$patches_jar" -f "$pkg_name" --with-versions --with-packages 2>&1); then
			echo "$op"
			return
		fi
	fi

	epr "Could not get patches list ($pkg_name) $cli_jar: '$op'"
	return 1
}

get_patch_last_supported_ver() {
	local list_patches=$1 pkg_name=$2 inc_sel=$3 is_experimental=$4
	local op ver vers="" NL=$'\n' line

	if [ -n "$inc_sel" ]; then
		if ! op=$(awk '{$1=$1}1' <<<"$list_patches"); then
			epr "list-patches: '$op'"
			return 1
		fi
		while IFS= read -r line; do
			line="${line:1:${#line}-2}"
			ver=$(sed -n "/^Name: $line\$/,/^\$/p" <<<"$op" | sed -n "/^Compatible versions:\$/,/^\$/p" | tail -n +2)
			vers=${vers}${ver}${NL}
		done <<<"$(list_args "$inc_sel")"
		vers=$(awk '{$1=$1}1' <<<"$vers")
		if [ -n "$vers" ]; then
			get_highest_ver <<<"$vers"
			return
		fi
	fi

	op=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$is_experimental") || return 1
	op=$(sed -n '/Most common compatible versions:/,$p' <<<"$op" | awk 'NR > 1 {print $1}')
	if [ -z "$op" ]; then
		abort "No patches found for '$pkg_name' in patches '$patches_jar'"
	elif [ "$op" = "Any" ]; then
		return 0
	fi
	get_highest_ver <<<"$op" || return 1
}

# ---------------------------------------------------------------------------
# APK signing / merging helpers
# ---------------------------------------------------------------------------

apksigner_cmd() { java_cmd -jar "$APKSIGNER_JAR" "$@"; }

merge_splits() {
	local bundle=$1 output=$2
	pr "Merging splits"
	if [ ! -f "$TEMP_DIR/apkeditor.jar" ]; then
		local resp dlurl
		resp=$(gh_req "https://api.github.com/repos/REAndroid/APKEditor/releases/latest" -) || return 1
		dlurl=$(jq -e -r '.assets[] | select(.name | endswith(".jar")) | .browser_download_url' <<<"$resp" | head -1) || return 1
		gh_dl "$TEMP_DIR/apkeditor.jar" "$dlurl" >/dev/null || return 1
	fi
	if ! OP=$(java_cmd -jar "$TEMP_DIR/apkeditor.jar" merge -i "$bundle" -o "${output}-unsigned" -clean-meta -f 2>&1); then
		epr "APKEditor error: $OP"
		return 1
	fi
	if ! OP=$(apksigner_cmd sign \
		--ks "${MERGE_KEYSTORE:-ks-p12.keystore}" \
		--ks-pass "pass:${MERGE_KEYSTORE_PASSWORD:-123456789}" \
		--key-pass "pass:${MERGE_KEY_PASSWORD:-123456789}" \
		--ks-key-alias "${MERGE_KEY_ALIAS:-jhc}" \
		--out "${output}" "${output}-unsigned" 2>&1); then
		epr "apksigner error: $OP"
		return 1
	fi
	rm -f "${output}.idsig" "${output}-unsigned" 2>/dev/null || :
	return 0
}

check_sig() {
	local file=$1 pkg_name=$2
	local sig
	if [ "${VERIFY_SIGNATURE:-true}" != "true" ]; then
		return 0
	fi
	if [ ! -f sig.txt ]; then
		wpr "sig.txt not found; skipping signature verification for ${pkg_name}"
		return 0
	fi
	if grep -q -- "$pkg_name" sig.txt; then
		sig=$(apksigner_cmd verify --print-certs "$file" 2>/dev/null | grep '^Signer' | grep SHA-256 | tail -1 | awk '{print $NF}')
		echo "$pkg_name signature: ${sig}"
		if ! grep -qFx -- "$sig $pkg_name" sig.txt; then
			return 1
		fi
	fi
	return 0
}
