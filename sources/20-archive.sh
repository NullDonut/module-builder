#!/usr/bin/env bash
# Download source: archive.org directory listing
#
# Config key: archive-dlurl = "https://archive.org/download/<item>/apks/com.example.app"
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

SOURCE_NAME=archive
SOURCE_PRIORITY=20

__SOURCE_ARCHIVE_PKG=""
__SOURCE_ARCHIVE_RESP=""

source_archive_resp() {
	local url=$1 html
	__SOURCE_ARCHIVE_PKG=$(awk -F/ '{print $NF}' <<<"$url")
	html=$(req "$url" -) || return 1
	if [ -z "$html" ]; then return 1; fi
	__SOURCE_ARCHIVE_RESP=$(sed -n 's;^<a href="\(.*\)"[^"]*;\1;p' <<<"$html")
}

source_archive_pkg_name() { printf '%s\n' "$__SOURCE_ARCHIVE_PKG"; }

source_archive_versions() {
	sed 's/^[^-]*-//;s/-\(all\|arm64-v8a\|arm-v7a\|x86\|x86_64\)\.\(apk\|apkm\)//g' <<<"$__SOURCE_ARCHIVE_RESP"
}

source_archive_download() {
	local url=$1 version=$2 output=$3 arch=$4 _dpi=${5-}
	local version_f=${version// /}
	local path

	if [ -f "${output}.apkm" ]; then
		merge_splits "${output}.apkm" "$output"
		return 0
	fi

	if ! path=$(grep -m1 -- "${version_f#v}-${arch// /}" <<<"$__SOURCE_ARCHIVE_RESP"); then
		path=$(grep -m1 -- "${version_f#v}-all" <<<"$__SOURCE_ARCHIVE_RESP") || return 1
	fi

	if [ "${path##*.}" = "apkm" ]; then
		req "${url}/${path}" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "$output"
	else
		req "${url}/${path}" "$output" || return 1
	fi
}
