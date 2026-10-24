#!/usr/bin/env bash
# Download source: direct APK URL
#
# Config key: direct-dlurl = "https://host/com.example.app-1.2.3-all.apk"
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

SOURCE_NAME=direct
SOURCE_PRIORITY=10

__SOURCE_DIRECT_URL=""
__SOURCE_DIRECT_PKG=""
__SOURCE_DIRECT_VERSION=""
__SOURCE_DIRECT_ARCH=""
__SOURCE_DIRECT_EXT=""

source_direct_parse() {
	local url=$1 base
	base=${url%%\?*}
	base=${base##*/}
	__SOURCE_DIRECT_URL=$url
	__SOURCE_DIRECT_EXT=${base##*.}
	if [[ $base =~ ^([^-]+)-([0-9][^-]*)-(.+)\.(apk|apkm)$ ]]; then
		__SOURCE_DIRECT_PKG=${BASH_REMATCH[1]}
		__SOURCE_DIRECT_VERSION=${BASH_REMATCH[2]}
		__SOURCE_DIRECT_ARCH=${BASH_REMATCH[3]}
	else
		__SOURCE_DIRECT_PKG=""
		__SOURCE_DIRECT_VERSION=""
		__SOURCE_DIRECT_ARCH=""
	fi
}

source_direct_resp() {
	source_direct_parse "$1"
	[ -n "$__SOURCE_DIRECT_PKG" ]
}

source_direct_pkg_name() { printf '%s\n' "$__SOURCE_DIRECT_PKG"; }
source_direct_versions() { printf '%s\n' "$__SOURCE_DIRECT_VERSION"; }

source_direct_download() {
	local url=$1 version=$2 output=$3 arch=$4 _dpi=${5-}
	local version_f=${version// /}
	local arch_f=${arch// /}
	local expected="${version_f#v}-${arch_f}"

	source_direct_parse "$url"
	if [ -z "$__SOURCE_DIRECT_PKG" ]; then
		epr "Direct URL does not match the required '<package>-<version>-<arch>.apk' format: $url"
		return 1
	fi

	if [ "$arch_f" = "all" ]; then
		if ! grep -Eq -- "${version_f#v}-(all|universal|noarch)" <<<"$url"; then
			epr "Given direct-dlurl is not compatible with version '${version}' and arch '${arch}'"
			return 1
		fi
	elif ! grep -Fq -- "$expected" <<<"$url"; then
		epr "Given direct-dlurl is not compatible with version '${version}' and arch '${arch}'"
		return 1
	fi

	if [ "${__SOURCE_DIRECT_EXT}" = "apkm" ]; then
		req "$url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "$output"
	else
		req "$url" "$output"
	fi
}
