#!/usr/bin/env python3
"""Behavior tests use disposable repositories and deliberately invalid samples."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "Tools/Repository/check.py"
SCANNER = os.environ.get("TSX_TEST_GITLEAKS", str(ROOT / ".build/RepositoryTools/gitleaks"))


class RepositoryChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tsx-policy-test-")
        self.repo = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Repository Test")
        self.git("config", "user.email", "123+fixture@users.noreply.github.com")
        self.put("README.md", "Public test fixture\n")
        policy_files = [".gitignore", ".gitleaks.toml", "Scripts/check-public-repo.sh",
                        ".github/workflows/repository-safety.yml"]
        for directory in (".githooks", "Tools/Repository"):
            policy_files.extend(str(p.relative_to(ROOT)) for p in (ROOT / directory).iterdir() if p.is_file())
        for name in policy_files:
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        self.git("add", "README.md", *policy_files)
        self.git("commit", "-qm", "Initial public fixture")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.PIPE, text=True).strip()

    def put(self, name, value):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def run_check(self, *args, stdin=None, scanner=None, review=None, repo=None):
        environment = os.environ.copy()
        environment.pop("TSX_REVIEWED_POLICY_SHA256", None)
        if review:
            environment["TSX_REVIEWED_POLICY_SHA256"] = review
        return subprocess.run([sys.executable, str(self.repo / "Tools/Repository/check.py"), *args, "--repo", str(repo or self.repo), "--gitleaks", scanner or SCANNER],
                              input=stdin, capture_output=True, text=True, env=environment)

    def assert_passes(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_blocks(self, result, reason):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(reason, result.stderr)

    def test_ignore_rule_only_excludes_root_design_archive(self):
        archive = subprocess.run(["git", "-C", str(self.repo), "check-ignore", "--no-index", "Design/proposal.png"], capture_output=True)
        source = subprocess.run(["git", "-C", str(self.repo), "check-ignore", "--no-index", "TranslateX/UI/Design/NewView.swift"], capture_output=True)
        self.assertEqual(archive.returncode, 0)
        self.assertEqual(source.returncode, 1)

    def test_subdirectory_invocation_checks_the_entire_index(self):
        self.put("Config/sample.txt", "Public fixture\n")
        self.put("Tools/QA/private.txt", "/Us" + "ers/private-person/notes\n")
        self.git("add", "Config/sample.txt", "Tools/QA/private.txt")
        self.assert_blocks(self.run_check("staged", repo=self.repo / "Config"), "personal absolute home path")

    def test_new_directory_and_unlisted_tool_document_are_blocked(self):
        self.put("Tools/PrivateNotes/internal.md", "Internal planning fixture\n")
        self.put("Tools/QA/internal.md", "Internal planning fixture\n")
        self.git("add", "Tools/PrivateNotes/internal.md", "Tools/QA/internal.md")
        result = self.run_check("staged")
        self.assert_blocks(result, "Tools/PrivateNotes/internal.md")
        self.assert_blocks(result, "Tools/QA/internal.md")

    def test_retired_names_cannot_be_reintroduced_in_current_paths(self):
        self.put("TranslateX/App/LumaxLegacy.swift", "// Constructed old-name fixture\n")
        self.git("add", "TranslateX/App/LumaxLegacy.swift")
        self.assert_blocks(self.run_check("staged"), "outside the public allowlist")

    def allow_historical_commit(self, oid):
        path = self.repo / "Tools/Repository/policy.json"
        policy = json.loads(path.read_text())
        policy["historical_path_commits"] = [oid]
        path.write_text(json.dumps(policy).replace("/Us" + "ers/constructed", r"\u002fUsers\u002fconstructed") + "\n")
        self.git("add", "Tools/Repository/policy.json")
        self.git("commit", "-qm", "Review immutable historical naming fixture")

    def test_reviewed_history_keeps_privacy_checks_and_rejects_new_old_paths(self):
        old_path = "LumaxTranslate/App/Fixture.swift"
        self.put(old_path, "// Public historical fixture\n")
        self.git("add", old_path)
        self.git("commit", "-qm", "Historical naming fixture")
        old_commit = self.git("rev-parse", "HEAD")
        self.git("rm", "-q", old_path)
        self.allow_historical_commit(old_commit)
        self.assert_passes(self.run_check("history"))
        self.put(old_path, "// Public historical fixture\n")
        self.git("add", old_path)
        self.git("commit", "-qm", "Reintroduce retired directory fixture")
        self.assert_blocks(self.run_check("history"), "outside the public allowlist")

    def test_reviewed_historical_path_still_scans_private_content(self):
        old_path = "LumaxTranslate/App/Fixture.swift"
        self.put(old_path, "/Us" + "ers/private-person/notes\n")
        self.git("add", old_path)
        self.git("commit", "-qm", "Historical private content fixture")
        old_commit = self.git("rev-parse", "HEAD")
        self.git("rm", "-q", old_path)
        self.allow_historical_commit(old_commit)
        self.assert_blocks(self.run_check("history"), "personal absolute home path")

    def test_staged_secret_is_blocked_despite_clean_worktree(self):
        sample = "-----BEGIN " + "PRIVATE KEY-----\nfixture-only\n-----END PRIVATE KEY-----\n"
        self.put("Config/sample.txt", sample)
        self.git("add", "Config/sample.txt")
        self.put("Config/sample.txt", "clean unstaged content\n")
        self.assert_blocks(self.run_check("staged"), "private-key material")

    def test_clean_index_passes_despite_unstaged_secret(self):
        self.put("Config/sample.txt", "clean staged content\n")
        self.git("add", "Config/sample.txt")
        self.put("Config/sample.txt", "-----BEGIN " + "PRIVATE KEY-----\nfixture-only\n")
        self.assert_passes(self.run_check("staged"))

    def test_force_added_ignored_file_is_blocked(self):
        self.put(".gitignore", "*.p12\n")
        self.git("add", ".gitignore")
        self.git("commit", "-qm", "Ignore fixture exports")
        self.put("Config/private.p12", "not a real credential\n")
        self.git("add", "-f", "Config/private.p12")
        self.assert_blocks(self.run_check("staged"), "outside the public allowlist")

    def test_design_and_internal_docs_are_blocked(self):
        for name in ("Design/reference.svg", "Docs/ExecutionPlan.md"):
            self.put(name, "Private planning fixture\n")
            self.git("add", "-f", name)
        self.assert_blocks(self.run_check("staged"), "Design/reference.svg")
        self.assert_blocks(self.run_check("staged"), "Docs/ExecutionPlan.md")

    def test_deleted_personal_path_is_still_blocked_in_outgoing_history(self):
        self.put("README.md", "/Us" + "ers/private-person/notes\n")
        self.git("add", "README.md")
        self.git("commit", "-qm", "Historical privacy regression fixture")
        self.put("README.md", "Clean current source\n")
        self.git("add", "README.md")
        self.git("commit", "-qm", "Remove fixture from current tree")
        self.assert_passes(self.run_check("tree"))
        oid = self.git("rev-parse", "HEAD")
        self.assert_blocks(self.run_check("pre-push", stdin=f"refs/heads/main {oid} refs/heads/main {'0' * 40}\n"),
                           "personal absolute home path")

    def test_deleted_secret_is_still_blocked_in_history(self):
        sample = "gh" + "p_" + "a8Qx4P2n7Z5v9R3t6W1y8C4k2B7m5L9s3D6f"
        self.put("TranslateXTests/Fixture.swift", 'let token = "' + sample + '"\n')
        self.git("add", "TranslateXTests/Fixture.swift")
        self.git("commit", "-qm", "Historical secret fixture")
        self.git("rm", "-q", "TranslateXTests/Fixture.swift")
        self.git("commit", "-qm", "Remove current fixture")
        self.assert_passes(self.run_check("tree"))
        self.assert_blocks(self.run_check("history"), "Gitleaks:")

    def test_annotated_tag_private_identity_is_blocked(self):
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("tag", "-a", "test-fixture", "-m", "Public tag fixture")
        self.assert_blocks(self.run_check("history", "refs/tags/test-fixture"), "tagger email")

    def test_private_path_in_author_name_is_blocked(self):
        self.git("config", "user.name", "/Us" + "ers/private-person/notes")
        self.assert_blocks(self.run_check("staged"), "personal absolute home path")
        self.git("commit", "--allow-empty", "-qm", "Private author name fixture")
        self.assert_blocks(self.run_check("history"), "personal absolute home path")

    def test_private_author_email_is_blocked(self):
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("commit", "--allow-empty", "-qm", "Private author fixture")
        self.assert_blocks(self.run_check("history"), "email is not GitHub noreply")

    def test_public_key_team_and_test_fixtures_pass(self):
        # RFC 8032 public test vector: public verification data, no private key.
        self.put("Config/sample.txt", '<key>SUPublicEDKey</key>\n<string>' + '1YBfmJ/YKywwUTgbDVbjpUVPG19CVUJje3JhshWVdvk=' + '</string>\nDEVELOPMENT_TEAM = ABCDE12345\n')
        self.put("TranslateXTests/Fixture.swift", 'let apiKey = "fixture-key"\nlet email = "sample@example.invalid"\n')
        self.put("Runtime/CodexHelper/src/connection.rs", 'let path = "/Us' + 'ers/constructed/.codex/config.toml";\n')
        self.git("add", "Config/sample.txt", "TranslateXTests/Fixture.swift", "Runtime/CodexHelper/src/connection.rs")
        self.assert_passes(self.run_check("staged"))

    def test_only_exact_cargo_false_positive_is_allowed(self):
        pair = 'dependencies = [\n "crypto_' + 'secretbox",\n "curve25519-dalek",\n]\n'
        self.put("Runtime/CodexHelper/Cargo.lock", pair)
        self.git("add", "Runtime/CodexHelper/Cargo.lock")
        self.assert_passes(self.run_check("staged"))
        self.put("Tools/QA/unrelated.lock", pair)
        self.git("add", "Tools/QA/unrelated.lock")
        self.assert_blocks(self.run_check("staged"), "Gitleaks: generic-api-key")

    def test_realistic_secret_in_lock_is_not_excluded(self):
        # Built at runtime so these test source files never embed credential patterns.
        sample = "gh" + "p_" + "a8Qx4P2n7Z5v9R3t6W1y8C4k2B7m5L9s3D6f"
        self.put("Runtime/CodexHelper/Cargo.lock", 'token = "' + sample + '"\n')
        self.git("add", "Runtime/CodexHelper/Cargo.lock")
        self.assert_blocks(self.run_check("staged"), "Gitleaks:")

    def test_missing_scanner_fails_closed(self):
        self.assert_blocks(self.run_check("tree", scanner=str(self.repo / "missing-scanner")), "Gitleaks is missing")

    def test_policy_change_needs_exact_staged_review_digest(self):
        self.put(".gitignore", "*.p12\n")
        self.git("add", ".gitignore")
        self.assert_blocks(self.run_check("staged"), "review staged policy diff")
        digest = self.run_check("policy-review").stdout.strip()
        self.assert_passes(self.run_check("staged", review=digest))
        self.put(".gitignore", "*.p12\n*.pfx\n")
        self.git("add", ".gitignore")
        self.assert_blocks(self.run_check("staged", review=digest), "review staged policy diff")

    def test_pre_push_rejects_uncommitted_working_and_staged_policy(self):
        oid = self.git("rev-parse", "HEAD")
        line = f"refs/heads/main {oid} refs/heads/main {'0' * 40}\n"
        self.assert_passes(self.run_check("pre-push", stdin=line))
        policy = self.repo / ".gitleaks.toml"
        policy.write_text(policy.read_text() + "\n# Uncommitted change\n")
        self.assert_blocks(self.run_check("pre-push", stdin=line), "Uncommitted repository policy")
        self.git("add", ".gitleaks.toml")
        self.assert_blocks(self.run_check("pre-push", stdin=line), "Uncommitted repository policy in index")

    def test_staged_policy_worktree_mismatch_is_blocked(self):
        self.put(".gitignore", "*.p12\n")
        self.git("add", ".gitignore")
        digest = self.run_check("policy-review").stdout.strip()
        self.put(".gitignore", "*.pfx\n")
        self.assert_blocks(self.run_check("staged", review=digest), "staged policy differs")

    def test_only_reviewed_image_content_passes(self):
        path = self.repo / "assets/app-icon.png"
        path.parent.mkdir(parents=True)
        path.write_bytes((ROOT / "assets/app-icon.png").read_bytes())
        self.git("add", "assets/app-icon.png")
        self.assert_passes(self.run_check("staged"))
        path.write_bytes(path.read_bytes() + b"unreviewed-metadata")
        self.git("add", "assets/app-icon.png")
        self.assert_blocks(self.run_check("staged"), "image content requires visual review")

    def test_large_binary_and_symlinks_are_blocked(self):
        path = self.repo / "assets/app-icon.png"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"\x89PNG\r\n\x1a\n" + b"x" * (2 * 1024 * 1024))
        self.git("add", "assets/app-icon.png")
        self.assert_blocks(self.run_check("staged"), "size limit")
        path.unlink()
        self.git("reset", "-q", "HEAD", "--", "assets/app-icon.png")
        path.symlink_to(self.repo / "README.md")
        self.git("add", "assets/app-icon.png")
        self.assert_blocks(self.run_check("staged"), "symlinks")


if __name__ == "__main__":
    unittest.main()
