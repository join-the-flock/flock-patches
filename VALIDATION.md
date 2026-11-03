# Patch validation

Every PR targeting `master`, `beta`, or `stable` runs **Lightweight patch
validation**. Merge queue checks run it too. The job validates the complete
collection from GitHub's checked-out PR/merge snapshot, not just changed files.

The validator requires only Python 3.9+ and Git. It checks:

- `.patches` is a regular UTF-8 file with no blank or duplicate entries.
- Every entry names an existing `.patch` file within the repository, without
  traversing symlinks or Git metadata. Every patch file is listed.
- Each patch is UTF-8 (as required by Nest) and contains Git mail envelopes and usable author, email, date, and
  subject metadata. Multi-commit patch files are supported.
- Git can parse each extracted diff, including hunk counts, binary patches,
  renames, and mode changes. Diff paths must remain relative and inside the
  target checkout.

Validation never applies a patch or fetches Flutter. It accepts nonzero commit
IDs, historical metadata formatting, and a missing final newline in `.patches`;
it does not rewrite files to normalize them.

Run locally from this repository:

```sh
python3 tools/validate_patches.py
python3 -m unittest discover -s tests -v
```

## Gate heavier checks

The workflow's job ID is `lightweight`. Add future full-channel application,
assembly, or SDK test jobs to `.github/workflows/validate-patches.yaml` with
`needs: lightweight` (or a dependency chain beginning there). Keep the default
success condition; `always()` would allow a heavy job to bypass the gate.
A failed lightweight job then prevents those dependent jobs from starting.
`needs` only connects jobs in the same workflow.

There is no full-channel application job yet. Passing lightweight validation
does not establish that the patches apply to a particular Flutter revision or
that the resulting SDK works. Those checks belong in the dependent jobs.

To also require this check before merging, add **Lightweight patch validation**
to the branch protection/ruleset requirements for each channel. The workflow
itself does not change repository settings.
