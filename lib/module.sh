#!/usr/bin/env bash
# module-builder - module packaging
#
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck shell=bash

module_arch_slug() {
	case "$1" in
	arm64-v8a) printf 'arm64' ;;
	arm-v7a) printf 'arm' ;;
	x86_64) printf 'x64' ;;
	x86) printf 'x86' ;;
	*) printf '' ;;
	esac
}

module_config_arch() {
	case "$1" in
	arm64-v8a) printf 'arm64' ;;
	arm-v7a) printf 'arm' ;;
	x86_64) printf 'x64' ;;
	x86) printf 'x86' ;;
	*) printf '' ;;
	esac
}

module_id_base() {
	local table=$1 id
	if id=$(config_get_effective "$table" module-id 2>/dev/null) && [ -n "$id" ]; then
		printf '%s' "$id"
		return 0
	fi
	if id=$(config_get_effective "$table" module-prop-name 2>/dev/null) && [ -n "$id" ]; then
		printf '%s' "$id"
		return 0
	fi
	printf '%s-shivanshbansal' "$(sanitize_name "$table")"
}

module_id_for() {
	local table=$1 arch=$2 base suffix
	base=$(module_id_base "$table")
	suffix=$(module_arch_slug "$arch")
	if [ -n "$suffix" ]; then
		printf '%s-%s' "$base" "$suffix"
	else
		printf '%s' "$base"
	fi
}

module_update_json_name() {
	local table=$1 arch=$2 override suffix
	if override=$(config_get_effective "$table" update-json-name 2>/dev/null) && [ -n "$override" ]; then
		printf '%s' "$override"
		return 0
	fi
	suffix=$(module_arch_slug "$arch")
	if [ -n "$suffix" ]; then
		printf '%s-%s-update.json' "$(sanitize_name "$table")" "$suffix"
	else
		printf '%s-update.json' "$(sanitize_name "$table")"
	fi
}

module_update_json_url() {
	local table=$1 arch=$2 base name
	base=$(config_get_effective "$table" update-json-base-url 2>/dev/null || :)
	if [ -z "$base" ]; then
		[ -n "${GITHUB_REPOSITORY-}" ] || return 1
		base="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/update"
	fi
	base=${base%/}
	name=$(module_update_json_name "$table" "$arch")
	printf '%s/%s' "$base" "$name"
}

# Version string shown in module.prop.
module_patches_version() {
	patches_file_version "$1" || basename "$1"
}

module_config_write() {
	local dir=$1 pkg_name=$2 version=$3 arch=$4 module_id=$5 module_name=$6 module_author=$7
	cat >"${dir}/config" <<EOF
PKG_NAME=$(sh_quote "$pkg_name")
PKG_VER=$(sh_quote "$version")
MODULE_ARCH=$(sh_quote "$(module_config_arch "$arch")")
MODULE_ID=$(sh_quote "$module_id")
MODULE_NAME=$(sh_quote "$module_name")
MODULE_AUTHOR=$(sh_quote "$module_author")
EOF
}

