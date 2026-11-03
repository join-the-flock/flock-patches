#!/usr/bin/env python3
"""Validate a Nest patch collection without fetching or modifying Flutter."""

from __future__ import annotations

import argparse
import os
from pathlib import Path, PurePosixPath, PureWindowsPath
import re
import shutil
import subprocess
import sys
import tempfile
from email.utils import parsedate_to_datetime


# A format-patch file can contain several commits (e.g. a GitHub PR download).
ENVELOPE = re.compile(rb"^From [0-9a-f]{40}(?:[0-9a-f]{24})? [^\r\n]+\r?$", re.MULTILINE)


def safe_path(name: str) -> bool:
    path = PurePosixPath(name)
    return (
        bool(name)
        and name == name.strip()
        and "\\" not in name
        and not path.is_absolute()
        and not PureWindowsPath(name).drive
        and not {"..", ".git"}.intersection(path.parts)
        and str(path) == name
    )


def run_git(arguments: list[str], data: bytes, directory: Path) -> subprocess.CompletedProcess:
    # Local invocations should not inherit another checkout's Git context.
    environment = {
        key: value
        for key, value in os.environ.items()
        if key.upper() not in {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"}
    }
    return subprocess.run(
        ["git", *arguments],
        input=data,
        capture_output=True,
        cwd=directory,
        env=environment,
        timeout=30,
        check=False,
    )


def validate_patch(data: bytes, directory: Path) -> list[str]:
    try:
        data.decode("utf-8")
    except UnicodeError:
        return ["patch files must be UTF-8 for Nest import"]
    envelopes = list(ENVELOPE.finditer(data))
    if not envelopes or envelopes[0].start() != 0:
        return ["expected a Git format-patch mail envelope"]

    errors = []
    boundaries = [match.start() for match in envelopes] + [len(data)]
    for number, (start, end) in enumerate(zip(boundaries, boundaries[1:]), 1):
        label = f"commit {number}"
        result = run_git(
            ["mailinfo", "-k", "--encoding=UTF-8", "--no-scissors", "message", "diff"],
            data[start:end],
            directory,
        )
        if result.returncode:
            errors.append(f"{label}: invalid mail: {result.stderr.decode(errors='replace').strip()}")
            continue
        metadata = {}
        for line in result.stdout.decode("utf-8", errors="replace").splitlines():
            key, separator, value = line.partition(":")
            if separator:
                metadata[key] = value.strip()
        for field in ("Author", "Email", "Date", "Subject"):
            if not metadata.get(field):
                errors.append(f"{label}: missing {field} mail metadata")
        if metadata.get("Email") and "@" not in metadata["Email"]:
            errors.append(f"{label}: invalid author email")
        if metadata.get("Date"):
            try:
                parsedate_to_datetime(metadata["Date"])
            except (ValueError, TypeError, OverflowError):
                errors.append(f"{label}: invalid author date")

        # Parse Git's extracted diff, including binary and mode-only patches.
        # --numstat never applies it and needs no Flutter source or index.
        result = run_git(["apply", "--numstat", "-z"], (directory / "diff").read_bytes(), directory)
        if result.returncode:
            errors.append(f"{label}: invalid diff: {result.stderr.decode(errors='replace').strip()}")
        elif not result.stdout:
            errors.append(f"{label}: contains no file changes")
        else:
            for record in result.stdout.rstrip(b"\0").split(b"\0"):
                filename = record.split(b"\t", 2)[-1].decode("utf-8", errors="surrogateescape")
                if not safe_path(filename):
                    errors.append(f"{label}: unsafe diff path {filename!r}")
    return errors


def validate_collection(root: Path) -> list[str]:
    root = root.resolve()
    manifest = root / ".patches"
    if manifest.is_symlink() or not manifest.is_file():
        return [".patches must be a regular file"]
    try:
        entries = manifest.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        return [f"cannot read .patches: {error}"]
    if not entries:
        return [".patches must list at least one patch"]

    errors = []
    listed = set()
    patches = []
    for number, entry in enumerate(entries, 1):
        label = f".patches:{number}"
        if not safe_path(entry) or not entry.endswith(".patch"):
            errors.append(f"{label}: expected a safe relative .patch filename, got {entry!r}")
            continue
        if entry in listed:
            errors.append(f"{label}: duplicate entry {entry!r}")
            continue
        listed.add(entry)
        path = root
        for part in PurePosixPath(entry).parts:
            path /= part
            if path.is_symlink():
                errors.append(f"{label}: patch paths cannot contain symlinks: {entry!r}")
                break
        else:
            if not path.is_file():
                errors.append(f"{label}: missing patch {entry!r}")
            else:
                patches.append(path)

    for path in sorted(root.rglob("*.patch")):
        relative = path.relative_to(root)
        if ".git" not in relative.parts and relative.as_posix() not in listed:
            errors.append(f"{relative.as_posix()}: patch is not listed in .patches")

    with tempfile.TemporaryDirectory(prefix="flock-patch-validation-") as temporary:
        directory = Path(temporary)
        for path in patches:
            try:
                for error in validate_patch(path.read_bytes(), directory):
                    errors.append(f"{path.relative_to(root).as_posix()}: {error}")
            except (OSError, subprocess.TimeoutExpired) as error:
                errors.append(f"{path.relative_to(root).as_posix()}: validation failed: {error}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parent.parent)
    arguments = parser.parse_args()
    if shutil.which("git") is None:
        parser.error("Git is required")
    errors = validate_collection(arguments.root)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(f"Patch validation failed: {len(errors)} error(s).", file=sys.stderr)
        return 1
    print("Patch manifest, mail metadata, and diff syntax are valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
