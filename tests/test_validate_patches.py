"""Exercise patch validation with real Git parsing and isolated collections."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from tools.validate_patches import validate_collection


MAIL = (
    "From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\n"
    "From: Example Author <author@example.com>\n"
    "Date: Tue, 3 Nov 2026 12:00:00 +0000\n"
    "Subject: [PATCH] Add an example\n\n"
)
DIFF = (
    "diff --git a/example.txt b/example.txt\n"
    "new file mode 100644\n"
    "index 0000000..ce01362\n"
    "--- /dev/null\n"
    "+++ b/example.txt\n"
    "@@ -0,0 +1 @@\n"
    "+hello\n"
)
VALID_PATCH = (MAIL + DIFF).encode()


class PatchValidationTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="flock-patch-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifest = self.root / ".patches"
        self.manifest.write_text("example.patch", encoding="utf-8")
        self.patch = self.root / "example.patch"
        self.patch.write_bytes(VALID_PATCH)

    def assert_invalid(self, expected):
        errors = validate_collection(self.root)
        self.assertTrue(any(expected in error for error in errors), errors)

    def test_valid_collection_needs_no_flutter_checkout_and_is_not_modified(self):
        before = {path.name: path.read_bytes() for path in self.root.iterdir()}
        self.assertEqual(validate_collection(self.root), [])
        self.assertEqual({path.name: path.read_bytes() for path in self.root.iterdir()}, before)

    def test_multi_commit_patch_checks_every_commit(self):
        self.patch.write_bytes(VALID_PATCH + b"\n" + VALID_PATCH)
        self.assertEqual(validate_collection(self.root), [])
        broken = (MAIL + DIFF.replace("+1 @@", "+1,2 @@")).encode()
        self.patch.write_bytes(VALID_PATCH + b"\n" + broken)
        self.assert_invalid("commit 2: invalid diff")

    def test_nonzero_envelope_and_incorrect_weekday_are_accepted(self):
        data = VALID_PATCH.replace(b"0000000000000000000000000000000000000000", b"a" * 40, 1)
        self.patch.write_bytes(data.replace(b"Tue, 3 Nov", b"Sun, 3 Nov"))
        self.assertEqual(validate_collection(self.root), [])

    def test_crlf_patch(self):
        self.patch.write_bytes(VALID_PATCH.replace(b"\n", b"\r\n"))
        self.assertEqual(validate_collection(self.root), [])

    def test_nested_patch_is_supported(self):
        nested = self.root / "nested"
        nested.mkdir()
        self.patch.rename(nested / "example.patch")
        self.manifest.write_text("nested/example.patch\n", encoding="utf-8")
        self.assertEqual(validate_collection(self.root), [])

    def test_missing_empty_and_invalid_utf8_manifests(self):
        self.manifest.unlink()
        self.assert_invalid(".patches must be a regular file")
        self.manifest.write_bytes(b"")
        self.assert_invalid("must list at least one patch")
        self.manifest.write_bytes(b"\xff")
        self.assert_invalid("cannot read .patches")

    def test_blank_duplicate_and_missing_entries(self):
        for contents, expected in [
            ("example.patch\n\n", "safe relative"),
            ("example.patch\nexample.patch\n", "duplicate entry"),
            ("missing.patch\n", "missing patch"),
        ]:
            with self.subTest(contents=contents):
                self.manifest.write_text(contents, encoding="utf-8")
                self.assert_invalid(expected)

    def test_unlisted_patch_and_git_metadata_exclusion(self):
        metadata = self.root / ".git"
        metadata.mkdir()
        (metadata / "internal.patch").write_bytes(b"not a collection entry")
        self.assertEqual(validate_collection(self.root), [])
        (self.root / "unlisted.patch").write_bytes(VALID_PATCH)
        self.assert_invalid("unlisted.patch: patch is not listed")

    def test_unsafe_manifest_paths(self):
        for name in ["../outside.patch", "/outside.patch", "./example.patch", "nested/../example.patch",
                     "nested\\example.patch", ".git/internal.patch", "C:/outside.patch"]:
            with self.subTest(name=name):
                self.manifest.write_text(name, encoding="utf-8")
                self.assert_invalid("safe relative")

    def test_symlink_manifest_and_patch_paths(self):
        self.patch.unlink()
        self.patch.symlink_to(self.root.parent / "outside.patch")
        self.assert_invalid("cannot contain symlinks")
        self.patch.unlink()
        self.patch.write_bytes(VALID_PATCH)
        link = self.root / "linked"
        link.symlink_to(self.root, target_is_directory=True)
        self.manifest.write_text("linked/example.patch", encoding="utf-8")
        self.assert_invalid("cannot contain symlinks")
        self.manifest.unlink()
        self.manifest.symlink_to(self.patch)
        self.assert_invalid(".patches must be a regular file")

    def test_patch_encoding_matches_nest_import(self):
        self.patch.write_bytes(VALID_PATCH.replace(b"+hello", b"+h\xffllo"))
        self.assert_invalid("patch files must be UTF-8")

    def test_missing_mail_metadata(self):
        for header, expected in [
            ("From: Example Author <author@example.com>\n", "missing Author"),
            ("Date: Tue, 3 Nov 2026 12:00:00 +0000\n", "missing Date"),
            ("Subject: [PATCH] Add an example\n", "missing Subject"),
        ]:
            with self.subTest(header=header):
                self.patch.write_bytes(VALID_PATCH.replace(header.encode(), b""))
                self.assert_invalid(expected)

    def test_invalid_date_and_email(self):
        self.patch.write_bytes(VALID_PATCH.replace(b"Tue, 3 Nov 2026 12:00:00 +0000", b"not a date"))
        self.assert_invalid("invalid author date")
        self.patch.write_bytes(VALID_PATCH.replace(b"author@example.com", b"invalid-email"))
        self.assert_invalid("invalid author email")

    def test_missing_envelope_empty_diff_and_invalid_hunk_counts(self):
        for data, expected in [
            (DIFF.encode(), "mail envelope"),
            (MAIL.encode(), "invalid diff"),
            ((MAIL + DIFF.replace("+1 @@", "+1,2 @@")).encode(), "invalid diff"),
        ]:
            with self.subTest(expected=expected):
                self.patch.write_bytes(data)
                self.assert_invalid(expected)

    def test_unsafe_diff_path(self):
        self.patch.write_bytes((MAIL + DIFF.replace("example.txt", "../outside.txt")).encode())
        self.assert_invalid("unsafe diff path")

    def test_mode_only_and_rename_patches(self):
        for diff in [
            "diff --git a/example.txt b/example.txt\nold mode 100644\nnew mode 100755\n",
            "diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n",
        ]:
            with self.subTest(diff=diff):
                self.patch.write_bytes((MAIL + diff).encode())
                self.assertEqual(validate_collection(self.root), [])

    def test_binary_patch(self):
        binary = self.root / "example.bin"
        binary.write_bytes(bytes(range(256)))
        result = subprocess.run(
            ["git", "diff", "--no-index", "--binary", "--", "/dev/null", "example.bin"],
            cwd=self.root, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 1)
        binary.unlink()
        self.patch.write_bytes(MAIL.encode() + result.stdout)
        self.assertEqual(validate_collection(self.root), [])

    def test_inherited_git_context_is_ignored(self):
        with patch.dict(os.environ, {"GIT_DIR": "/nonexistent", "GIT_WORK_TREE": "/nonexistent"}):
            self.assertEqual(validate_collection(self.root), [])

    def test_cli_fails_on_invalid_collection(self):
        self.manifest.write_text("missing.patch", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parents[1] / "tools/validate_patches.py"),
             str(self.root)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing.patch", result.stderr)


if __name__ == "__main__":
    unittest.main()
