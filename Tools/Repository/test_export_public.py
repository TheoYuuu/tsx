#!/usr/bin/env python3
"""One-way export behavior in independent disposable Git repositories."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
EXPORT = ROOT / "Tools/Repository/export_public.py"
SCANNER = os.environ.get("TSX_TEST_GITLEAKS", str(ROOT / ".build/RepositoryTools/gitleaks"))
STATE = "Tools/Repository/export-state.json"
CODE = "LumaxTranslate/App/Sample.swift"


class PublicExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tsx-export-test-")
        self.base = Path(self.temporary.name)
        self.source = self.base / "private"
        self.target = self.base / "public"
        for repo in (self.source, self.target):
            repo.mkdir()
            self.git(repo, "init", "-q", "--template=")
            self.git(repo, "config", "user.name", "Export Fixture")
            self.git(repo, "config", "user.email", "123+fixture@users.noreply.github.com")
        files = [".gitignore", ".gitleaks.toml", "Scripts/check-public-repo.sh",
                 ".github/workflows/repository-safety.yml"]
        for directory in (".githooks", "Tools/Repository"):
            files.extend(str(p.relative_to(ROOT)) for p in (ROOT / directory).iterdir() if p.is_file())
        for name in files:
            path = self.target / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, path)
        self.put(self.source, CODE, "let fixture = 1\n")
        self.put(self.source, "README.md", "Private development notes\n")
        self.put(self.source, "Private/notes.md", "Private test diary\n")
        self.put(self.source, "Design/proposal.svg", "Private concept fixture\n")
        self.commit(self.source, "Initial private fixture", CODE, "README.md", "Private/notes.md", "Design/proposal.svg")
        self.put(self.target, CODE, "let fixture = 1\n")
        self.put(self.target, "README.md", "Public product description\n")
        self.commit(self.target, "Independent public fixture", *files, CODE, "README.md")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, repo, *args):
        return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE, text=True).strip()

    def put(self, repo, name, value):
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def commit(self, repo, message, *names):
        if names:
            self.git(repo, "add", "-f", "--", *names)
        self.git(repo, "commit", "-qm", message)

    def run_export(self, *args, environment=None):
        return subprocess.run([sys.executable, str(EXPORT), "--source", str(self.source), "--target", str(self.target),
                               "--gitleaks", SCANNER, *args], capture_output=True, text=True, env=environment)

    def preview(self, *args):
        result = self.run_export(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def apply(self, *args):
        plan = self.preview(*args)
        result = self.run_export(*args, "--apply", "--expect-plan", plan["plan_sha256"])
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def establish_state(self):
        self.apply()
        self.commit(self.target, "Record reviewed export baseline", STATE)

    def assert_blocked(self, reason, *args):
        result = self.run_export(*args)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(reason, result.stderr)

    def test_preview_does_not_write_or_transfer_history(self):
        head = self.git(self.target, "rev-parse", "HEAD")
        objects_before = self.git(self.target, "rev-list", "--all")
        files_before = sorted(str(p.relative_to(self.target)) for p in self.target.rglob("*") if ".git" not in p.parts)
        plan = self.preview()
        self.assertFalse(plan["applied"])
        self.assertFalse((self.target / STATE).exists())
        self.assertEqual(files_before, sorted(str(p.relative_to(self.target)) for p in self.target.rglob("*") if ".git" not in p.parts))
        self.assertEqual(self.git(self.target, "rev-list", "--all"), objects_before)
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), head)
        self.assertEqual(self.git(self.target, "status", "--porcelain"), "")
        self.assertTrue(any(i["path"] == "README.md" and "target-owned" in i["reason"] for i in plan["skipped"]))

    def test_baseline_and_commit_only_source_ignore_private_and_unstaged_data(self):
        self.establish_state()
        self.put(self.source, CODE, "let fixture = 2\n")
        self.commit(self.source, "Committed public change", CODE)
        self.put(self.source, CODE, "uncommitted private content\n")
        self.put(self.source, "LumaxTranslate/App/Untracked.swift", "private draft\n")
        before_refs = self.git(self.target, "rev-list", "--all")
        plan = self.apply()
        self.assertTrue(plan["applied"])
        self.assertEqual((self.target / CODE).read_text(), "let fixture = 2\n")
        self.assertEqual((self.target / "README.md").read_text(), "Public product description\n")
        self.assertFalse((self.target / "Private").exists())
        self.assertFalse((self.target / "Design").exists())
        self.assertFalse((self.target / "LumaxTranslate/App/Untracked.swift").exists())
        self.assertEqual(self.git(self.target, "rev-list", "--all"), before_refs)
        source_hash = self.git(self.source, "rev-parse", "HEAD")
        found = subprocess.run(["git", "-C", str(self.target), "cat-file", "-e", source_hash], capture_output=True)
        self.assertNotEqual(found.returncode, 0)
        self.assertNotIn(source_hash, (self.target / STATE).read_text())

    def test_only_previously_managed_deleted_files_are_removed(self):
        extra = "LumaxTranslate/App/PublicOnly.swift"
        self.put(self.target, extra, "let publicOnly = true\n")
        self.commit(self.target, "Public-only source fixture", extra)
        self.establish_state()
        self.git(self.source, "rm", CODE)
        self.commit(self.source, "Remove managed source")
        self.apply()
        self.assertFalse((self.target / CODE).exists())
        self.assertTrue((self.target / extra).exists())
        self.assertNotIn(CODE, json.loads((self.target / STATE).read_text())["files"])

    def test_dirty_target_and_unrelated_overwrite_are_rejected(self):
        self.put(self.target, CODE, "target edits\n")
        self.assert_blocked("Target must be clean")
        self.commit(self.target, "Independent public change", CODE)
        self.assert_blocked("Refusing to overwrite unrelated target content")

    def test_managed_target_divergence_requires_reconciliation(self):
        self.establish_state()
        self.put(self.target, CODE, "independent public change\n")
        self.commit(self.target, "Public divergence", CODE)
        self.put(self.source, CODE, "different private change\n")
        self.commit(self.source, "Private divergence", CODE)
        self.assert_blocked("Target managed file changed independently")

    def test_unknown_path_requires_explicit_exclusion(self):
        name = "Docs/NewPrivateDiary.md"
        self.put(self.source, name, "private notes\n")
        self.commit(self.source, "Unknown private material", name)
        self.assert_blocked("Source path is not public")
        plan = self.preview("--exclude", name)
        self.assertTrue(any(item["path"] == name for item in plan["skipped"]))

    def test_target_policy_controls_scope_and_source_policy_is_skipped(self):
        self.put(self.source, "Tools/Repository/policy.json", '{"root_files":["PrivateDocument.txt"]}\n')
        self.put(self.source, "PrivateDocument.txt", "private diary\n")
        self.commit(self.source, "Private policy cannot widen public scope", "Tools/Repository/policy.json", "PrivateDocument.txt")
        self.assert_blocked("Source path is not public")
        original = (self.target / "Tools/Repository/policy.json").read_bytes()
        self.apply("--exclude", "PrivateDocument.txt")
        self.assertEqual((self.target / "Tools/Repository/policy.json").read_bytes(), original)

    def test_source_symlink_is_rejected(self):
        self.git(self.source, "rm", CODE)
        (self.source / CODE).parent.mkdir(parents=True, exist_ok=True)
        (self.source / CODE).symlink_to("../../Private/notes.md")
        self.commit(self.source, "Symlink fixture", CODE)
        self.assert_blocked("Symlinks")

    def test_ignored_target_collision_is_not_overwritten(self):
        name = "LumaxTranslate/App/New.swift"
        self.put(self.target, ".gitignore", (self.target / ".gitignore").read_text() + "\n" + name + "\n")
        self.commit(self.target, "Ignore local fixture", ".gitignore")
        self.put(self.target, name, "local-only content\n")
        self.put(self.source, name, "public candidate\n")
        self.commit(self.source, "New source file", name)
        self.assert_blocked("untracked or ignored target path")
        self.assertEqual((self.target / name).read_text(), "local-only content\n")

    def test_ignored_symlink_parent_cannot_escape_target(self):
        parent = "LumaxTranslate/Translation"
        self.put(self.target, ".gitignore", (self.target / ".gitignore").read_text() + "\n" + parent + "\n")
        self.commit(self.target, "Ignore local symlink fixture", ".gitignore")
        outside = self.base / "outside"
        outside.mkdir()
        (self.target / parent).symlink_to(outside, target_is_directory=True)
        self.put(self.source, parent + "/Example.swift", "public candidate\n")
        self.commit(self.source, "New candidate file", parent + "/Example.swift")
        self.assert_blocked("symlink")
        self.assertEqual(list(outside.iterdir()), [])

    def test_exclusion_path_traversal_is_rejected(self):
        self.assert_blocked("Unsafe repository path", "--exclude", "../private/")

    def test_secret_in_allowed_file_fails_before_writing(self):
        self.establish_state()
        state_before = (self.target / STATE).read_bytes()
        self.put(self.source, CODE, "-----BEGIN " + "PRIVATE KEY-----\nfixture-only\n")
        self.commit(self.source, "Unsafe public candidate fixture", CODE)
        self.assert_blocked("failed the target's repository safety checks")
        self.assertEqual((self.target / CODE).read_text(), "let fixture = 1\n")
        self.assertEqual((self.target / STATE).read_bytes(), state_before)

    def test_shared_history_is_rejected(self):
        clone = self.base / "clone"
        subprocess.run(["git", "clone", "-q", str(self.source), str(clone)], check=True)
        self.target = clone
        self.assert_blocked("share commit history")

    def test_lfs_pointer_is_rejected(self):
        self.establish_state()
        pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:" + "1" * 64 + "\nsize 100\n"
        self.put(self.source, CODE, pointer)
        self.commit(self.source, "LFS pointer fixture", CODE)
        self.assert_blocked("Git LFS pointers")

    def test_ignored_nested_repository_is_not_modified(self):
        parent = "LumaxTranslate/Translation"
        self.put(self.target, ".gitignore", (self.target / ".gitignore").read_text() + "\n" + parent + "\n")
        self.commit(self.target, "Ignore nested checkout fixture", ".gitignore")
        nested = self.target / parent
        nested.mkdir(parents=True)
        self.git(nested, "init", "-q", "--template=")
        self.put(self.source, parent + "/Example.swift", "public candidate\n")
        self.commit(self.source, "New source fixture", parent + "/Example.swift")
        self.assert_blocked("nested Git checkout")
        self.assertFalse((nested / "Example.swift").exists())

    def test_alternate_object_store_is_rejected(self):
        alternate = self.target / ".git/objects/info/alternates"
        alternate.write_text(str(self.source / ".git/objects") + "\n")
        self.assert_blocked("Alternate Git object stores")

    def test_git_environment_redirection_is_rejected(self):
        for variable in ("GIT_DIR", "GIT_WORK_TREE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                         "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_INDEX_FILE"):
            environment = os.environ.copy()
            environment[variable] = "fixture-redirection"
            result = self.run_export(environment=environment)
            self.assertNotEqual(result.returncode, 0, variable)
            self.assertIn("Git environment redirection", result.stderr, variable)

    def test_stale_plan_and_apply_without_preview_are_rejected(self):
        self.establish_state()
        self.assert_blocked("requires --expect-plan", "--apply")
        plan = self.preview()
        self.put(self.source, CODE, "let fixture = 3\n")
        self.commit(self.source, "New change after preview", CODE)
        self.assert_blocked("Export plan changed", "--apply", "--expect-plan", plan["plan_sha256"])
        self.assertEqual((self.target / CODE).read_text(), "let fixture = 1\n")


if __name__ == "__main__":
    unittest.main()
