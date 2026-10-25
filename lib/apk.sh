#!/usr/bin/env bash
# module-builder - per-app build pipeline
#
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck shell=bash

# Convert a shell-like argument string (as used by patcher-args) into the
# global array REPLY_ARGS. Config files are trusted; this is intentionally the
# same semantics users expect from the CLI.
parse_args_string() {
	local str=$1
	REPLY_ARGS=()
	if [ -n "$str" ]; then
		eval "REPLY_ARGS=(${str})"
	fi
}

patch_apk() {
	local stock_input=$1 patched_apk=$2 args_string=$3 cli_jar=$4 patches_jar=$5
	local tmp_files cli_name
	local -a cmd extra=()

	tmp_files="${CWD}/${TEMP_DIR}/patch-tmp.$$"
	mkdir -p "$tmp_files"

	cmd=("${JAVA_CMD[@]}" -jar "$cli_jar" patch "$stock_input" -o "$patched_apk" \
		-p "$patches_jar" \
		--keystore="${SIGNING_KEYSTORE:-ks.keystore}" \
		--keystore-entry-password="${SIGNING_ENTRY_PASSWORD:-123456789}" \
		--keystore-password="${SIGNING_KEYSTORE_PASSWORD:-123456789}" \
		--signer="${SIGNING_SIGNER:-jhc}" \
		--keystore-entry-alias="${SIGNING_ENTRY_ALIAS:-jhc}" \
		-t "$tmp_files")

	if [ -n "$args_string" ]; then
		parse_args_string "$args_string"
		extra=("${REPLY_ARGS[@]}")
		cmd+=("${extra[@]}")
	fi

	# ReVanced CLI needs -b; Morphe CLI does not, but harmless to detect.
	cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = "revanced" ]; then
		cmd+=(-b)
		if [ "$OS" = "Android" ] && [ -n "${AAPT2_BIN-}" ]; then
			cmd+=("--custom-aapt2-binary=${AAPT2_BIN}")
		fi
	fi

	pr "Patching ${stock_input}"
	dpr "Command: ${cmd[*]}"
	if "${cmd[@]}"; then
		[ -f "$patched_apk" ] || return 1
	else
		rm -f "$patched_apk" 2>/dev/null || :
		return 1
	fi
	rm -rf "$tmp_files"
}

