# Config reference

`module-builder` accepts a TOML file (default `config.toml`) or a JSON file.
Every table other than the root table is an app, unless it is marked as a preset.
All keys are optional except that each enabled app needs at least one download
source (`<source>-dlurl`) or a local `stock-apk`.

> [!WARNING]
> When a patch name itself contains a single quote, double it inside the string
> (for example `'Hide ''Get Music Premium'''`).

## Minimal app

```toml
[Some-App]
apkmirror-dlurl = "https://www.apkmirror.com/apk/vendor/some-app"
```

## Global keys

These live at the top of the file (outside any `[table]`) and are defaults for
every app.

| Key | Default | Description |
| --- | --- | --- |
| `parallel-jobs` | `1` | Number of app/arch jobs to run at once. |
| `compression-level` | `9` | Module zip compression level, 0-9. |
| `remove-rv-integrations-checks` | `true` | Patch the ReVanced integrations checks out of the patches bundle. |
| `enable-module-update` | `true` | Write `updateJson=` into `module.prop` when a GitHub repo is available. |
| `hooks-enabled` | `true` | Run hooks. |
| `verify-signature` | `true` | Verify the stock APK against `sig.txt`. |
| `patches-source` | `ReVanced/revanced-patches` | GitHub repo for the patches bundle. |
| `cli-source` | `ReVanced/revanced-cli` | GitHub repo for the patcher CLI. |
| `patches-version` | `latest` | `latest`, `dev`, or a tag/version. |
| `cli-version` | `latest` | `latest`, `dev`, or a tag/version. |
| `rv-brand` | `ReVanced` | Brand name used in APK/module names and patch behavior. |
| `dpi` | `nodpi anydpi` | DPI variants to search, in order. |
| `download-sources` | plugin order | Restrict/reorder source names, e.g. `"direct apkmirror"`. |
| `keystore` | `ks.keystore` | APK signing keystore. |
| `keystore-password` | `123456789` | Keystore password. |
| `keystore-entry-password` | same as keystore password | Key password. |
| `signer` | `jhc` | apksigner signer name. |
| `keystore-entry-alias` | `jhc` | Key alias. |
| `merge-keystore` | `ks-p12.keystore` | Keystore used when merging split APKs. |
| `merge-keystore-password` | `123456789` | Merge keystore password. |
| `merge-key-password` | `123456789` | Merge key password. |
| `merge-keystore-alias` | `jhc` | Merge key alias. |
| `apk-name-format` | `{app}-{brand}-v{version}-{arch}.apk` | APK output template. |
| `module-name-format` | `{app}-{brand}-module-v{version}-{arch}.zip` | Module output template. |
| `update-json-base-url` | GitHub raw `update` branch | Base URL for `updateJson`. |

## App keys

| Key | Default | Description |
| --- | --- | --- |
| `app-name` | table name | Display name used in filenames and `module.prop`. |
| `enabled` | `true` | Build this app. |
| `build-mode` | `apk` | `both`, `apk` or `module`. |
| `version` | `auto` | `auto`, `experimental`, `latest`, or an explicit version. |
| `arch` | `all` | `all`, `both`, `arm64-v8a`, `arm-v7a`, `x86`, `x86_64`. `both` builds arm64 and arm. |
| `include-stock` | `merged` | `merged`, `split` or `disable`. Stock APK included in the module. |
| `pkg-name` | auto | Package name. Normally detected from the download source. |
| `dpi` | global | DPI preference for APKMirror/Uptodown. |
| `excluded-patches` | empty | Quoted, whitespace-separated patch names to exclude. |
| `included-patches` | empty | Quoted, whitespace-separated non-default patches to include. |
| `exclusive-patches` | `false` | Start with all patches excluded. |
| `patcher-args` | empty | Extra CLI arguments, e.g. `-OappIcon=original`. |
| `enable-update-checks` | `false` | Add an update-check patch to APK builds. |
| `update-check-patch-url` | empty | URL of a `.mpp` update-check patch. |
| `module-id` | `<table>-shivanshbansal` | Module ID (alias: `module-prop-name`). |
| `module-name` | `<app-name> <rv-brand>` | `module.prop` name. |
| `module-version` | `<version> (patches <patches>)` | `module.prop` version. |
| `module-author` | `shivanshbansal` | `module.prop` author. |
| `module-description` | `<app-name> <rv-brand> module` | `module.prop` description. |
| `module-template` | `module` | Template directory copied into the module. |
| `extra-module-files` | empty | Files/directories copied into the module root. |
| `update-json-name` | `<table>[-arch]-update.json` | Name of the update JSON file. |
| `update-json-base-url` | global | Per-app override of the update JSON base URL. |
| `enable-module-update` | global | Per-app override for `updateJson`. |
| `hooks-enabled` | global | Per-app override for hooks. |
| `apk-name-format` | global | Per-app APK filename template. |
| `module-name-format` | global | Per-app module filename template. |
| `compression-level` | global | Per-app module compression. |
| `stock-apk` | empty | Use a local stock APK instead of downloading one. |
| `pre-build-hook` | empty | Hook before the app build starts. |
| `post-patch-hook` | empty | Hook after the patched APK is produced. |
| `post-module-hook` | empty | Hook after the module zip is produced. |
| `extra-hooks` | empty | Additional hooks run in every phase. |
| `download-sources` | global | Per-app source restriction/reorder. |
| `<source>-dlurl` | empty | URL for a download source plugin. |

