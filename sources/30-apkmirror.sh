#!/usr/bin/env bash
# Download source: APKMirror
#
# Config key: apkmirror-dlurl = "https://www.apkmirror.com/apk/<vendor>/<app>"
# Optional: dpi = "nodpi anydpi 360-480dpi"
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

SOURCE_NAME=apkmirror
SOURCE_PRIORITY=30

__SOURCE_APKMIRROR_RESP=""
__SOURCE_APKMIRROR_CAT=""

__apkmirror_require_htmlq() {
	if [ -z "${HTMLQ_BIN-}" ] || [ ! -x "$HTMLQ_BIN" ]; then
		epr "htmlq is required for the apkmirror source but was not found"
		return 1
	fi
}

__apkmirror_search() {
	local resp=$1 dpi=$2 arch=$3 apk_bundle=$4
	local dlurl="" node app_table emptyCheck
	local -a apparch=('universal' 'noarch' 'arm64-v8a + armeabi-v7a')
	local -a appdpi=("nodpi" "anydpi")
	local n

	if [ "$arch" != "all" ]; then
		apparch+=("$arch")
	fi
	if [ -n "$dpi" ]; then
		# shellcheck disable=SC2206
		appdpi+=($dpi)
	fi

	for ((n = 1; n < 40; n++)); do
		node=$("$HTMLQ_BIN" "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		emptyCheck=$("$HTMLQ_BIN" -t -w "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node" | xargs)
		if [ -z "$emptyCheck" ]; then break; fi
		app_table=$("$HTMLQ_BIN" --text --ignore-whitespace <<<"$node")
		if [ "$(sed -n 3p <<<"$app_table")" != "$apk_bundle" ]; then continue; fi
		dlurl=$("$HTMLQ_BIN" --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
		if isoneof "$(sed -n 6p <<<"$app_table")" "${appdpi[@]}" &&
			isoneof "$(sed -n 4p <<<"$app_table")" "${apparch[@]}"; then
			echo "$dlurl"
			return 0
		fi
	done
	if [ "$n" -eq 2 ] && [ -n "$dlurl" ]; then
		echo "$dlurl"
		return 0
	fi
	return 1
}

source_apkmirror_resp() {
	__apkmirror_require_htmlq || return 1
	__SOURCE_APKMIRROR_RESP=$(req "$1" -) || return 1
	__SOURCE_APKMIRROR_CAT=${1##*/}
	[ -n "$__SOURCE_APKMIRROR_RESP" ]
}

source_apkmirror_pkg_name() {
	sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p' <<<"$__SOURCE_APKMIRROR_RESP"
}

source_apkmirror_versions() {
	local vers apkm_resp v r_vers=()
	local IFS=$'\n'

	apkm_resp=$(req "https://www.apkmirror.com/uploads/?appcategory=${__SOURCE_APKMIRROR_CAT}" -) || return 1
	vers=$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$apkm_resp" | awk '{$1=$1}1')
	vers=$(grep -iv "\(beta\|alpha\)" <<<"$vers" || :)
	for v in $vers; do
		grep -iq "${v} \(beta\|alpha\)" <<<"$apkm_resp" || r_vers+=("$v")
	done
	printf '%s\n' "${r_vers[@]}"
}

source_apkmirror_download() {
	local url=$1 version=$2 output=$3 arch=$4 dpi=${5-}
	local is_bundle=false resp node app_table apkmname dlurl="" type

	__apkmirror_require_htmlq || return 1

	version=${version// /-}
	if [ -f "${output}.apkm" ]; then
		merge_splits "${output}.apkm" "${output}"
		return 0
	fi

	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi
	apkmname=$("$HTMLQ_BIN" "h1.marginZero" --text <<<"$__SOURCE_APKMIRROR_RESP")
	apkmname="${apkmname,,}"
	apkmname="${apkmname// /-}"
	apkmname="${apkmname//[^a-z0-9-]/}"
	url="${url}/${apkmname}-${version//./-}-release/"
	resp=$(req "$url" -) || return 1
	node=$("$HTMLQ_BIN" "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")
	if [ -n "$node" ]; then
		for type in APK BUNDLE; do
			if dlurl=$(__apkmirror_search "$resp" "$dpi" "$arch" "$type"); then
				if [ "$type" = "BUNDLE" ]; then
					is_bundle=true
				else
					is_bundle=false
				fi
				break
			fi
		done
		if [ -z "$dlurl" ]; then return 1; fi
		resp=$(req "$dlurl" -)
	fi
	url=$(echo "$resp" | "$HTMLQ_BIN" --base https://www.apkmirror.com --attribute href "a.btn") || return 1
	url=$(req "$url" - | "$HTMLQ_BIN" --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1

	if [ "$is_bundle" = true ]; then
		req "$url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		req "$url" "${output}" || return 1
	fi
}
