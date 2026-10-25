# Future plans

Roadmap for making module-builder more reliable and suitable for long-term
support (LTS). "LTS" here means predictable releases, reproducible builds,
supply-chain safety, a stable config format, and a documented support policy.

Items are ordered by impact. Security and release-correctness issues come before
new features.

> Status (2026-10-25): the highest-impact release bugs are fixed. See the
> checked items below. Remaining work is unchanged.

---

## Known bugs (fix first)

These are defects found while auditing the builder and CI workflows.

- [x] **`.mpp` patches get the wrong version in `module.prop`.**
      `module_patches_version()` in `lib/module.sh` stripped only `.jar`, but
      Morphe ships `.mpp`. Fixed by extracting the shared
      `patches_file_version()` helper in `lib/core.sh`, which handles `.jar`,
      `.mpp` and `.apk`.

- [x] **CI update check is unauthenticated.**
      The `Update config` step in `.github/workflows/build.yml` runs
      `--config-update` without `GITHUB_TOKEN`, so it uses GitHub's
      60-requests/hour anonymous limit. The token is now passed to the step.

- [x] **Telegram rejects long messages.**
      `.github/workflows/build.yml` truncated the message to 9450 characters,
      but Telegram `sendMessage` allows 4096. The step now splits messages on
      line boundaries below 4000 characters, uses `curl --fail-with-body`,
      checks the response's `"ok": true`, and fails the job when a chunk is
      rejected.

- [x] **Partial failures still publish a release.**
      `build.sh` only aborted when `build/` was completely empty. `run_jobs`
      now reports failure, and `build.sh` aborts with
      "refusing to publish a partial release" when any job fails.

- [x] **Overlapping runs can create duplicate or wrong tags.**
      Added a repository-wide `build-modules` concurrency group and derived
      the next tag from the numeric maximum of all release tags instead of the
      first row of `gh release list`.

- [ ] **Old module versions show the wrong changelog.**
      `update/build.md` is overwritten every release and every `update.json`
      points to it, so a user on an older version sees the newest notes.

- [ ] **Security and hygiene.**
      `permissions: write-all` in the workflows, actions pinned only by tag,
      committed `ks.keystore` / `ks-p12.keystore` with the default password
      `123456789`, and `eval` in `lib/apk.sh`.

---

## Phase 1 - release correctness

Highest value: a release should never be wrong, partial, or silently fail.

- [x] Fail the job when any app fails, or add `allow-partial = true` and list
      failed apps in the release notes. (Fail-fast is implemented;
      `allow-partial` is not.)
- [x] Add a `concurrency` group (`cancel-in-progress: false`) and
      `timeout-minutes` to the workflows. (Concurrency is implemented;
      `timeout-minutes` is not.)
- [ ] Reduce workflow permissions to `contents: write` (plus only what each
      job actually needs).
- [x] Derive the next tag from the numeric maximum of
      `gh release list --json tagName` and validate it before use.
- [ ] Telegram:
  - [x] keep messages under 4096 characters or split them
  - [ ] use `parse_mode=HTML` with escaping (legacy Markdown breaks on `_`,
        `*`, `[` in app names)
  - [ ] retry with exponential backoff
  - [x] check for `"ok": true` and use `curl --fail-with-body`
  - [ ] optionally support a thread/topic ID for groups
- [ ] Upload `build.md`, job logs, and failed artifacts on failure; write a
      `$GITHUB_STEP_SUMMARY`.
- [ ] Use a meaningful release title (`Release <tag>`) and support a `draft`
      input for testing.
- [x] Include the patches changelog link in release bodies and Telegram
      messages. (Implemented: `Patches changelog:` line in `build.md`.)

---

## Phase 2 - reproducibility and LTS core

- [ ] Add `versions.lock`: record resolved patches/CLI tags, asset URLs and
      SHA-256 after each build, and add `--locked` for CI. Floating `latest`
      and `dev` currently make builds non-reproducible.
- [ ] Publish `SHA256SUMS` and sign it (cosign or minisign). Optionally include
      digests in `update.json`.
- [ ] Add `tools.lock` with checksums for `bin/` binaries and the JDK.
- [ ] Pin GitHub Actions by commit SHA and add Dependabot/Renovate.
- [ ] Keep per-release changelogs (`changelogs/<tag>.md`) and point
      `update.json.changelog` at the immutable release URL instead of the
      moving `build.md`.
- [ ] Give the builder its own semver tags, changelog, support matrix
      (Ubuntu x64, Termux aarch64), and deprecation policy.
- [ ] Move keystores and passwords to repository secrets; fail CI if the
      default template password is used for a real release.

---

## Phase 3 - config safety and developer experience

- [ ] Add `config.schema.json` and make `--check` warn on unknown keys; today
      typos are silently ignored.
- [ ] Validate URLs, arch values, patch names (`included`/`excluded` exist in
      `list-patches`), and module IDs.
- [ ] Add `./build.sh --doctor` (Java version, tools, keystore, disk space,
      GitHub token), `--version`, and `--json` for machine-readable plans.
- [ ] Downloads: retry with exponential backoff, set `--max-time`, resume with
      `curl -C -`, and verify checksums.
- [ ] Replace the `eval` parser in `lib/apk.sh` with a safe tokenizer, or
      restrict it to explicit shell-word parsing.

---

## Phase 4 - quality and maintainability

- [ ] Add `shellcheck` and `shfmt -d` to CI; there is currently no linting.
- [ ] Parallel jobs append to one `build.md`. Collect per-job log fragments and
      merge them in a deterministic order instead of relying on concurrent
      appends.
- [ ] Add a true offline end-to-end build test using stub `java`/`aapt2`
      wrappers; the suite currently tests packaging but not the full patch
      pipeline.
- [ ] The test harness counts every assertion as a test (hence repeated `ok`
      lines). Count test cases once and print sub-assertion failures.
- [ ] Document troubleshooting, the upgrade/migration path, and the supported
      versions policy.

---

## What "LTS-ready" means for this repo

A release is LTS-ready when all of these are true:

- the same config plus lockfile produces the same artifacts
- every download is checksum-verified
- a failed app can never silently publish
- release notes contain patches and CLI versions, the changelog link, app
  versions and checksums
- old module versions keep their original changelog
- CI is concurrency-safe, least-privilege and reproducible
- one command validates the config and the environment

---

## Suggested order of work

1. Known bugs: `.mpp` version, CI token, partial failures, Telegram limits.
2. Phase 1: concurrency, permissions, tag derivation, artifacts.
3. Phase 2: lockfile, checksums, changelog history, action pinning.
4. Phase 3: schema, validation, `--doctor`, download resilience.
5. Phase 4: linting, deterministic logs, end-to-end tests, docs.
