# module-builder

A configurable, modular builder for patched Android APKs and flashable
**Magisk / KernelSU** modules. It is inspired by
[revanced-morphe-builder](https://github.com/peternmuller/revanced-morphe-builder)
and keeps the same `config.toml` keys while adding a plugin registry, reusable
presets, hooks and per-app output settings.

Author: **shivanshbansal** — [github.com/NullDonut](https://github.com/NullDonut)

## Features

- Builds **APKs**, **modules**, or both (`build-mode = "both"`).
- Same config keys as revanced-morphe-builder; existing `config.toml` files work.
- Reusable presets and table inheritance (`inherits = "Base"`).
- Pluggable download sources in `sources/` and `plugins/sources/`.
- Hooks before builds, after patching and after module packaging.
- Per-app module IDs, names, descriptions, templates and output filenames.
- Optional local stock APK (`stock-apk`) for offline or pre-downloaded builds.
- Signature verification against `sig.txt`.
- GitHub Actions CI, scheduled rebuilds, release uploads and `update.json`.
- Termux bootstrap script.

## Quick start

```bash
git clone https://github.com/NullDonut/module-builder --depth 1
cd module-builder
cp config.example.toml config.toml
# edit config.toml, then:
./build.sh
```

On Termux:

```bash
bash <(curl -sSf https://raw.githubusercontent.com/NullDonut/module-builder/main/build-termux.sh)
```

Outputs are written to `build/`.

## Requirements

- `bash` 5.1+ (for optional parallel jobs)
- `jq`, `curl`, `zip`, `unzip`, a JDK (21+)
- The bundled `bin/` tools: `tq` (TOML), `htmlq`, `aapt2`, `apksigner.jar`

On Termux:

```bash
pkg install jq curl zip unzip openjdk-21 aapt2
```

## Commands

```bash
./build.sh                         # build all enabled apps
./build.sh --check                 # validate config and show the plan
./build.sh --list                  # show effective settings per app
./build.sh --dry-run               # show jobs without downloading
./build.sh --app YouTube           # build one app table
./build.sh --jobs 2 --verbose      # parallel jobs and command logging
./build.sh --no-hooks              # disable hooks for this run
./build.sh clean                   # remove temp/, build/ and build.md
./build.sh config.toml --config-update > config.json
```

`--config-update` prints a JSON config only when a configured patches release
is not present in `build.md`. CI uses it to rebuild and release only when the
Morphe patches version changes. A new CLI release for the same patches version
does **not** trigger a release; rebuilds with unchanged versions must be started
manually with the **Build Modules** workflow.

## Tests

```bash
bash tests/test_builder.sh
```

The suite is offline: it loads JSON and TOML configs, checks inheritance and
presets, exercises the source registry, packages a module with a fake APK,
verifies output names and hooks, and mocks the GitHub API for
`--config-update`.

## Configuration

See [CONFIG.md](CONFIG.md) for every key. The short version:

```toml
[YouTube]
app-name = "YouTube"
build-mode = "both"
arch = "all"
version = "auto"
direct-dlurl = "https://host/com.google.android.youtube-21.20.405-all.apk"
patches-source = "MorpheApp/morphe-patches"
cli-source = "MorpheApp/morphe-cli"
```

Adding an app is just another table. Reuse settings with a preset:

```toml
[Base]
preset = true
patches-source = "MorpheApp/morphe-patches"
cli-source = "MorpheApp/morphe-cli"
rv-brand = "Morphe-dev"

[YouTube]
inherits = "Base"
direct-dlurl = "https://host/com.google.android.youtube-21.20.405-all.apk"
```

## Download source plugins

A source is a shell file that implements four functions:

```bash
SOURCE_NAME=mysource
SOURCE_PRIORITY=50
SOURCE_ALIAS_LIST="myalias"   # optional

source_mysource_resp() { ...; }        # fetch metadata
source_mysource_pkg_name() { ...; }    # print package name
source_mysource_versions() { ...; }    # print one version per line
source_mysource_download() { ...; }    # download to $3
```

Drop it in `plugins/sources/` and configure it with `mysource-dlurl`:

```toml
[SomeApp]
mysource-dlurl = "https://example.com/app"
```

Sources are tried in priority order. Set `download-sources` globally or per app
to restrict/reorder them.

## Hooks

Hooks are trusted shell scripts. They receive `MB_*` environment variables and
run for each build variant.

```
hooks/pre-build.d/*.sh
hooks/post-patch.d/*.sh
hooks/post-module.d/*.sh
plugins/hooks/<phase>.d/*.sh
```

Per-app hooks:

```toml
[SomeApp]
pre-build-hook = "hooks/some-pre.sh"
post-patch-hook = "hooks/some-post-patch.sh"
post-module-hook = "hooks/some-post-module.sh"
```

Useful variables: `MB_TABLE`, `MB_APP_NAME`, `MB_PKG_NAME`, `MB_VERSION`,
`MB_ARCH`, `MB_BUILD_MODE`, `MB_STOCK_APK`, `MB_PATCHED_APK`, `MB_MODULE_DIR`,
`MB_MODULE_ZIP`, `MB_MODULE_ID`.

## Module template

The default template lives in `module/`. A per-app template can be selected with
`module-template = "path/to/template"`. The builder writes `config` and
`module.prop` into the template copy, then zips it.

## Notifications

The build workflow can post release links to Telegram. Configure:

- `TG_TOKEN` — repository **secret** containing the bot token.
- `TG_CHAT_ID` — repository **variable** with a numeric chat ID or
  `@channelusername`. The bot must be a member/admin of that chat.

`TG_BOTNAME` is still read as a fallback for existing setups, but a bot name is
**not** a chat ID. There is currently **no Instagram (IG) integration**; only
Telegram is implemented.

Each release body (which is also the Telegram message) includes a
`Patches changelog:` line linking to the upstream patches release notes for the
resolved version, e.g.
`https://github.com/MorpheApp/morphe-patches/releases/tag/v1.49.0-dev.5`.

## Credits

- [revanced-morphe-builder](https://github.com/peternmuller/revanced-morphe-builder)
  by Peter Noël Muller — the original design and much of the build logic.
- [j-hc](https://github.com/j-hc) for the original builder lineage.
- The [ReVanced](https://github.com/ReVanced), [anddea](https://github.com/anddea)
  and [Morphe](https://github.com/MorpheApp) teams.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

```
Copyright (C) 2024-2026 Peter Noël Muller
Copyright (C) 2026 Shivansh Bansal
```
