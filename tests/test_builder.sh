#!/usr/bin/env bash
# module-builder - offline test suite
#
# Exercises config loading/inheritance, the source registry, module packaging,
# output-name formatting and `--config-update` without touching the network.
#
# Usage: bash tests/test_builder.sh
#
# Copyright (C) 2026 Shivansh Bansal
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "${TEST_DIR}/.." && pwd)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/mb-tests.XXXXXX")

PASS=0
FAIL=0
SKIP=0
CURRENT=""

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

testcase() { CURRENT=$1; }

pass() {
	PASS=$((PASS + 1))
	printf 'ok   - %s\n' "$CURRENT"
}

fail() {
	FAIL=$((FAIL + 1))
	printf 'FAIL - %s: %s\n' "$CURRENT" "${1:-}"
}

skip() {
	SKIP=$((SKIP + 1))
	printf 'skip - %s: %s\n' "$CURRENT" "${1:-}"
}

assert_eq() {
	local expected=$1 actual=$2
	if [ "$expected" = "$actual" ]; then
		pass
	else
		fail "expected '${expected}', got '${actual}'"
	fi
}

assert_ne() {
	local unexpected=$1 actual=$2
	if [ "$unexpected" != "$actual" ]; then
		pass
	else
		fail "did not expect '${actual}'"
	fi
}

assert_contains() {
	local needle=$1 haystack=$2
	case "$haystack" in
	*"$needle"*) pass ;;
	*) fail "expected '${haystack}' to contain '${needle}'" ;;
	esac
}

assert_not_contains() {
	local needle=$1 haystack=$2
	case "$haystack" in
	*"$needle"*) fail "did not expect '${haystack}' to contain '${needle}'" ;;
	*) pass ;;
	esac
}

assert_file_contains() {
	local file=$1 needle=$2
	if [ ! -f "$file" ]; then
		fail "file not found: ${file}"
	elif grep -qF -- "$needle" "$file"; then
		pass
	else
		fail "expected ${file} to contain '${needle}'"
	fi
}

assert_file_not_contains() {
	local file=$1 needle=$2
	if [ ! -f "$file" ]; then
		fail "file not found: ${file}"
	elif grep -qF -- "$needle" "$file"; then
		fail "did not expect ${file} to contain '${needle}'"
	else
		pass
	fi
}

assert_zip_contains() {
	local zip_file=$1 entry=$2
	if unzip -l "$zip_file" 2>/dev/null | awk '{print $4}' | grep -qxF "$entry"; then
		pass
	else
		fail "expected ${zip_file} to contain ${entry}"
	fi
}

assert_zip_missing() {
	local zip_file=$1 entry=$2
	if unzip -l "$zip_file" 2>/dev/null | awk '{print $4}' | grep -qxF "$entry"; then
		fail "did not expect ${zip_file} to contain ${entry}"
	else
		pass
	fi
}