# Strip native libraries from a copy of the stock APK. Returns the stripped
# path on stdout.
strip_stock_apk() {
	local stock_apk=$1 build_mode=$2 arch=$3
	local out="${stock_apk}.stripped.apk"
	cp -f "$stock_apk" "$out" || return 1

	if [ "$build_mode" = "module" ]; then
		zip -d "$out" "lib/*" >/dev/null 2>&1 || :
	else
		case "$arch" in
		arm64-v8a)
			zip -d "$out" "lib/armeabi-v7a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			;;
		arm-v7a)
			zip -d "$out" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			;;
		x86)
			zip -d "$out" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/armeabi-v7a/*" >/dev/null 2>&1 || :
			;;
		x86_64)
			zip -d "$out" "lib/arm64-v8a/*" "lib/armeabi-v7a/*" "lib/x86/*" >/dev/null 2>&1 || :
			;;
		*)
			zip -d "$out" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			;;
		esac
	fi
	printf '%s\n' "$out"
}

# Extract a package name from an APK using aapt2.
aapt2_pkg_name() {
	local apk=$1
	[ -n "${AAPT2_BIN-}" ] && [ -x "$AAPT2_BIN" ] || return 1
	"$AAPT2_BIN" dump badging "$apk" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | sed -n '1p'
}

resolve_pkg_name() {
	local table=$1
	local pkg_name src url stock_apk
	local -a sources=()

	if pkg_name=$(config_get_effective "$table" pkg-name ""); then
		if [ -n "$pkg_name" ]; then
			printf '%s' "$pkg_name"
			return 0
		fi
	fi

	# A locally supplied stock APK can provide the package name.
	stock_apk=$(config_get_effective "$table" stock-apk "")
	if [ -n "$stock_apk" ]; then
		case "$stock_apk" in
		/*) : ;;
		*) stock_apk="${MB_ROOT}/${stock_apk}" ;;
		esac
	fi
	if [ -n "$stock_apk" ] && [ -f "$stock_apk" ] && [ -n "${AAPT2_BIN-}" ]; then
		pkg_name=$(aapt2_pkg_name "$stock_apk" || :)
		if [ -n "$pkg_name" ]; then
			printf '%s' "$pkg_name"
			return 0
		fi
	fi

	mapfile -t sources < <(source_names_for "$table")
	for src in "${sources[@]}"; do
		[ -n "$src" ] || continue
		url=$(source_url "$table" "$src")
		[ -n "$url" ] || continue
		if ! source_resp "$src" "$url"; then
			wpr "Could not read metadata from '${src}' for '${table}'"
			continue
		fi
		if pkg_name=$(source_pkg_name "$src"); then
			if [ -n "$pkg_name" ]; then
				printf '%s' "$pkg_name"
				return 0
			fi
		fi
	done
	return 1
}

# Pick the source that works for version discovery / download. Prefers a
# source that was already used to resolve metadata.
pick_source() {
	local table=$1 preferred=${2-}
	local src url
	local -a sources=()
	if [ -n "$preferred" ]; then
		url=$(source_url "$table" "$preferred")
		if [ -n "$url" ]; then
			printf '%s' "$preferred"
			return 0
		fi
	fi
	mapfile -t sources < <(source_names_for "$table")
	for src in "${sources[@]}"; do
		[ -n "$src" ] || continue
		url=$(source_url "$table" "$src")
		if [ -n "$url" ]; then
			printf '%s' "$src"
			return 0
		fi
	done
	return 1
}

latest_version_from_source() {
	local table=$1 src=$2 url versions
	url=$(source_url "$table" "$src")
	[ -n "$url" ] || return 1
	source_resp "$src" "$url" || return 1
	versions=$(source_versions "$src") || return 1
	[ -n "$versions" ] || return 1
	get_highest_ver <<<"$versions" || sed -n '1p' <<<"$versions"
}

download_stock_apk() {
	local table=$1 pkg_name=$2 version=$3 arch=$4 output=$5 preferred=${6-}
	local src url version_f
	local -a order=()
	version_f=${version// /}

	if [ -f "$output" ] || [ -f "${output}.apkm" ]; then
		if [ -f "${output}.apkm" ] && [ ! -f "$output" ]; then
			merge_splits "${output}.apkm" "$output" || return 1
		fi
		return 0
	fi

	if [ -n "$preferred" ]; then order+=("$preferred"); fi
	while IFS= read -r src; do
		[ -n "$src" ] && ! isoneof "$src" "${order[@]}" && order+=("$src")
	done < <(source_names_for "$table")

	for src in "${order[@]}"; do
		url=$(source_url "$table" "$src")
		[ -n "$url" ] || continue
		pr "Downloading '${table}' from '${src}'"
		if ! source_resp "$src" "$url"; then
			epr "Could not get '${table}' metadata from '${src}'"
			continue
		fi
		if source_download "$src" "$url" "$version" "$output" "$arch" "$(config_get_effective "$table" dpi "")"; then
			if [ -f "$output" ] || [ -f "${output}.apkm" ]; then
				return 0
			fi
		fi
		epr "Could not download '${table}' from '${src}' (version ${version_f}, arch ${arch})"
	done
	return 1
}

# Build one table/arch variant. Accepts a serialized associative array:
#   build_variant "$(declare -p app_args)"
build_variant() {
	local spec=$1
	eval "declare -A args=${spec#*=}"

	local table=${args[table]}
	local arch=${args[arch]}
	local label=${args[label]:-$table}
	local app_name rv_brand build_mode include_stock version_mode
	local patches_src patches_ver cli_src cli_ver
	local pkg_name="" dl_from="" version="" stock_apk=""
	local is_experimental=false get_latest_ver=false
	local p_patcher_args="" included_patches excluded_patches exclusive_patches
	local list_patches branding_patch="" microg_patch=""
	local patches_jar cli_jar prebuilts patch_failed=false
	local -a prebuilt_lines=() build_mode_arr=() apk_outputs=()
	local version_f arch_f app_slug brand_slug
	local mode output apk_format module_format

	app_name=$(config_get_effective "$table" app-name "$table")
	rv_brand=$(config_get_effective "$table" rv-brand "${DEF_RV_BRAND:-ReVanced}")
	build_mode=$(config_get_effective "$table" build-mode "apk")
	include_stock=$(config_get_effective "$table" include-stock "merged")
	version_mode=$(config_get_effective "$table" version "auto")
	patches_src=$(config_get_effective "$table" patches-source "${DEF_PATCHES_SRC:-ReVanced/revanced-patches}")
	patches_ver=$(config_get_effective "$table" patches-version "${DEF_PATCHES_VER:-latest}")
	cli_src=$(config_get_effective "$table" cli-source "${DEF_CLI_SRC:-ReVanced/revanced-cli}")
	cli_ver=$(config_get_effective "$table" cli-version "${DEF_CLI_VER:-latest}")

	app_slug=$(sanitize_name "$app_name")
	brand_slug=$(sanitize_name "$rv_brand")

	run_hooks pre-build "$table" "$app_name" "" "" "$arch" "$build_mode" "" "" "" "" "" "$rv_brand" ""

	if ! prebuilts=$(get_prebuilts "$cli_src" "$cli_ver" "$patches_src" "$patches_ver"); then
		epr "Could not get prebuilts for '${table}'"
		return 1
	fi
	mapfile -t prebuilt_lines <<<"$prebuilts"
	patches_jar=${prebuilt_lines[0]-}
	cli_jar=${prebuilt_lines[1]-}
	if [ ! -f "$patches_jar" ] || [ ! -f "$cli_jar" ]; then
		epr "Prebuilt JARs were not resolved for '${table}'"
		return 1
	fi
	log "Patches: ${patches_src}/$(basename "$patches_jar")"
	if changelog_url=$(patches_changelog_url "$patches_src" "$patches_jar"); then
		log "Patches changelog: ${changelog_url}"
	fi
	log "CLI: ${cli_src}/$(basename "$cli_jar")"

	# get_patch_last_supported_ver uses these globals.
	cli_jar=$cli_jar
	patches_jar=$patches_jar

	if ! pkg_name=$(resolve_pkg_name "$table"); then
		epr "empty package name, not building ${label}."
		return 2
	fi
	pr "Package name of '${label}' is '${pkg_name}'"
	MB_PKG_NAME=$pkg_name

	if [ "$version_mode" = "experimental" ]; then
		is_experimental=true
	fi

	if ! list_patches=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "$is_experimental"); then
		epr "Could not list patches for '${pkg_name}'"
		return 1
	fi

	excluded_patches=$(config_get_effective "$table" excluded-patches "")
	included_patches=$(config_get_effective "$table" included-patches "")
	exclusive_patches=$(config_bool "$table" exclusive-patches false)

	if [ -n "$excluded_patches" ] && [[ $excluded_patches != *'"'* ]] && [[ $excluded_patches != *"'"* ]]; then
		abort "patch names inside excluded-patches must be quoted ('${table}')"
	fi
	if [ -n "$included_patches" ] && [[ $included_patches != *'"'* ]] && [[ $included_patches != *"'"* ]]; then
		abort "patch names inside included-patches must be quoted ('${table}')"
	fi

	if [ -n "$excluded_patches" ]; then p_patcher_args+=" $(join_args "$excluded_patches" -d)"; fi
	if [ -n "$included_patches" ]; then p_patcher_args+=" $(join_args "$included_patches" -e)"; fi
	if [ "$exclusive_patches" = true ]; then p_patcher_args+=" --exclusive"; fi

	if isoneof "$version_mode" "auto" "experimental"; then
		if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" "$included_patches" "$is_experimental"); then
			epr "Could not determine a supported version for '${label}'"
			return 1
		fi
		if [ -z "$version" ]; then get_latest_ver=true; fi
	elif [ "$version_mode" = "latest" ]; then
		get_latest_ver=true
		p_patcher_args+=" -f"
	else
		version=$version_mode
		p_patcher_args+=" -f"
	fi

	dl_from=$(config_get_effective "$table" "dl-from" "")
	if [ -z "$dl_from" ]; then
		# If package metadata came from a source, prefer it; otherwise the
		# source order does the right thing.
		dl_from=""
	fi

	if [ "$get_latest_ver" = true ]; then
		local src
		src=$(pick_source "$table" "$dl_from") || {
			epr "No usable download source for '${label}'"
			return 1
		}
		dl_from=$src
		if ! version=$(latest_version_from_source "$table" "$src"); then
			epr "Could not determine the latest version for '${label}' from '${src}'"
			return 1
		fi
	fi
	if [ -z "$version" ]; then
		epr "Empty version, not building ${label}."
		return 2
	fi

	version_f=${version// /}
	version_f=${version_f#v}
	arch_f=${arch// /}
	stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"

	pr "Choosing version '${version}' for ${label}"
	local stock_override
	stock_override=$(config_get_effective "$table" stock-apk "")
	if [ -n "$stock_override" ]; then
		case "$stock_override" in
		/*) : ;;
		*) stock_override="${MB_ROOT}/${stock_override}" ;;
		esac
		if [ ! -f "$stock_override" ]; then
			epr "stock-apk not found for '${label}': ${stock_override}"
			return 1
		fi
		stock_apk=$stock_override
		pr "Using stock APK '${stock_apk}' for ${label}"
	elif ! download_stock_apk "$table" "$pkg_name" "$version" "$arch" "$stock_apk" "$dl_from"; then
		epr "Stock apk not found (${stock_apk})"
		return 1
	fi

	local sig_op
	if [ -f "${stock_apk}.apkm" ]; then
		rm -rf "${stock_apk}-zip" || :
		unzip -j "${stock_apk}.apkm" -d "${stock_apk}-zip" >/dev/null || :
		local base_apk="${stock_apk}-zip/base.apk"
		if ! sig_op=$(check_sig "$base_apk" "$pkg_name" 2>&1); then
			epr "Not building ${label}, apk signature mismatch '${base_apk}': ${sig_op}"
			return 2
		fi
		rm -rf "${stock_apk}-zip" || :
	else
		if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" 2>&1); then
			epr "Not building ${label}, apk signature mismatch '${stock_apk}': ${sig_op}"
			return 2
		fi
	fi

	log "${label}: ${version}"

	if [ -n "$(config_get_effective "$table" patcher-args "")" ]; then
		p_patcher_args+=" $(config_get_effective "$table" patcher-args "")"
	fi

	branding_patch=$(grep '^Name: ' <<<"$list_patches" | grep -i 'custom branding' | sed -n '1p' | cut -d: -f2- | xargs || :)
	microg_patch=$(grep '^Name: ' <<<"$list_patches" | grep -Ei 'gmscore|microg' | sed -n '1p' | cut -d: -f2- | xargs || :)
	if [ -n "$branding_patch" ] && [[ $p_patcher_args == *"$branding_patch"* ]]; then
		branding_patch=""
	fi
	if [ -n "$microg_patch" ] && [[ $p_patcher_args == *"$microg_patch"* ]]; then
		wpr "Cannot include/exclude the microg patch; the builder manages it automatically."
		microg_patch=""
	fi

	case "$build_mode" in
	both) build_mode_arr=(apk module) ;;
	apk) build_mode_arr=(apk) ;;
	module) build_mode_arr=(module) ;;
	*) abort "Invalid build-mode '${build_mode}'" ;;
	esac

	# Do not put the brace-containing defaults inside "${VAR:-...}": the
	# first closing brace ends the expansion and corrupts the output name.
	apk_format=$(config_get_effective "$table" apk-name-format "${APK_NAME_FORMAT:-}")
	if [ -z "$apk_format" ]; then
		apk_format='{app}-{brand}-v{version}-{arch}.apk'
	fi
	module_format=$(config_get_effective "$table" module-name-format "${MODULE_NAME_FORMAT:-}")
	if [ -z "$module_format" ]; then
		module_format='{app}-{brand}-module-v{version}-{arch}.zip'
	fi

	for mode in "${build_mode_arr[@]}"; do
		local patcher_args="$p_patcher_args"
		local sub_mode="$mode"
		local patched_apk="${TEMP_DIR}/${app_slug}-${brand_slug}-v${version_f}-${arch_f}-${sub_mode}.apk"
		local stock_to_patch

		pr "Building '${label}' in '${sub_mode}' mode"

		if [ "$sub_mode" = "apk" ]; then
			if [ -n "$microg_patch" ]; then
				patcher_args+=" -e $(sh_quote "$microg_patch")"
			fi
		else
			if [ -n "$microg_patch" ]; then
				patcher_args+=" -d $(sh_quote "$microg_patch")"
			fi
			if [ -n "$branding_patch" ]; then
				patcher_args+=" -d $(sh_quote "$branding_patch")"
			fi
		fi

		if [ "$sub_mode" = "apk" ] && [ "$(config_bool "$table" enable-update-checks false)" = true ]; then
			local update_check_url v
			update_check_url=$(config_get_effective "$table" update-check-patch-url "")
			if [ -z "$update_check_url" ] && [ "${GITHUB_REPOSITORY-}" = "j-hc/revanced-magisk-module" ]; then
				update_check_url="https://github.com/j-hc/morphe-jhc-update-check-patch/releases/latest"
			fi
			if [ -n "$update_check_url" ]; then
				local patch_file="${TEMP_DIR}/update-check.mpp"
				if [ ! -s "$patch_file" ]; then
					if [[ $update_check_url == https://api.github.com/* ]]; then
						local resp dlurl
						resp=$(gh_req "$update_check_url" -) || :
						dlurl=$(jq -e -r '.assets[0].browser_download_url' <<<"$resp" 2>/dev/null) || :
						[ -n "$dlurl" ] && gh_dl "$patch_file" "$dlurl" >/dev/null || :
					else
						gh_dl "$patch_file" "$update_check_url" >/dev/null || :
					fi
				fi
				if [ -s "$patch_file" ]; then
					patcher_args+=" -p $(sh_quote "$patch_file")"
					v=$(git -C "$MB_ROOT" tag --sort=committerdate 2>/dev/null | tail -1 || :)
					if [[ $v =~ ^[0-9]+$ ]]; then
						v=$((v + 1))
						patcher_args+=" -e $(sh_quote 'Current Build Tag') -OcurrentTag=$(sh_quote "\"${v}\"")"
					fi
				fi
			else
				wpr "enable-update-checks is only effective when update-check-patch-url is set (or in j-hc/revanced-magisk-module)."
			fi
		fi

		if ! stock_to_patch=$(strip_stock_apk "$stock_apk" "$sub_mode" "$arch"); then
			epr "Could not prepare stock apk for '${label}'"
			return 1
		fi

		if ! patch_apk "$stock_to_patch" "$patched_apk" "$patcher_args" "$cli_jar" "$patches_jar"; then
			epr "Building '${label}' (${sub_mode}) failed!"
			rm -f "$stock_to_patch"
			patch_failed=true
			continue
		fi
		rm -f "$stock_to_patch"

		run_hooks post-patch "$table" "$app_name" "$pkg_name" "$version" "$arch" \
			"$sub_mode" "$stock_apk" "$patched_apk" "" "" "" "$rv_brand" "$patcher_args"

		if [ "$sub_mode" = "apk" ]; then
			output=$(format_output_name "$apk_format" "$table" "$app_name" "$rv_brand" "$version" "$arch" "apk")
			mkdir -p "$BUILD_DIR"
			mv -f "$patched_apk" "${BUILD_DIR}/${output}" || {
				epr "Could not move patched APK for '${label}'"
				patch_failed=true
				continue
			}
			apk_outputs+=("${BUILD_DIR}/${output}")
			pr "Built ${label} (non-root): '${BUILD_DIR}/${output}'"
		else
			output=$(package_module "$table" "$app_name" "$pkg_name" "$version" "$arch" \
				"$stock_apk" "$patched_apk" "$rv_brand" "$patches_jar" \
				"$cli_jar" "$patcher_args" "$include_stock" "$module_format") || {
				epr "Could not package module for '${label}'"
				patch_failed=true
				continue
			}
			pr "Built ${label} (root): '${output}'"
		fi
	done

	if [ "$patch_failed" = true ]; then
		return 1
	fi
	return 0
}
