#!/usr/bin/env bash
# module-builder - HTTP helpers
#
# Copyright (C) 2024-2026 Peter Noël Muller
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

# shellcheck shell=bash

mkdir -p "$TEMP_DIR"
: >"$TEMP_DIR/cookie.txt" 2>/dev/null || :

_req() {
	local ip=$1 op=$2
	shift 2
	local dlp=$op
	local -a headers=("$@")

	if [ "$op" != "-" ]; then
		if [ -s "$op" ]; then
			return 0
		fi
		mkdir -p "$(dirname "$op")"
		dlp="${op}.tmp.$$"
	fi

	if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" \
		--connect-timeout 15 --retry 3 --retry-delay 1 --fail --silent --show-error \
		"${headers[@]}" "$ip" -o "$dlp"; then
		epr "Request failed: $ip"
		if [ "$dlp" != "-" ]; then rm -f "$dlp"; fi
		return 1
	fi

	if [ "$dlp" != "-" ]; then
		mv -f "$dlp" "$op"
	fi
}

req() {
	local url=$1 out=$2
	shift 2
	_req "$url" "$out" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:148.0) Gecko/20100101 Firefox/148.0" "$@"
}

gh_req() {
	local url=$1 out=$2
	shift 2
	if [ -n "$GH_HEADER" ]; then
		_req "$url" "$out" -H "$GH_HEADER" -H "Accept: application/vnd.github+json" "$@"
	else
		_req "$url" "$out" -H "Accept: application/vnd.github+json" "$@"
	fi
}

gh_dl() {
	local file=$1 url=$2
	local -a args=()
	if [ -n "$GH_HEADER" ]; then
		args=(-H "$GH_HEADER")
	fi
	if [ ! -s "$file" ]; then
		pr "Getting '${file}' from '${url}'"
		_req "$url" "$file" "${args[@]}" -H "Accept: application/octet-stream"
	fi
}

# Fetch a URL to a file only if the file does not exist yet.
fetch() {
	local url=$1 out=$2
	if [ -s "$out" ]; then return 0; fi
	pr "Fetching '${url}'"
	req "$url" "$out"
}
