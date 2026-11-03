# Infrastructure specification

Acceptance criteria for infrastructure in this repository. Update this file
alongside infrastructure changes.

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
  repository's patch collection and accepts an explicit repository path.

## Lightweight patch validation

- Every PR targeting `master`, `beta`, or `stable`, and every merge-queue check,
  runs the `lightweight` job, displayed as **Lightweight patch validation**.
- The job checks Dart formatting and analysis, tests the validator, and validates
  the complete proposed patch collection. It uses Dart and Git, fetches no Flutter
  SDK, and modifies no patches.
- `.patches` is a regular UTF-8 file listing at least one patch. Entries are
  nonblank, unique, relative `.patch` paths. Every listed file exists, every patch
  file is listed, and paths cannot escape the repository or traverse symlinks or
  Git metadata.
- Patch files are UTF-8 Git mail patches with usable author, email, date, and
  subject metadata. Multi-commit files are supported.
- Git can parse every diff and its hunk counts. Binary patches, renames, mode
  changes, and CRLF mail are supported; diff paths cannot escape the target tree.
- Existing formatting remains acceptable, including nonzero commit IDs,
  historical weekday discrepancies, and no final newline in `.patches`.
- Any validation error fails the job. Future heavyweight jobs must depend on
  `lightweight`, directly or transitively, and must not bypass its success gate.

## Patch application

- PRs and merge-queue checks for `master`, `beta`, and `stable` run the
  `application` job, displayed as **Patch application**, after `lightweight` passes.
- The job checks out a pinned Nest revision at the workspace root and reuses its
  `assemble-flock` action. Update the pin deliberately when adopting Nest changes.
- The PR's target branch selects the matching Flutter branch. The patch collection
  comes from the exact PR or merge-queue merge commit being checked.
- Assembly uses the complete patch collection in `.patches` order, including
  Nest's engine pin, patch metadata, and three-way import behavior.
- Success requires the requested patch revision, a completed import, and a clean
  assembled checkout. Any patch conflict or failed assembly fails the job.
- Reports identify the Nest, patch, Flutter base, and assembled revisions and
  preserve import diagnostics and the failing patch mail on failure.
- The job uses read-only repository permissions. SDK/demo verification and
  publication remain separate stages; this job establishes patch applicability.

## Backport pull requests

- On a PR merged into `master`, `add-to-beta` and `add-to-stable` select the
  corresponding backport targets. Both labels select both branches. Without
  either label, no backport is created. Adding a target label after merge also
  triggers backporting.
- Unmerged PRs and PRs targeting other branches do not trigger backporting.
- Each backport starts from its target branch and cherry-picks the source PR's
  changes, preserving channel-specific history and patch collections.
- Clean backports open normal PRs. Conflicts open draft PRs identifying the
  unresolved work and any remaining commits. The source PR receives links and
  resolution instructions.
- Repeated events do not create duplicate PRs or force-push over existing work.
  Runs for the same source PR do not race.
- Backports require review and manual merging. Successful cherry-picking of
  patch files does not establish compatibility with the target Flutter channel.
- The workflow uses trusted `master` content and only recognizes the two target
  labels. Repository setup must provide those labels and allow its workflow
  token to push branches and create PRs. Bot-created PR checks may require a
  maintainer's approval to run.
