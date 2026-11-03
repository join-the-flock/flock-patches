# Infrastructure specification

Acceptance criteria for infrastructure in this repository. Update this file
alongside infrastructure changes.

## Tooling

- Infrastructure tools, tests, package configuration, and this specification live
  in `validation/`. GitHub workflow entrypoints remain in `.github/workflows/`.
- Executable commands live in `bin/`, reusable implementation in `lib/`, and
  tests in `test/`, with test filenames matching their implementation files.
- Repository-owned tools and tests are written in Dart wherever feasible.
- Dart naming, formatting, and member ordering follow
  [FBH code formatting](https://github.com/Flutter-Bounty-Hunters/fbh_dev_practices/blob/main/skills/shared-code-skills/dart_code_formatting.md).
  Test naming, groups, and helper organization follow
  [FBH Dart and Flutter tests](https://github.com/Flutter-Bounty-Hunters/fbh_dev_practices/blob/main/skills/shared-code-skills/dart_and_flutter_tests.md).
- CI uses the standalone stable Dart SDK and the checked-in dependency lockfile.
- Run Dart commands from `validation/`. The validator defaults to the parent
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

Full-channel patch application and SDK verification are not implemented yet.
Lightweight success alone does not establish Flutter compatibility.

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
