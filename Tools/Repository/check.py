#!/usr/bin/env python3
"""Check Git snapshots and reachable history, without reading user credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile

POLICY_ROOT = Path(__file__).resolve().parents[2]
VERSION = "8.30.1"
PROTECTED = (".gitignore", ".gitleaks.toml", ".githooks/", "Tools/Repository/",
             "Scripts/check-public-repo.sh", ".github/workflows/repository-safety.yml")
NOREPLY = re.compile(r"(?:[0-9]+\+)?[A-Za-z0-9-]+@users\.noreply\.github\.com\Z", re.I)
HOME_PATH = re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+(?:/[^\s\"'<>`)]*)?|[A-Za-z]:[\\/]Users[\\/][A-Za-z0-9._-]+(?:[\\/][^\s\"'<>`]*)?")
PRIVATE_KEY = re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")
FORBIDDEN_PARTS = {".build", "build", "DerivedData", "xcuserdata", "node_modules", "target", ".git", ".ssh"}
FORBIDDEN_SUFFIXES = {".p12", ".pfx", ".p8", ".pem", ".key", ".keychain", ".keychain-db",
                      ".mobileprovision", ".provisionprofile", ".app", ".dmg", ".xcarchive",
                      ".xcresult", ".zip", ".tar", ".gz", ".log", ".sqlite", ".db"}
FORBIDDEN_NAMES = {"auth.json", "credentials.json", "credentials", "credentials.toml", "Local.xcconfig", ".gitleaksignore"}


def protected(path):
    return any(path == name or (name.endswith("/") and path.startswith(name)) for name in PROTECTED)


class Audit:
    def __init__(self, repo, gitleaks, review):
        self.repo = Path(subprocess.check_output(["git", "-C", str(Path(repo).resolve()),
                                                 "rev-parse", "--show-toplevel"], text=True).strip())
        self.policy = json.loads((POLICY_ROOT / "Tools/Repository/policy.json").read_text())
        self.images = json.loads((POLICY_ROOT / "Tools/Repository/reviewed-images.json").read_text())
        self.gitleaks = Path(gitleaks).resolve() if gitleaks else POLICY_ROOT / ".build/RepositoryTools/gitleaks"
        self.review = review
        self.issues = set()
        self.blobs = {}
        self.checked = set()
        self.scan_files = {}
        self.metadata = {}
        self.trees = set()
        self.commits = set()

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.repo), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError(f"Git operation failed: {args[0]} (no content printed)")
        return result.stdout

    def issue(self, context, message):
        self.issues.add(f"{context}: {message}")

    def object(self, oid):
        if oid not in self.blobs:
            self.blobs[oid] = self.git("cat-file", "blob", oid)
        return self.blobs[oid]

    def allowed_path(self, name):
        p = PurePosixPath(name)
        if any(term.casefold() in name.casefold() for term in self.policy.get("retired_path_terms", [])):
            return False
        if p.is_absolute() or ".." in p.parts or any(ord(c) < 32 for c in name):
            return False
        if any(part in FORBIDDEN_PARTS or Path(part).suffix.lower() in FORBIDDEN_SUFFIXES for part in p.parts):
            return False
        if p.name in FORBIDDEN_NAMES or (p.name.startswith(".env") and p.name != ".env.example"):
            return False
        if name in self.policy["root_files"]:
            return True
        if p.parts[0] == "Docs":
            return len(p.parts) == 2 and p.name in self.policy["public_docs"]
        if p.parts[0] == ".githooks":
            return name in {".githooks/pre-commit", ".githooks/pre-push"}
        if p.parts[0] == ".github":
            return ((len(p.parts) == 3 and p.parts[1] == "ISSUE_TEMPLATE" and p.suffix in {".yml", ".yaml", ".md"})
                    or name == ".github/workflows/repository-safety.yml")
        if p.parts[0] == "TranslateX.xcodeproj":
            return name in {
                "TranslateX.xcodeproj/project.pbxproj",
                "TranslateX.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
                "TranslateX.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                "TranslateX.xcodeproj/xcshareddata/xcschemes/TranslateX.xcscheme",
            }
        if p.suffix.lower() == ".png":
            return (name in self.policy["png_paths"] or
                    (len(p.parts) == 5 and p.parts[:3] == ("TranslateX", "Resources", "Assets.xcassets")
                     and p.parts[3] in self.policy["png_asset_sets"]))
        return (p.parts[0] in self.policy["source_roots"]
                and str(p.parent) in self.policy["source_directories"]
                and p.suffix in self.policy["text_extensions"]
                and (p.suffix != ".md" or name in self.policy["source_documents"]))

    def check_text(self, name, text):
        for match in HOME_PATH.finditer(text):
            if match.group() not in self.policy["home_path_exceptions"].get(name, []):
                line = text.count("\n", 0, match.start()) + 1
                self.issue(f"{name}:{line}", "personal absolute home path")
        if PRIVATE_KEY.search(text):
            self.issue(name, "private-key material")

    def entry(self, mode, oid, name, historical=False):
        # A naming migration must not exempt old content from privacy checks.
        # Only explicitly reviewed immutable commits may use retired paths.
        reviewed_name = name
        if historical:
            for old, new in self.policy.get("historical_path_replacements", []):
                reviewed_name = reviewed_name.replace(old, new)
        key = (mode, oid, name, historical)
        if key in self.checked:
            return
        self.checked.add(key)
        if not self.allowed_path(reviewed_name):
            self.issue(name, "path or file type is outside the public allowlist")
            return
        if mode not in {"100644", "100755"}:
            self.issue(name, "symlinks and submodules require separate review; not permitted")
            return
        data = self.object(oid)
        if len(data) > self.policy["max_file_bytes"]:
            self.issue(name, "file exceeds reviewed size limit")
            return
        if name.lower().endswith(".png"):
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                self.issue(name, "approved image path does not contain PNG data")
            elif hashlib.sha256(data).hexdigest() not in self.images.get(reviewed_name, []):
                self.issue(name, "image content requires visual review and an exact reviewed-images.json entry")
            return
        try:
            text = data.decode("utf-8")
            if "\x00" in text:
                raise ValueError("binary data")
        except (UnicodeDecodeError, ValueError):
            self.issue(name, "unreviewed binary content")
            return
        self.check_text(name, text)
        self.scan_files[(oid, name)] = data

    def tree(self, ref, historical=False):
        tree = self.git("rev-parse", "--verify", "--end-of-options", f"{ref}^{{tree}}").decode().strip()
        key = (tree, historical)
        if key in self.trees:
            return
        self.trees.add(key)
        for record in self.git("ls-tree", "-rz", "--full-tree", tree).split(b"\0"):
            if record:
                header, name = record.split(b"\t", 1)
                mode, kind, oid = header.decode().split()
                self.entry(mode, oid, name.decode("utf-8"), historical=historical)

    def policy_digest(self):
        entries = []
        changed = self.git("diff", "--cached", "--name-only", "-z", "--diff-filter=ACDMRTUXB").decode().split("\0")
        for name in sorted(filter(protected, filter(None, changed))):
            data = self.git("diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "--", name)
            entries.append(name.encode() + b"\0" + data)
        return hashlib.sha256(b"\0".join(entries)).hexdigest() if entries else None

    def staged(self):
        digest = self.policy_digest()
        if digest and self.review != digest:
            self.issue("repository policy", "review staged policy diff, then set TSX_REVIEWED_POLICY_SHA256=" + digest)
        for record in self.git("ls-files", "--stage", "-z").split(b"\0"):
            if record:
                header, name = record.split(b"\t", 1)
                mode, oid, stage = header.decode().split()
                if stage != "0":
                    self.issue(name.decode(), "unresolved index conflict")
                else:
                    path = name.decode("utf-8")
                    if protected(path):
                        working = self.repo / path
                        if working.is_symlink() or not working.is_file() or working.read_bytes() != self.object(oid):
                            self.issue(path, "staged policy differs from the working policy; review and synchronize before checking")
                    self.entry(mode, oid, path)
        for role in ("GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"):
            identity = self.git("var", role).decode()
            self.check_text(role, identity)
            self.metadata["identities/" + role + ".txt"] = identity.encode()
            found = re.search(r"<([^<>]+)>", identity)
            if not found or not NOREPLY.fullmatch(found[1]):
                self.issue(role, "use a verified GitHub noreply email before committing")

    def commit_metadata(self, commit):
        raw = self.git("cat-file", "commit", commit)
        text = raw.decode("utf-8")
        for label in ("author", "committer"):
            found = re.search(r"^" + label + r" .*<([^<>]+)> ", text, re.M)
            if not found or not NOREPLY.fullmatch(found[1]):
                self.issue(commit[:12], f"{label} email is not GitHub noreply")
        self.check_text("commit " + commit[:12], text)
        self.metadata["commits/" + commit + ".txt"] = raw

    def history(self, refs):
        commits = []
        for ref in refs:
            oid = self.git("rev-parse", "--verify", "--end-of-options", ref).decode().strip()
            # Annotated tag identity and message are public independently of commits.
            while self.git("cat-file", "-t", oid).strip() == b"tag":
                raw = self.git("cat-file", "tag", oid)
                text = raw.decode("utf-8")
                found = re.search(r"^tagger .*<([^<>]+)>", text, re.M)
                if found and not NOREPLY.fullmatch(found[1]):
                    self.issue(oid[:12], "tagger email is not GitHub noreply")
                self.check_text("tag " + oid[:12], text)
                self.metadata["tags/" + oid + ".txt"] = raw
                oid = text.splitlines()[0].removeprefix("object ")
            commit = self.git("rev-parse", "--verify", "--end-of-options", f"{oid}^{{commit}}").decode().strip()
            commits.append(commit)
        for commit in self.git("rev-list", *commits).decode().splitlines():
            if commit not in self.commits:
                self.commits.add(commit)
                self.commit_metadata(commit)
                self.tree(commit, historical=commit in self.policy.get("historical_path_commits", []))

    def pre_push_policy(self):
        required = {".gitignore", ".gitleaks.toml", ".githooks/pre-commit", ".githooks/pre-push",
                    "Scripts/check-public-repo.sh", ".github/workflows/repository-safety.yml",
                    "Tools/Repository/check.py", "Tools/Repository/bootstrap_gitleaks.py",
                    "Tools/Repository/policy.json", "Tools/Repository/reviewed-images.json"}
        committed = {}
        for record in self.git("ls-tree", "-rz", "HEAD").split(b"\0"):
            if record:
                header, name = record.split(b"\t", 1)
                path = name.decode("utf-8")
                if protected(path):
                    committed[path] = header.decode().split()[2]
        if not required.issubset(committed):
            raise RuntimeError("Commit the complete reviewed repository policy before pushing")
        changed = self.git("diff", "--cached", "--name-only", "-z", "HEAD").decode().split("\0")
        if any(protected(name) for name in changed if name):
            raise RuntimeError("Uncommitted repository policy in index; review and commit it before pushing")
        for path, oid in committed.items():
            expected = self.object(oid)
            for source in {self.repo / path, POLICY_ROOT / path}:
                if source.is_symlink() or not source.is_file() or source.read_bytes() != expected:
                    raise RuntimeError("Uncommitted repository policy or executing policy differs from HEAD: " + path)

    def secrets(self):
        if not self.gitleaks.is_file():
            raise RuntimeError("Gitleaks is missing; run python3 Tools/Repository/bootstrap_gitleaks.py")
        version = subprocess.check_output([str(self.gitleaks), "version"], text=True).strip()
        if version != VERSION:
            raise RuntimeError("Gitleaks version must be " + VERSION)
        with tempfile.TemporaryDirectory(prefix="tsx-public-audit-") as directory:
            scratch = Path(directory)
            source = scratch / "source"
            source.mkdir()
            for (oid, name), data in self.scan_files.items():
                target = source / "blobs" / oid / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            for name, data in self.metadata.items():
                target = source / "metadata" / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            report = scratch / "report.json"
            ignore = scratch / "empty.ignore"
            ignore.touch()
            result = subprocess.run([
                str(self.gitleaks), "dir", str(source), "--config", str(POLICY_ROOT / ".gitleaks.toml"),
                "--gitleaks-ignore-path", str(ignore), "--ignore-gitleaks-allow", "--redact=100",
                "--report-format", "json", "--report-path", str(report), "--no-banner", "--log-level", "error",
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode not in {0, 1} or not report.is_file():
                raise RuntimeError("Gitleaks did not complete successfully; no scan output exposed")
            findings = json.loads(report.read_text())
            for finding in findings:
                path = finding.get("File", "unknown")
                marker = "/blobs/"
                if marker in path:
                    path = path.split(marker, 1)[1].split("/", 1)[-1]
                elif "/metadata/" in path:
                    path = path.split("/metadata/", 1)[1]
                self.issue(f"{path}:{finding.get('StartLine', '?')}", "Gitleaks: " + finding.get("RuleID", "secret"))
            if result.returncode and not findings:
                raise RuntimeError("Gitleaks failed without a findings report")

    def finish(self):
        self.secrets()
        if self.issues:
            for issue in sorted(self.issues)[:60]:
                print("BLOCKED " + issue, file=sys.stderr)
            if len(self.issues) > 60:
                print(f"... {len(self.issues) - 60} additional violations", file=sys.stderr)
            raise SystemExit(1)
        print(f"Public repository check passed: {len(self.checked)} file versions, {len(self.commits)} commits; Gitleaks {VERSION}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["staged", "tree", "history", "pre-push", "policy-review"])
    parser.add_argument("refs", nargs="*")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--gitleaks", help="Explicit pinned-version executable for isolated verification")
    args = parser.parse_args()
    audit = Audit(args.repo, args.gitleaks, os.environ.get("TSX_REVIEWED_POLICY_SHA256"))
    if args.command == "policy-review":
        print(audit.policy_digest() or "No staged policy changes")
        return
    if args.command == "staged":
        if args.refs:
            parser.error("staged takes no refs")
        audit.staged()
    elif args.command == "tree":
        if len(args.refs) > 1:
            parser.error("tree takes at most one ref")
        audit.tree(args.refs[0] if args.refs else "HEAD")
    elif args.command == "history":
        audit.history(args.refs or ["HEAD"])
    else:
        refs = []
        for line in sys.stdin:
            fields = line.split()
            if len(fields) != 4:
                parser.error("invalid pre-push input")
            if set(fields[1]) != {"0"}:
                refs.append(fields[1])
        if not refs:
            print("No objects to push")
            return
        audit.pre_push_policy()
        audit.history(refs)
    audit.finish()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, UnicodeError, subprocess.SubprocessError) as error:
        print(f"Public repository check failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None