zip_read() {
	local zip_file=$1 entry=$2
	unzip -p "$zip_file" "$entry" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Sandbox and library loading
# ---------------------------------------------------------------------------

mkdir -p "$SANDBOX"/{temp,build,sources,plugins/sources,plugins/hooks,module-template,extras}
mkdir -p "$SANDBOX"/hooks/{pre-build.d,post-patch.d,post-module.d}

cat >"$SANDBOX/module-template/customize.sh" <<'EOF'
#!/system/bin/sh
# test template
EOF
cat >"$SANDBOX/module-template/service.sh" <<'EOF'
#!/system/bin/sh
# test service
EOF
printf 'extra file\n' >"$SANDBOX/extras/extra.txt"

# Minimal source plugins with deterministic priorities.
write_source_plugin() {
	local file=$1 name=$2 priority=$3 alias=${4-}
	cat >"$file" <<EOF
SOURCE_NAME=${name}
SOURCE_PRIORITY=${priority}
SOURCE_ALIAS_LIST="${alias}"
source_${name}_resp() { return 0; }
source_${name}_pkg_name() { printf 'com.example.${name}'; }
source_${name}_versions() { printf '1.0.0\n1.1.0\n'; }
source_${name}_download() { return 0; }
EOF
}

write_source_plugin "$SANDBOX/plugins/sources/10-alpha.sh" alpha 30 ""
write_source_plugin "$SANDBOX/plugins/sources/20-beta.sh" beta 10 "b"
write_source_plugin "$SANDBOX/plugins/sources/30-gamma.sh" gamma 20 ""
write_source_plugin "$SANDBOX/plugins/sources/40-zeta.sh" zeta 40 ""

export MB_ROOT="$SANDBOX"
export CWD="$SANDBOX"
export TEMP_DIR="temp"
export BUILD_DIR="build"
export BUILD_LOG="build.md"
export BIN_DIR="${PROJECT_ROOT}/bin"
export SOURCES_DIR="sources"
export PLUGIN_DIR="plugins"
export HOOKS_DIR="hooks"
export MODULE_TEMPLATE_DIR="module-template"
export MB_VERBOSE=false
export NEXT_VER_CODE=42
export GITHUB_REPOSITORY="NullDonut/module-builder"
export ENABLE_MODULE_UPDATE=true
export HOOKS_ENABLED=true
export DEF_PATCHES_SRC="Owner/patches"
export DEF_PATCHES_VER="latest"
export DEF_CLI_SRC="Owner/cli"
export DEF_CLI_VER="latest"
export DEF_RV_BRAND="Morphe"

cd "$SANDBOX" || exit 1

# shellcheck source=lib/core.sh
source "${PROJECT_ROOT}/lib/core.sh"
# shellcheck source=lib/config.sh
source "${PROJECT_ROOT}/lib/config.sh"
# shellcheck source=lib/net.sh
source "${PROJECT_ROOT}/lib/net.sh"
# shellcheck source=lib/sources.sh
source "${PROJECT_ROOT}/lib/sources.sh"
# shellcheck source=lib/hooks.sh
source "${PROJECT_ROOT}/lib/hooks.sh"
# shellcheck source=lib/module.sh
source "${PROJECT_ROOT}/lib/module.sh"
# shellcheck source=lib/apk.sh
source "${PROJECT_ROOT}/lib/apk.sh"
# shellcheck source=lib/update.sh
source "${PROJECT_ROOT}/lib/update.sh"

detect_tools

# ---------------------------------------------------------------------------
# Config loading and inheritance
# ---------------------------------------------------------------------------

cat >"$SANDBOX/config-inherit.json" <<'EOF'
{
  "compression-level": 7,
  "module-author": "global-author",
  "Base": {
    "app-name": "Base App",
    "arch": "arm64-v8a",
    "module-description": "base description"
  },
  "Brand": {
    "preset": true,
    "rv-brand": "Morphe",
    "patcher-args": "-e 'Custom branding'"
  },
  "Derived": {
    "inherits": "Base Brand",
    "app-name": "Derived App",
    "module-author": "derived-author"
  },
  "Other": {
    "extends": "Base",
    "app-name": "Other App"
  }
}
EOF

testcase "config loads JSON"
if config_load "$SANDBOX/config-inherit.json"; then pass; else fail "config_load failed"; fi

testcase "config discovers all object tables"
assert_eq "Base Brand Derived Other" "$(printf '%s\n' "${CFG_TABLES[@]}" | sort | paste -sd ' ' -)"

testcase "main keys are separated from app tables"
assert_eq "global-author" "$(config_get "" module-author)"

testcase "preset is detected"
if config_is_preset Brand; then pass; else fail "Brand should be a preset"; fi
testcase "regular table is not a preset"
if config_is_preset Base; then fail "Base should not be a preset"; else pass; fi

testcase "table value overrides global default"
assert_eq "derived-author" "$(config_get_effective Derived module-author)"

testcase "single parent inheritance"
assert_eq "arm64-v8a" "$(config_get_effective Derived arch)"

testcase "multiple parent inheritance"
assert_eq "Morphe" "$(config_get_effective Derived rv-brand)"

testcase "child overrides inherited value"
assert_eq "Derived App" "$(config_get_effective Derived app-name)"

testcase "extends is an alias for inherits"
assert_eq "arm64-v8a" "$(config_get_effective Other arch)"

testcase "inherited nested value survives"
assert_eq "base description" "$(config_get_effective Derived module-description)"

testcase "missing value falls back to caller default"
assert_eq "fallback" "$(config_get_effective Other missing-key fallback)"

testcase "global compression-level is read"
assert_eq "7" "$(config_get_effective "" compression-level)"

testcase "ancestors include the table and both parents"
assert_eq "Base Brand Derived" "$(config_ancestors Derived | sort | paste -sd ' ' -)"

testcase "config_to_json keeps requested tables and main keys"
kept=$(config_to_json Derived)
assert_eq "1" "$(jq -r 'has("Derived") | if . then 1 else 0 end' <<<"$kept")"
assert_eq "0" "$(jq -r 'has("Other") | if . then 1 else 0 end' <<<"$kept")"
assert_eq "7" "$(jq -r '."compression-level"' <<<"$kept")"

cat >"$SANDBOX/config-cycle.json" <<'EOF'
{"A": {"inherits": "B"}, "B": {"inherits": "A"}}
EOF
testcase "inheritance cycles are rejected"
cycle_out=$( (config_load "$SANDBOX/config-cycle.json" && config_resolve_table A) 2>&1)
cycle_rc=$?
assert_eq "1" "$cycle_rc"
assert_contains "cycle" "$cycle_out"

cat >"$SANDBOX/config-invalid.json" <<'EOF'
{"Bad": {"build-mode": "nope"}}
EOF
testcase "invalid build-mode is rejected"
invalid_out=$( (config_load "$SANDBOX/config-invalid.json" && config_validate_table Bad) 2>&1)
invalid_rc=$?
assert_eq "1" "$invalid_rc"
assert_contains "build-mode" "$invalid_out"

testcase "TOML config loads and inherits"
cat >"$SANDBOX/config-mini.toml" <<'EOF'
compression-level = 5

[Preset]
preset = true
arch = "arm64-v8a"

[App]
inherits = "Preset"
app-name = "Toml App"
EOF
if [ -n "${TOML_BIN-}" ] && [ -x "$TOML_BIN" ]; then
	if config_load "$SANDBOX/config-mini.toml"; then
		assert_eq "Toml App" "$(config_get_effective App app-name)"
	else
		fail "config_load failed for TOML"
	fi
else
	skip "no TOML parser available"
fi

# ---------------------------------------------------------------------------
# Source registry
# ---------------------------------------------------------------------------

cat >"$SANDBOX/config-sources.json" <<'EOF'
{
  "AlphaApp": {
    "enabled": true,
    "alpha-dlurl": "https://example.test/alpha",
    "beta-dlurl": "https://example.test/beta"
  },
  "ExplicitApp": {
    "enabled": true,
    "download-sources": "b zeta",
    "zeta-dlurl": "https://example.test/zeta"
  },
  "BadSource": {
    "enabled": true,
    "download-sources": "nope"
  },
  "EmptyApp": {"enabled": true}
}
EOF

config_load "$SANDBOX/config-sources.json"
load_sources

testcase "sources are ordered by priority"
assert_eq "beta gamma alpha zeta" "${DEFAULT_SOURCE_LIST[*]}"

testcase "source_names_for only returns configured sources"
assert_eq "beta alpha" "$(source_names_for AlphaApp | paste -sd ' ' -)"

testcase "explicit download-sources controls order"
assert_eq "beta zeta" "$(source_names_for ExplicitApp | paste -sd ' ' -)"

testcase "source aliases resolve to canonical names"
assert_eq "beta" "$(source_canonical b)"

testcase "source_names_for skips apps with no URLs"
assert_eq "" "$(source_names_for EmptyApp)"

testcase "unknown source names are rejected"
unknown_out=$( (source_names_for BadSource) 2>&1)
unknown_rc=$?
assert_ne "0" "$unknown_rc"
assert_contains "Unknown download source" "$unknown_out"

testcase "source URL trailing slash is normalised"
assert_eq "https://example.test/beta" "$(source_url AlphaApp beta)"

# ---------------------------------------------------------------------------
# Output names
# ---------------------------------------------------------------------------

testcase "output name placeholders are expanded"
MB_PKG_NAME="com.example.test"
assert_eq "my-app-my-app-morphe-v1.2.3-arm64-v8a-module-com.example.test" \
	"$(format_output_name '{table}-{app}-{brand}-v{version}-{arch}-{kind}-{pkg}' \
		'My App' 'My App' 'Morphe' '1.2.3' 'arm64-v8a' 'module')"

testcase "version placeholder strips a leading v"
assert_eq "app-v1.2.3" "$(format_output_name '{app}-v{version}' 'App' 'App' 'Morphe' 'v1.2.3' 'arm64-v8a' 'apk')"

testcase "app_name is an alias for app"
assert_eq "my-app" "$(format_output_name '{app_name}' 'My App' 'My App' 'Morphe' '1.0' 'arm64-v8a' 'apk')"

# ---------------------------------------------------------------------------
# Module packaging
# ---------------------------------------------------------------------------

cat >"$SANDBOX/config-module.json" <<'EOF'
{
  "enable-module-update": true,
  "hooks-enabled": true,
  "Base": {"preset": true, "arch": "arm64-v8a"},
  "TestApp": {
    "inherits": "Base",
    "app-name": "Test App",
    "module-name": "Test Module",
    "module-id": "com.example.test",
    "module-description": "A test module",
    "extra-module-files": "extras"
  },
  "DefaultApp": {
    "app-name": "Default App"
  }
}
EOF

config_load "$SANDBOX/config-module.json"
load_sources

printf 'PK' >"$SANDBOX/temp/stock.apk"
printf 'PA' >"$SANDBOX/temp/patched.apk"
printf 'JAR' >"$SANDBOX/temp/patches-1.2.3.jar"
printf 'CLI' >"$SANDBOX/temp/cli.jar"

cat >"$SANDBOX/hooks/post-module.d/10-record.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s\n' "\$MB_TABLE" "\$MB_MODULE_ID" "\$MB_ARCH" "\$MB_VERSION" "\$MB_MODULE_ZIP" >"${SANDBOX}/hook.log"
EOF

testcase "hooks default to enabled when HOOKS_ENABLED is unset"
hooks_out=$( (unset HOOKS_ENABLED; run_hooks post-patch TestApp "Test App" com.example.test \
	1.0.0 arm64-v8a apk "" "" "" "" "" "" "" "") 2>&1)
hooks_rc=$?
assert_eq "0" "$hooks_rc"

testcase "default module id uses the author suffix"
assert_eq "defaultapp-shivanshbansal" "$(module_id_base DefaultApp)"
testcase "module id gets an arch suffix"
assert_eq "defaultapp-shivanshbansal-arm64" "$(module_id_for DefaultApp arm64-v8a)"

testcase "module packaging succeeds"
package_out=$(package_module TestApp "Test App" com.example.test 1.0.0 arm64-v8a \
	temp/stock.apk temp/patched.apk Morphe temp/patches-1.2.3.jar \
	temp/cli.jar "" merged '{app}-{brand}-module-v{version}-{arch}.zip')
package_rc=$?
module_zip=$(printf '%s\n' "$package_out" | tail -1)
assert_eq "0" "$package_rc"
if [ -f "$module_zip" ]; then pass; else fail "module zip not found: ${module_zip}"; fi

testcase "module zip contains the expected files"
assert_zip_contains "$module_zip" "base.apk"
assert_zip_contains "$module_zip" "stock/base.apk"
assert_zip_contains "$module_zip" "extra.txt"
assert_zip_contains "$module_zip" "customize.sh"
assert_zip_contains "$module_zip" "service.sh"

testcase "module.prop has the expected metadata"
module_prop=$(zip_read "$module_zip" module.prop)
assert_contains "id=com.example.test-arm64" "$module_prop"
assert_contains "name=Test Module" "$module_prop"
assert_contains "version=1.0.0 (patches 1.2.3)" "$module_prop"
assert_contains "versionCode=42" "$module_prop"
assert_contains "author=shivanshbansal" "$module_prop"
assert_contains "description=A test module" "$module_prop"
assert_contains "updateJson=https://raw.githubusercontent.com/NullDonut/module-builder/update/testapp-arm64-update.json" "$module_prop"

testcase "module config has the expected values"
module_config=$(zip_read "$module_zip" config)
assert_contains "PKG_NAME='com.example.test'" "$module_config"
assert_contains "MODULE_ARCH='arm64'" "$module_config"
assert_contains "MODULE_ID='com.example.test-arm64'" "$module_config"

testcase "post-module hook receives module metadata"
assert_file_contains "$SANDBOX/hook.log" "TestApp|com.example.test-arm64|arm64-v8a|1.0.0|${module_zip}"

testcase "include-stock=disable omits the stock APK"
unset ENABLE_MODULE_UPDATE
package_out2=$(package_module TestApp "Test App" com.example.test 1.0.0 arm64-v8a \
	temp/stock.apk temp/patched.apk Morphe temp/patches-1.2.3.jar \
	temp/cli.jar "" disable '{table}-nostock-{arch}.zip')
module_zip2=$(printf '%s\n' "$package_out2" | tail -1)
assert_zip_contains "$module_zip2" "base.apk"
assert_zip_missing "$module_zip2" "stock/base.apk"

testcase "module update is disabled when the global flag is unset"
module_prop2=$(zip_read "$module_zip2" module.prop)
assert_not_contains "updateJson=" "$module_prop2"

testcase "extra-module-files paths must exist"
cat >"$SANDBOX/config-bad-extra.json" <<'EOF'
{"Broken": {"app-name": "Broken", "extra-module-files": "does-not-exist"}}
EOF
config_load "$SANDBOX/config-bad-extra.json"
bad_extra_out=$(package_module Broken "Broken" com.example.broken 1.0.0 arm64-v8a \
	temp/stock.apk temp/patched.apk Morphe temp/patches-1.2.3.jar \
	temp/cli.jar "" disable '{table}.zip' 2>&1)
assert_ne "0" "$?"

# ---------------------------------------------------------------------------
# config_update (mocked GitHub API)
# ---------------------------------------------------------------------------

gh_req() {
	local url=$1
	case "$url" in
	"https://api.github.com/repos/Owner/patches/releases")
		printf '%s' '[{"tag_name":"v1.2.2"},{"tag_name":"v1.2.3"}]'
		;;
	"https://api.github.com/repos/Owner/patches/releases/latest")
		printf '%s' '{"tag_name":"v1.2.3","assets":[{"name":"patches-1.2.3.jar.asc"},{"name":"patches-1.2.3.jar"},{"name":"patches-1.2.3.json"}]}'
		;;
	"https://api.github.com/repos/Owner/patches/releases/tags/v1.2.3")
		printf '%s' '{"tag_name":"v1.2.3","assets":[{"name":"patches-1.2.3.jar"}]}'
		;;
	"https://api.github.com/repos/Owner/patches2/releases/latest")
		printf '%s' '{"tag_name":"v2.0.0","assets":[{"name":"patches-2.0.0.jar"}]}'
		;;
	"https://api.github.com/repos/Owner/cli/releases/latest")
		printf '%s' '{"tag_name":"v9.9.9","assets":[{"name":"morphe-desktop-9.9.9-all.jar"},{"name":"morphe-desktop-9.9.9-all.jar.asc"}]}'
		;;
	"https://api.github.com/repos/Owner/multi/releases/latest")
		printf '%s' '{"tag_name":"v1.3.0","assets":[{"name":"patches-1.3.0-dev.1.jar"},{"name":"patches-1.3.0.jar"},{"name":"patches-1.3.0.jar.asc"}]}'
		;;
	*)
		return 1
		;;
	esac
}