module_prop_write() {
	local dir=$1 table=$2 app_name=$3 rv_brand=$4 version=$5 arch=$6
	local patches_jar=$7 module_id=$8
	local name author description patches_ver update_json custom_version base_version
	local update_enabled=${ENABLE_MODULE_UPDATE:-false} app_update
	base_version=$version
	name=$(config_get_effective "$table" module-name "${app_name} ${rv_brand}")
	author=$(config_get_effective "$table" module-author "shivanshbansal")
	patches_ver=$(module_patches_version "$patches_jar")

	if description=$(config_get_effective "$table" module-description 2>/dev/null) && [ -n "$description" ]; then
		:
	else
		description="${app_name} ${rv_brand} module"
	fi
	if custom_version=$(config_get_effective "$table" module-version 2>/dev/null) && [ -n "$custom_version" ]; then
		version=$custom_version
	else
		version="${base_version} (patches ${patches_ver})"
	fi

	# module.prop is a line-oriented format.
	name=${name//$'\n'/ }
	description=${description//$'\n'/ }

	cat >"${dir}/module.prop" <<EOF
id=${module_id}
name=${name}
version=${version}
versionCode=${NEXT_VER_CODE}
author=${author}
description=${description}
EOF

	if app_update=$(config_get "$table" enable-module-update 2>/dev/null) && [ -n "$app_update" ]; then
		validate_bool "$app_update" enable-module-update
		update_enabled=$app_update
	fi
	if [ "$update_enabled" = "true" ]; then
		if update_json=$(module_update_json_url "$table" "$arch"); then
			printf 'updateJson=%s\n' "$update_json" >>"${dir}/module.prop"
		fi
	fi
}

copy_extra_module_files() {
	local table=$1 module_dir=$2 path
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		case "$path" in
		/*) : ;;
		*) path="${MB_ROOT}/${path}" ;;
		esac
		if [ -d "$path" ]; then
			cp -a "${path}/." "$module_dir/" || abort "Could not copy extra module files from '${path}'"
		elif [ -f "$path" ]; then
			cp -a "$path" "$module_dir/" || abort "Could not copy extra module file '${path}'"
		else
			abort "extra-module-files path does not exist: '${path}'"
		fi
	done < <(config_list "$table" "extra-module-files" "")
}

include_stock_apk() {
	local table=$1 include_stock=$2 stock_apk=$3 arch=$4 module_dir=$5
	local stock_dir="${module_dir}/stock"

	case "$include_stock" in
	disable)
		return 0
		;;
	merged)
		mkdir -p "$stock_dir"
		cp -f "$stock_apk" "${stock_dir}/base.apk" || return 1
		;;
	split)
		if [ ! -f "${stock_apk}.apkm" ]; then
			epr "Cannot include stock as 'split' for '${table}' because the stock download is not a bundle"
			return 1
		fi
		mkdir -p "$stock_dir"
		case "$arch" in
		arm64-v8a)
			unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*armeabi_v7a.apk' -d "$stock_dir" >/dev/null 2>&1 || return 1
			;;
		arm-v7a)
			unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -d "$stock_dir" >/dev/null 2>&1 || return 1
			;;
		x86)
			unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "$stock_dir" >/dev/null 2>&1 || return 1
			;;
		x86_64)
			unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "$stock_dir" >/dev/null 2>&1 || return 1
			;;
		*)
			unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -d "$stock_dir" >/dev/null 2>&1 || return 1
			;;
		esac
		;;
	*)
		abort "Invalid include-stock value '${include_stock}'"
		;;
	esac
}

# Package the module and print the resulting zip path.
package_module() {
	local table=$1 app_name=$2 pkg_name=$3 version=$4 arch=$5
	local stock_apk=$6 patched_apk=$7 rv_brand=$8 patches_jar=$9
	local cli_jar=${10} patcher_args=${11} include_stock=${12}
	local file_format=${13} module_id module_name module_author template
	local base_template module_output compression

	module_id=$(module_id_for "$table" "$arch")
	module_name=$(config_get_effective "$table" module-name "${app_name} ${rv_brand}")
	module_author=$(config_get_effective "$table" module-author "shivanshbansal")
	template=$(config_get_effective "$table" module-template "${MODULE_TEMPLATE_DIR}")
	compression=$(config_get_effective "$table" compression-level "${COMPRESSION_LEVEL:-9}")

	if [ ! -d "$template" ]; then
		epr "Module template not found: '$template'"
		return 1
	fi

	base_template=$(mktemp -d -p "$TEMP_DIR")
	cp -a "${template}/." "$base_template/" || return 1

	module_config_write "$base_template" "$pkg_name" "$version" "$arch" "$module_id" "$module_name" "$module_author"
	module_prop_write "$base_template" "$table" "$app_name" "$rv_brand" "$version" "$arch" "$patches_jar" "$module_id"

	cp -f "$patched_apk" "${base_template}/base.apk" || return 1
	include_stock_apk "$table" "$include_stock" "$stock_apk" "$arch" "$base_template" || return 1
	copy_extra_module_files "$table" "$base_template"

	module_output=$(format_output_name "$file_format" "$table" "$app_name" "$rv_brand" "$version" "$arch" "module")
	mkdir -p "$BUILD_DIR"

	(
		cd "$base_template" || exit 1
		zip -"$compression" -FSqr "${CWD}/${BUILD_DIR}/${module_output}" . || exit 1
	) || return 1

	run_hooks post-module "$table" "$app_name" "$pkg_name" "$version" "$arch" \
		"module" "$stock_apk" "$patched_apk" "$base_template" \
		"${BUILD_DIR}/${module_output}" "$module_id" "$rv_brand" "$patcher_args"

	printf '%s\n' "${BUILD_DIR}/${module_output}"
}

# Replace {placeholders} in an output name format.
format_output_name() {
	local format=$1 table=$2 app_name=$3 rv_brand=$4 version=$5 arch=$6 kind=$7
	local app_slug brand_slug version_slug arch_slug pkg
	app_slug=$(sanitize_name "$app_name")
	brand_slug=$(sanitize_name "$rv_brand")
	version_slug=${version// /}
	version_slug=${version_slug#v}
	arch_slug=${arch// /}
	pkg=${MB_PKG_NAME:-}

	format=${format//\{table\}/$(sanitize_name "$table")}
	format=${format//\{app\}/$app_slug}
	format=${format//\{app_name\}/$app_slug}
	format=${format//\{brand\}/$brand_slug}
	format=${format//\{version\}/$version_slug}
	format=${format//\{arch\}/$arch_slug}
	format=${format//\{kind\}/$kind}
	format=${format//\{pkg\}/$pkg}
	printf '%s' "$format"
}