### Version modes

- `auto` — highest version supported by all included patches.
- `experimental` — same, but includes experimental patches.
- `latest` — highest stable version available from the download source,
  without checking patch compatibility.
- explicit — use exactly this version (for example `21.20.405`).

### Output placeholders

`apk-name-format` and `module-name-format` support:

| Placeholder | Value |
| --- | --- |
| `{table}` | Config table name, sanitized. |
| `{app}`, `{app_name}` | `app-name`, sanitized and lowercased. |
| `{brand}` | `rv-brand`, sanitized and lowercased. |
| `{version}` | Resolved version. |
| `{arch}` | Architecture. |
| `{kind}` | `apk` or `module`. |
| `{pkg}` | Package name. |

## Presets and inheritance

A table marked `preset = true` is not built. Any app can inherit from one or
more tables with `inherits` (or `extends`). Values are deep-merged in order:
parents first, then the child.

```toml
[Base]
preset = true
patches-source = "MorpheApp/morphe-patches"
cli-source = "MorpheApp/morphe-cli"
rv-brand = "Morphe-dev"
build-mode = "both"

[YouTube]
inherits = "Base"
direct-dlurl = "https://host/com.google.android.youtube-21.20.405-all.apk"

[YT-Music]
inherits = "Base"
direct-dlurl = "https://host/com.google.android.apps.youtube.music-9.20.53-arm64-v8a.apk"
```

Multiple parents: `inherits = "Base Extra"`. Cycles are detected and abort the
build.

## Download source plugins

The bundled sources are:

| Source | Config key | Notes |
| --- | --- | --- |
| `direct` | `direct-dlurl` | URL must end in `<package>-<version>-<arch>.apk` or `.apkm`. |
| `archive` | `archive-dlurl` | archive.org item directory. |
| `apkmirror` | `apkmirror-dlurl` | Uses `dpi` and `arch` to pick a variant. |
| `uptodown` | `uptodown-dlurl` | Uses `dpi` and `arch` to pick a variant. |

A plugin lives in `sources/` or `plugins/sources/` and must set `SOURCE_NAME`
and implement:

```bash
source_<name>_resp <url>        # set whatever globals you need
source_<name>_pkg_name          # print the package name
source_<name>_versions          # print one version per line
source_<name>_download <url> <version> <output> <arch> <dpi>
```

Optional metadata:

```bash
SOURCE_PRIORITY=50              # lower runs first
SOURCE_ALIAS_LIST="alias1 alias2"
```

If a source downloads a split bundle (`.apkm`/`.xapk`), call `merge_splits
"${output}.apkm" "$output"` after downloading.

## Hooks

Hooks are sourced/executed with `bash` and are trusted. They run for each app
and architecture variant.

```
hooks/pre-build.d/*.sh
hooks/post-patch.d/*.sh
hooks/post-module.d/*.sh
plugins/hooks/<phase>.d/*.sh
```

They receive:

`MB_PROJECT_ROOT`, `MB_CONFIG_FILE`, `MB_PHASE`, `MB_TABLE`, `MB_APP_NAME`,
`MB_PKG_NAME`, `MB_VERSION`, `MB_ARCH`, `MB_BUILD_MODE`, `MB_STOCK_APK`,
`MB_PATCHED_APK`, `MB_MODULE_DIR`, `MB_MODULE_ZIP`, `MB_MODULE_ID`,
`MB_RV_BRAND`, `MB_PATCHER_ARGS`.

A non-zero hook exit aborts that build variant.

## Module template

The template is copied to a temporary directory. The builder then writes:

- `config` — `PKG_NAME`, `PKG_VER`, `MODULE_ARCH`, `MODULE_ID`, `MODULE_NAME`,
  `MODULE_AUTHOR`.
- `module.prop` — `id`, `name`, `version`, `versionCode`, `author`,
  `description`, and optional `updateJson`.

It also copies the patched APK to `base.apk`, optionally copies the stock APK to
`stock/`, and copies `extra-module-files`.

The default template's installer supports Magisk and KernelSU, mounts the APK,
extracts native libraries, and handles system-app debloating.

## Signature verification

`sig.txt` contains lines in the form:

```
<sha256> <package.name>
```

If a package is listed, the stock APK signature must match. If the package is
not listed, verification is skipped. Disable globally with
`verify-signature = false`.
