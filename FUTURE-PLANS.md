# Future plans

Roadmap for making module-builder more reliable and suitable for long-term
support (LTS). "LTS" here means predictable releases, reproducible builds,
supply-chain safety, a stable config format, and a documented support policy.

Items are ordered by impact. Security and release-correctness issues come before
new features.

Scope: module-builder owns downloading, patching and packaging. Runtime symptoms
of the patched apps (sign-in, playback, buffering, account state) belong to the
patch projects, the device/root setup, or the user's network. They should not
trigger a rewrite of the builder.

> Status (2026-11-07): the highest-impact release bugs are fixed. Runtime
> reports were triaged as external (see below). CI now keeps per-release
> changelogs, uses least-privilege permissions, pinned actions and timeouts.
> The remaining LTS backlog is tracked in Phase 5.

---

## Runtime triage (not builder bugs)

Reports against built APKs/modules that were investigated and found to be
outside the builder. Keep these here so they are not re-opened as builder
defects.

- [x] **Sign-in failures and slow video buffering (2026-11-07).**
      Reported on a poor village connection for the YouTube and YT Music
      modules. Root modules install the stock APK and bind-mount the patched
      APK, so package identity/signature and Google sign-in stay intact; the
      builder does not touch accounts or playback networking. An equivalent
      upstream Morphe report
      ([MorpheApp/morphe-patches#4113](https://github.com/MorpheApp/morphe-patches/issues/4113))
      found the same buffering on stock YouTube and the web client, and was
      resolved after the reporter contacted their ISP. Conclusion: carrier or
      local network issue, not a builder defect. Do not change build config or
      download logic for this class of report.

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

- [x] **Old module versions show the wrong changelog.**
      Each release now writes `changelogs/<versionCode>.md` on the `update`
      branch, and `update.json.changelog` points at that immutable file instead
      of the moving `build.md`.

- [ ] **Security and hygiene.**
      `permissions: write-all` in the workflows, actions pinned only by tag,
      committed `ks.keystore` / `ks-p12.keystore` with the default password
      `123456789`, and `eval` in `lib/apk.sh`. (Workflow permissions are now
      least-privilege, actions are pinned by SHA and Dependabot is enabled;
      keystore handling and `eval` remain.)

---

## Phase 1 - release correctness

Highest value: a release should never be wrong, partial, or silently fail.

- [x] Fail the job when any app fails, or add `allow-partial = true` and list
      failed apps in the release notes. (Fail-fast is implemented;
      `allow-partial` is not.)
- [x] Add a `concurrency` group (`cancel-in-progress: false`) and
      `timeout-minutes` to the workflows. (Both are implemented.)
- [x] Reduce workflow permissions to `contents: write` (plus only what each
      job actually needs).
- [x] Derive the next tag from the numeric maximum of
      `gh release list --json tagName` and validate it before use.
- [ ] Telegram:
  - [x] keep messages under 4096 characters or split them
  - [ ] use `parse_mode=HTML` with escaping (legacy Markdown breaks on `_`,
        `*`, `[` in app names)
  - [x] retry with exponential backoff
  - [x] check for `"ok": true` and use `curl --fail-with-body`
  - [x] optionally support a thread/topic ID for groups
- [ ] Upload `build.md`, job logs, and failed artifacts on failure; write a
      `$GITHUB_STEP_SUMMARY`. (The step summary is implemented; artifacts and
      job logs are not.)
- [x] Use a meaningful release title (`Release <tag>`) and support a `draft`
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
- [x] Pin GitHub Actions by commit SHA and add Dependabot/Renovate.
- [x] Keep per-release changelogs (`changelogs/<tag>.md`) and point
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

## Phase 5 - LTS operations and supply chain

Phases 1-4 make builds correct, reproducible and testable. LTS also needs
artifacts that can be verified after release, a predictable upgrade/rollback
path, and a documented support window. Treat this phase as the backlog for the
LTS release line; it can land after the core pipeline is stable.

### Release governance and channels

- [ ] Define `stable` and `edge` channels, with separate release tags or
      metadata, so testers are not forced onto every dev patch release.
- [ ] Publish a support policy: supported builder versions, patch/CLI ranges,
      platforms (Ubuntu x64, Termux aarch64), root managers and an EOL date.
- [ ] Keep a release checklist covering config validation, smoke tests,
      changelog generation, checksum verification and Telegram delivery.
- [ ] Automate release notes from commits/PR labels, and keep a curated
      changelog for breaking config changes.
- [ ] Define a rollback/yank procedure for a bad release, including how to
      remove assets and how modules recover on the next update check.
- [ ] Retain release artifacts and changelogs for at least the supported
      window, not only the latest version.

### Artifact integrity and provenance

- [ ] Publish `SHA256SUMS` for every release and attach it to the release.
- [ ] Sign checksum files and `update.json` metadata (minisign or cosign),
      and document how users and the module updater can verify them.
- [ ] Add SLSA-style build provenance / GitHub artifact attestations so a
      downloaded module can be traced back to the workflow and commit.
- [ ] Verify the upstream patches bundle signature (Morphe `.mpp`
      `MorpheSig1`) before patching, and fail closed when it is invalid.
- [ ] Include `sha256`, `size`, `releaseDate`, `minVersionCode` and `channel`
      in `update.json`, not just version, URL and changelog.
- [ ] Add a `--verify-release` mode that checks an existing release directory
      or URL against the published checksums.

### Upgrade, rollback and compatibility

- [ ] Version the builder config (`config-version`) and add migrations plus
      deprecation warnings for renamed or removed keys.
- [ ] Keep module IDs and output filenames stable across upgrades; document
      any intentional rename and provide a migration note.
- [ ] Define downgrade behavior: `versionCode` must stay monotonic, and an
      older module must not be offered as an "update" over a newer install.
- [ ] Publish a compatibility table for builder version, config version,
      patches/CLI versions and supported Android/root setups.
- [ ] Add tests that load pinned historical configs and verify they still
      resolve to the same effective settings.

### Build environment reproducibility

- [ ] Pin the JDK distribution/version, Ubuntu runner image and Termux package
      set by version and checksum, not only by major tag.
- [ ] Add a reproducibility check that builds the same config twice and
      compares artifact hashes (excluding signatures if they are timestamped).
- [ ] Run the test suite on both supported platforms (Ubuntu x64 and Termux
      aarch64) in CI; the Termux path is currently bootstrap-only.
- [ ] Add per-app timeouts and cancellation so a hung patch or download cannot
      consume the whole job budget.
- [ ] Cache immutable downloads and tools, and verify cache entries against
      the lockfile before reuse.

### Security and operations

- [ ] Generate an SBOM for the builder and include the resolved patches/CLI
      versions in it.
- [ ] Add CodeQL, OpenSSF Scorecard, secret scanning and dependency review to
      the repository.
- [ ] Restrict hooks in CI to trusted paths and document the execution model;
      hooks are currently arbitrary shell with build credentials available.
- [ ] Move signing keys to repository secrets, document key rotation, and fail
      releases that use the template password.
- [ ] Add `SECURITY.md` with a vulnerability-reporting process and a supported
      window for security fixes.

### Verification and observability

- [ ] Add an old-version integration test: install an older module, fetch the
      new `update.json`, and assert the version, checksum and changelog all
      belong to the same release.
- [ ] Add a Magisk/KernelSU install smoke test on an emulator or test device
      that verifies mount, native-library extraction and the module description.
- [ ] Record builder version/commit, patches/CLI versions and artifact hashes
      in `build.md` and `module.prop` so a bug report is self-contained.
- [ ] Emit per-app duration, artifact size and failure-reason metrics in the
      job summary to spot slow or flaky apps over time.
- [ ] Maintain a "known-good versions" page for users who need to pin patches
      or roll back after an upstream regression.

---

## What "LTS-ready" means for this repo

A release is LTS-ready when all of these are true:

- the same config plus lockfile produces the same artifacts
- every download is checksum-verified
- artifacts and update metadata are signed and have verifiable provenance
- a failed app can never silently publish
- release notes contain patches and CLI versions, the changelog link, app
  versions and checksums
- old module versions keep their original changelog, checksum and metadata
- CI is concurrency-safe, least-privilege and reproducible
- CI tests both supported platforms and a real module install path
- upgrade, rollback and deprecation policies are documented and tested
- old configs keep working or fail with a clear migration message
- one command validates the config and the environment

---

## Suggested order of work

1. Known bugs: `.mpp` version, CI token, partial failures, Telegram limits.
2. Phase 1: concurrency, permissions, tag derivation, artifacts.
3. Phase 2: lockfile, checksums, changelog history, action pinning.
4. Phase 3: schema, validation, `--doctor`, download resilience.
5. Phase 4: linting, deterministic logs, end-to-end tests, docs.
6. Phase 5: release channels, signing/provenance, migration policy, platform
   matrix and install smoke tests.
