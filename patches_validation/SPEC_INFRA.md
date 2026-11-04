# Infrastructure specification

Acceptance criteria for infrastructure in this repository. Update this file
alongside infrastructure changes.

## Channel manifest migration

- The `main` branch holds `.patches-master`, `.patches-beta`, and `.patches-stable`.
  Each manifest selects its channel's complete patch collection in application order.
- Channels reference shared patch files where their contents match. Compatibility
  variants use distinct filenames and are selected by the relevant manifest.
- Patch files stay together in the repository root. The baseline uses
  `<name>.patch`; adaptations use `<name>_YYYY-MM-DD.patch`, dated from the UTC
  commit date of the upstream change requiring the adaptation. Re-exporting or
  moving an adaptation between channels does not change its filename date.
- Adaptation descriptions identify the upstream commit and the compatibility
  change. Manifests select variants explicitly; dates do not determine selection.
- The initial collections preserve the patch contents and order from the existing
  channel branches. Those branches continue serving builds during migration.
- Migration is complete when validation checks all three collections and Nest's
  import, export, and assembly tooling selects the matching channel manifest.

## Tooling

- Infrastructure tools, tests, package configuration, and this specification live
  in `patches_validation/`. GitHub workflow entrypoints remain in `.github/workflows/`.
- The Dart package name matches its containing directory: `patches_validation`.
- The validation command and its private implementation live in `bin/validate.dart`.
  Tests in `test/` exercise its command-line behavior through subprocesses.
- Repository-owned tools and tests are written in Dart wherever feasible.
- Dart naming, formatting, and member ordering follow
  [FBH code formatting](https://github.com/Flutter-Bounty-Hunters/fbh_dev_practices/blob/main/skills/shared-code-skills/dart_code_formatting.md).
  Test naming, groups, and helper organization follow
  [FBH Dart and Flutter tests](https://github.com/Flutter-Bounty-Hunters/fbh_dev_practices/blob/main/skills/shared-code-skills/dart_and_flutter_tests.md).
- Test and group names describe behavior demonstrated by their setup and assertions.
- Dart Docs explain the code's intent and provide relevant domain context.
- CI uses the standalone stable Dart SDK and the checked-in dependency lockfile.
- Run Dart commands from `patches_validation/`. The validator defaults to the parent
  repository's three channel collections and accepts an explicit repository path.

## Lightweight patch validation

- Every PR targeting `main`, and every merge-queue check,
  runs the `lightweight` job, displayed as **Lightweight patch validation**.
- The job checks Dart formatting and analysis, tests the validator, and validates
  the complete proposed patch collection. It uses Dart and Git, fetches no Flutter
  SDK, and modifies no patches.
- `.patches-master`, `.patches-beta`, and `.patches-stable` are required regular
  UTF-8 files, each listing at least one patch in application order. The legacy
  `.patches` manifest is rejected.
- Entries are nonblank, unique within each manifest, and name regular `.patch`
  files in the repository root. Symlinks and unsafe paths are rejected.
- Files may be shared across manifests or selected by only one channel. Every
  patch file must appear in at least one manifest; shared files are checked once.
- Each manifest selects at most one variant of a change: its unsuffixed baseline
  or one dated adaptation. Date suffixes must use valid `YYYY-MM-DD` calendar
  dates. Dates do not imply channel selection or prove upstream compatibility.
- Validation checks all three manifests and reports errors with manifest names
  and line numbers where applicable.
- Patch files are UTF-8 Git mail patches with usable author, email, date, and
  subject metadata. Multi-commit files are supported.
- Git can parse every diff and its hunk counts. Binary patches, renames, mode
  changes, and CRLF mail are supported; diff paths cannot escape the target tree.
- Existing formatting remains acceptable, including nonzero commit IDs,
  historical weekday discrepancies, and manifests without a final newline.
- Any validation error fails the job. Future heavyweight jobs must depend on
  `lightweight`, directly or transitively, and must not bypass its success gate.

## Patch application

- PRs and merge-queue checks targeting `main` run an `application` matrix for
  Flutter `master`, `beta`, and `stable` after `lightweight` passes. Each check
  includes its channel in its name, and a failure does not cancel other channels.
- The job checks out Nest's `main` branch at the workspace root and reuses that
  checkout's `assemble-flock` action and tools. Each run follows the current Nest
  assembly behavior and records the resolved Nest commit.
- Each matrix entry selects the matching Flutter branch and `.patches-<channel>`
  manifest from the exact PR or merge-queue merge commit being checked.
- Nest's assembly action accepts `patches_manifest`, defaulting to `.patches` for
  existing callers. It copies a selected channel manifest to its importer's local
  `.patches` file, preserving manifest order, engine pinning, patch metadata, and
  three-way import behavior. This input must be available on Nest `main` before
  the migrated workflow runs.
- Verification confirms both the patch checkout revision and the selected manifest
  used for import; successful assembly of a different selection is insufficient.
- Success requires the requested patch revision, a completed import, and a clean
  assembled checkout. Any patch conflict or failed assembly fails the job.
- Reports identify the Nest, patch, Flutter base, and assembled revisions and
  preserve the selected manifest, import diagnostics, and failing patch mail on
  failure. Artifact names include the channel so matrix reports remain separate.
- The job uses read-only repository permissions. SDK/demo verification and
  publication remain separate stages; this job establishes patch applicability.

## Coordinated channel changes

- A PR to `main` contains the changes and manifest selections for all relevant
  channels. The `main` branch has no label-driven backport workflow.
- Existing channel branches and their publication workflows remain in use until
  Nest's publication and local import/export tools adopt the new layout.
