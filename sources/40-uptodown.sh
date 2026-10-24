#!/usr/bin/env bash
# Download source: Uptodown
#
# Config key: uptodown-dlurl = "https://app.uptodown.com/android"
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

SOURCE_NAME=uptodown
SOURCE_PRIORITY=40

__SOURCE_UPTODOWN_RESP=""
__SOURCE_UPTODOWN_RESP_PKG=""

__uptodown_require_htmlq() {
	if [ -z "${HTMLQ_BIN-}" ] || [ ! -x "$HTMLQ_BIN" ]; then
		epr "htmlq is required for the uptodown source but was not found"
		return 1
	fi
}

source_uptodown_resp() {
	local url=$1
	__uptodown_require_htmlq || return 1
	__SOURCE_UPTODOWN_RESP=$(req "${url}/versions" -) || return 1
	__SOURCE_UPTODOWN_RESP_PKG=$(req "${url}/download" -) || return 1
	[ -n "$__SOURCE_UPTODOWN_RESP" ]
}

source_uptodown_pkg_name() {
	"$HTMLQ_BIN" --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"$__SOURCE_UPTODOWN_RESP_PKG"
}

source_uptodown_versions() {
	"$HTMLQ_BIN" --text ".version" <<<"$__SOURCE_UPTODOWN_RESP"
}

source_uptodown_download() {
	local url=$1 version=$2 output=$3 arch=$4 _dpi=${5-}
	local apparch=('arm64-v8a, armeabi-v7a, x86_64' 'arm64-v8a, armeabi-v7a, x86, x86_64' 'arm64-v8a, armeabi-v7a')
	local op resp data_code versionURL="" is_bundle=false i n
	local node_arch="" data_version files node_class file_type data_file_id data_url

	__uptodown_require_htmlq || return 1
	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi
	if [ "$arch" != "all" ]; then
		apparch+=("$arch")
	fi

	data_code=$("$HTMLQ_BIN" "#detail-app-name" --attribute data-code <<<"$__SOURCE_UPTODOWN_RESP")
	for ((i = 1; i <= 20; i++)); do
		resp=$(req "${url}/apps/${data_code}/versions/${i}" -) || continue
		if ! op=$(jq -e -r --arg v "$version" '.data | map(select(.version == $v)) | .[0]' <<<"$resp"); then
			continue
		fi
		if [ "$(jq -e -r '.kindFile' <<<"$op")" = "xapk" ]; then is_bundle=true; fi
		if versionURL=$(jq -e -r '.versionURL' <<<"$op"); then break; else return 1; fi
	done
	if [ -z "$versionURL" ]; then return 1; fi
	versionURL=$(jq -e -r '.url + "/" + .extraURL + "/" + (.versionID | tostring)' <<<"$versionURL")
	resp=$(req "$versionURL" -) || return 1

	data_version=$("$HTMLQ_BIN" '.button.variants' --attribute data-version <<<"$resp") || return 1
	if [ -n "$data_version" ]; then
		files=$(req "${url%/*}/app/${data_code}/version/${data_version}/files" - | jq -e -r .content) || return 1
		for ((n = 1; n < 12; n += 1)); do
			node_class=$("$HTMLQ_BIN" -w -t ".content > :nth-child($n)" --attribute class <<<"$files") || return 1
			if [ "$node_class" != "variant" ]; then
				node_arch=$("$HTMLQ_BIN" -w -t ".content > :nth-child($n)" <<<"$files" | xargs) || return 1
				continue
			fi
			if [ -z "$node_arch" ]; then return 1; fi
			if ! isoneof "$node_arch" "${apparch[@]}"; then continue; fi

			file_type=$("$HTMLQ_BIN" -w -t ".content > :nth-child($n) > .v-file > span" <<<"$files") || return 1
			if [ "$file_type" = "xapk" ]; then is_bundle=true; else is_bundle=false; fi
			data_file_id=$("$HTMLQ_BIN" ".content > :nth-child($n) > .v-report" --attribute data-file-id <<<"$files") || return 1
			resp=$(req "${url}/download/${data_file_id}-x" -)
			break
		done
		if [ "$n" -eq 12 ]; then return 1; fi
	fi

	data_url=$("$HTMLQ_BIN" "#detail-download-button" --attribute data-url <<<"$resp") || return 1
	if [ "$is_bundle" = true ]; then
		req "https://dw.uptodown.com/dwn/${data_url}" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		req "https://dw.uptodown.com/dwn/${data_url}" "$output"
	fi
}