clear_update_cache() { __UPDATE_ASSET_CACHE=(); }

testcase "release asset is normalised for patches"
clear_update_cache
assert_eq "patches-1.2.3.jar" "$(release_asset_name patches Owner/patches latest)"

testcase "release asset keeps the CLI asset name"
clear_update_cache
assert_eq "morphe-desktop-9.9.9-all.jar" "$(release_asset_name cli Owner/cli latest)"

testcase "dev patches resolve to the highest tag"
clear_update_cache
assert_eq "patches-1.2.3.jar" "$(release_asset_name patches Owner/patches dev)"

testcase "non-dev asset is preferred over a dev asset"
clear_update_cache
assert_eq "patches-1.3.0.jar" "$(release_asset_name patches Owner/multi latest)"

testcase "unknown releases fail cleanly"
clear_update_cache
if release_asset_name patches Owner/unknown latest >/dev/null 2>&1; then
	fail "expected failure for an unknown release"
else
	pass
fi

cat >"$SANDBOX/config-update.json" <<'EOF'
{
  "patches-source": "Owner/patches",
  "cli-source": "Owner/cli",
  "BasePreset": {"preset": true, "arch": "arm64-v8a"},
  "AppOne": {"inherits": "BasePreset", "enabled": true},
  "AppTwo": {"enabled": true, "patches-source": "Owner/patches2"},
  "DisabledApp": {"enabled": false}
}
EOF

