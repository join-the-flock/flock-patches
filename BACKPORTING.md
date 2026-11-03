# Backporting patches

Add `add-to-beta`, `add-to-stable`, or both to a PR targeting `master`.
When that PR merges, the backport workflow opens a separate PR for each
selected branch. Each backport starts from its target branch and cherry-picks
the merged PR's changes; it does not merge the whole master branch.

Backport PRs require normal review and merging. A conflict produces a draft
PR containing the first conflict, with resolution instructions on the original
PR. Subsequent source commits may still need to be cherry-picked after that
conflict is resolved. Review `.patches` carefully to preserve the target
channel's patch collection.

The entire source PR is backported, including changes to existing patch files.
Keep source PRs focused. Successful cherry-picking only proves that Git could
apply changes to the patch repository. Before merging, assemble Flock against
the target Flutter channel and run the relevant tests and version checks.

## Setup

1. Merge `.github/workflows/backport.yaml` into `master`.
2. Create the repository labels `add-to-beta` and `add-to-stable`.
3. In Settings → Actions → General → Workflow permissions, enable
   **Allow GitHub Actions to create and approve pull requests**. The workflow
   uses `GITHUB_TOKEN` with contents and pull-request write permissions.

The workflow also handles these labels being added to an already merged PR.
For an older PR, add the label after the workflow is installed; if it already
has the label, remove and re-add it. Adding a label to an unmerged PR waits
until merge. Labels on PRs targeting `beta` or `stable` do not trigger backports.

The backport action detects existing backport branches/PRs on reruns. If a
backport needs to be recreated, follow the action's instructions rather than
force-pushing over a branch that a reviewer may have edited.

GitHub may require a maintainer to approve CI runs on PRs created with
`GITHUB_TOKEN`. If unattended CI becomes necessary, configure a GitHub App
installation token for both checkout and the backport action.