config_load "$SANDBOX/config-update.json"

testcase "config_update prints nothing when everything is current"
cat >"$SANDBOX/build-current.md" <<'EOF'
Patches: Owner/patches/patches-1.2.3.jar
Patches: Owner/patches2/patches-2.0.0.jar
CLI: Owner/cli/morphe-desktop-9.9.9-all.jar
EOF
BUILD_LOG="$SANDBOX/build-current.md"
clear_update_cache
update_out=$(config_update)
assert_eq "" "$update_out"

testcase "config_update reports only changed apps"
cat >"$SANDBOX/build-partial.md" <<'EOF'
Patches: Owner/patches/patches-1.2.3.jar
CLI: Owner/cli/morphe-desktop-9.9.9-all.jar
EOF
BUILD_LOG="$SANDBOX/build-partial.md"
clear_update_cache
update_out=$(config_update)
assert_eq "AppTwo" "$(jq -r '[keys[] | select(. == "AppTwo" or . == "AppOne" or . == "BasePreset" or . == "DisabledApp")] | sort | join(" ")' <<<"$update_out")"

testcase "config_update includes inherited presets"
cat >"$SANDBOX/build-empty.md" <<'EOF'
EOF
BUILD_LOG="$SANDBOX/build-empty.md"
clear_update_cache
update_out=$(config_update)
assert_eq "AppOne AppTwo BasePreset" "$(jq -r '[keys[] | select(. == "AppOne" or . == "AppTwo" or . == "BasePreset" or . == "DisabledApp")] | sort | join(" ")' <<<"$update_out")"

testcase "a changed CLI alone triggers an update"
cat >"$SANDBOX/build-cli.md" <<'EOF'
Patches: Owner/patches/patches-1.2.3.jar
Patches: Owner/patches2/patches-2.0.0.jar
CLI: Owner/cli/morphe-desktop-9.9.8-all.jar
EOF
BUILD_LOG="$SANDBOX/build-cli.md"
clear_update_cache
update_out=$(config_update)
assert_eq "AppOne AppTwo" "$(jq -r '[keys[] | select(. == "AppOne" or . == "AppTwo")] | sort | join(" ")' <<<"$update_out")"

testcase "config_update fails when the build log is missing"
BUILD_LOG="$SANDBOX/no-such-build.md"
clear_update_cache
missing_out=$(config_update 2>&1)
assert_ne "0" "$?"
assert_contains "build.md is not available" "$missing_out"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL > 0)); then
	exit 1
fi
exit 0
