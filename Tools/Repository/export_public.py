#!/usr/bin/env python3
"""Preview or apply reviewed file snapshots between independent private/public repos.

Run from the public checkout. Public policies/docs remain target-owned. No source
history, working changes, ignored files, commits, or pushes are transferred.
"""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tempfile
import unicodedata

STATE = "Tools/Repository/export-state.json"
POLICY_FILES = ("Tools/Repository/check.py", "Tools/Repository/policy.json",
                "Tools/Repository/reviewed-images.json", ".gitleaks.toml")


class ExportError(Exception):
    pass


def reject_git_redirection():
    redirects = {"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_INDEX_FILE", "GIT_CONFIG",
                 "GIT_NAMESPACE", "GIT_SHALLOW_FILE", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES"}
    if any(name in redirects or name.startswith("GIT_CONFIG_") for name in os.environ):
        raise ExportError("Git environment redirection is not allowed during public export")


def git(repo, *args, data=None):
    reject_git_redirection()
    environment = os.environ.copy()
    environment["GIT_NO_LAZY_FETCH"] = "1"
    result = subprocess.run(["git", "-C", str(repo), *args], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    if result.returncode:
        raise ExportError(f"Git {args[0]} failed; command output is not displayed")
    return result.stdout


def repository(path):
    return Path(git(Path(path).resolve(), "rev-parse", "--show-toplevel").decode().strip()).resolve()


def commit(repo, ref):
    return git(repo, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()


def safe_name(name):
    path = PurePosixPath(name)
    if (not name or name in {".", ".."} or path.is_absolute() or str(path) != name or "\\" in name
            or any(part in {".", ".."} or part.casefold() == ".git" for part in path.parts)
            or any(ord(c) < 32 for c in name)):
        raise ExportError("Unsafe repository path (value omitted)")
    return name


def entries(repo, ref):
    files = {}
    for record in git(repo, "ls-tree", "-rz", "--full-tree", ref).split(b"\0"):
        if record:
            header, raw_name = record.split(b"\t", 1)
            mode, kind, oid = header.decode().split()
            name = safe_name(raw_name.decode("utf-8"))
            files[name] = (mode, kind, oid)
    return files


def blob(repo, item):
    mode, kind, oid = item
    if mode not in {"100644", "100755"} or kind != "blob":
        raise ExportError("Symlinks, submodules and special file modes cannot be exported")
    data = git(repo, "cat-file", "blob", oid)
    if data.startswith(b"version https://git-lfs.github.com/spec/v1"):
        raise ExportError("Git LFS pointers are not exportable; review the real file content first")
    return data


def independent_storage(repo):
    for name in ("objects/info/alternates", "objects/info/http-alternates"):
        path = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-path", name).decode().strip())
        if path.exists() or path.is_symlink():
            raise ExportError("Alternate Git object stores are not allowed during public export")
    if git(repo, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise ExportError("Full Git history is required to verify repository independence")
    # A partial clone may fetch missing objects implicitly; export is offline.
    config = git(repo, "config", "--list", "--name-only").decode().splitlines()
    if any(name == "extensions.partialclone" or name.endswith(".promisor") for name in config):
        raise ExportError("Partial-clone object stores are not supported for public export")


def fingerprint(mode, data):
    return {"mode": mode, "sha256": hashlib.sha256(data).hexdigest()}


def matches(name, patterns):
    return any(name == p or (p.endswith("/") and name.startswith(p)) for p in patterns)


def check_destination(root, name, exists):
    # Check components without following links, including ignored directories.
    path = root
    parts = PurePosixPath(safe_name(name)).parts
    for i, part in enumerate(parts):
        path /= part
        try:
            info = path.lstat()
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode):
            raise ExportError("Target path contains a symlink: " + name)
        if i < len(parts) - 1 and ((path / ".git").exists() or (path / ".git").is_symlink()):
            raise ExportError("Target path enters a nested Git checkout: " + name)
        if i < len(parts) - 1 and not stat.S_ISDIR(info.st_mode):
            raise ExportError("Target parent is not a directory: " + name)
        if i == len(parts) - 1:
            if not exists:
                raise ExportError("Refusing to overwrite an untracked or ignored target path: " + name)
            if not stat.S_ISREG(info.st_mode):
                raise ExportError("Target path is not a regular file: " + name)


def clean_target(target, expected, files):
    if commit(target, "HEAD") != expected:
        raise ExportError("Target HEAD changed during export")
    if git(target, "status", "--porcelain=v1", "--untracked-files=all"):
        raise ExportError("Target must be clean, including staged and untracked changes")
    # Compare bytes as well: skip-worktree/assume-unchanged cannot hide a conflict.
    for name, item in files.items():
        check_destination(target, name, True)
        path = target / name
        if not path.is_file() or path.read_bytes() != blob(target, item):
            raise ExportError("Target working content differs from HEAD: " + name)
        executable = bool(path.stat().st_mode & 0o111)
        if executable != (item[0] == "100755"):
            raise ExportError("Target file mode differs from HEAD: " + name)


def load_checker(target, files):
    for name in POLICY_FILES:
        if name not in files:
            raise ExportError("Target must already contain its reviewed public policy: " + name)
    # The caller's private policies never decide what may become public.
    spec = importlib.util.spec_from_file_location("tsx_reviewed_public_check", target / POLICY_FILES[0])
    module = importlib.util.module_from_spec(spec)
    old_bytecode = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = old_bytecode
    return module


def canonical(value):
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode()


def excluded_patterns(values):
    patterns = []
    for value in values:
        safe_name(value[:-1] if value.endswith("/") else value)
        patterns.append(value)
    return patterns


def audit_snapshot(checker, target, snapshot, scanner):
    with tempfile.TemporaryDirectory(prefix="tsx-public-export-check-") as directory:
        scratch = Path(directory)
        git(scratch, "init", "-q", "--template=")
        index = []
        for name, (mode, data) in sorted(snapshot.items()):
            # Raw bytes bypass global attributes/clean filters, including LFS.
            oid = git(scratch, "hash-object", "-w", "--stdin", data=data).decode().strip()
            index.append(f"{mode} {oid}\t{name}\n".encode())
        # Only fresh blob objects and a tree are made; no source refs/commits.
        git(scratch, "update-index", "--index-info", data=b"".join(index))
        tree = git(scratch, "write-tree").decode().strip()
        audit = checker.Audit(scratch, scanner, None)
        audit.tree(tree)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                audit.finish()
        except SystemExit as error:
            raise ExportError("Proposed public snapshot failed the target's repository safety checks") from error


def plan_export(source, ref, target, excludes, scanner):
    source = repository(source)
    target = repository(target)
    if source == target or source in target.parents or target in source.parents:
        raise ExportError("Source and target must be separate, non-nested checkouts")
    source_common = Path(git(source, "rev-parse", "--path-format=absolute", "--git-common-dir").decode().strip())
    target_common = Path(git(target, "rev-parse", "--path-format=absolute", "--git-common-dir").decode().strip())
    if source_common.resolve() == target_common.resolve():
        raise ExportError("Source and target must not share a Git object database")
    independent_storage(source)
    independent_storage(target)
    source_commit = commit(source, ref)
    target_commit = commit(target, "HEAD")
    source_history = set(git(source, "rev-list", "--all", source_commit).split())
    target_history = set(git(target, "rev-list", "--all").split())
    if source_history & target_history:
        raise ExportError("Source and target share commit history; use an independent public repository")
    source_files = entries(source, source_commit)
    target_files = entries(target, target_commit)
    clean_target(target, target_commit, target_files)
    checker = load_checker(target, target_files)
    policy_audit = checker.Audit(target, scanner, None)
    settings = policy_audit.policy.get("export")
    if not isinstance(settings, dict):
        raise ExportError("Target policy has no reviewed export configuration")
    owned = excluded_patterns(settings["target_owned_files"] + settings["target_owned_directories"])
    excluded = excluded_patterns(settings["excluded_source_directories"] + excludes)
    if not matches(STATE, owned):
        raise ExportError("Export state must be target-owned by public policy")
    skipped = []
    selected = {}
    for name, item in source_files.items():
        if matches(name, owned):
            skipped.append({"path": name, "reason": "target-owned: update directly in the public checkout"})
        elif matches(name, excluded):
            skipped.append({"path": name, "reason": "explicitly excluded"})
        elif not policy_audit.allowed_path(name):
            raise ExportError("Source path is not public; review target policy or explicitly --exclude it: " + name)
        else:
            selected[name] = (item[0], blob(source, item))
    old_state = {"version": 1, "files": {}}
    if STATE in target_files:
        old_state = json.loads(blob(target, target_files[STATE]))
        if old_state.get("version") != 1 or not isinstance(old_state.get("files"), dict):
            raise ExportError("Unsupported or invalid export state")
    managed = old_state["files"]
    for name, item in managed.items():
        safe_name(name)
        if (not policy_audit.allowed_path(name) or matches(name, owned)
                or not isinstance(item, dict) or item.get("mode") not in {"100644", "100755"}
                or not isinstance(item.get("sha256"), str) or len(item["sha256"]) != 64
                or any(c not in "0123456789abcdef" for c in item["sha256"])):
            raise ExportError("Invalid managed path or fingerprint in export state: " + name)
    snapshot = {name: (item[0], blob(target, item)) for name, item in target_files.items()}
    next_managed = dict(managed)
    changes = []
    for name in sorted(set(selected) | set(managed)):
        if matches(name, excluded):
            continue
        incoming = selected.get(name)
        current = snapshot.get(name)
        current_id = fingerprint(*current) if current else None
        incoming_id = fingerprint(*incoming) if incoming else None
        baseline = managed.get(name)
        if baseline and current_id != baseline and current_id != incoming_id:
            raise ExportError("Target managed file changed independently; reconcile explicitly: " + name)
        if not baseline and current and current_id != incoming_id:
            raise ExportError("Refusing to overwrite unrelated target content: " + name)
        if incoming is None:
            if current:
                del snapshot[name]
                changes.append({"action": "delete", "path": name, "before": current_id})
            next_managed.pop(name, None)
        else:
            snapshot[name] = incoming
            next_managed[name] = incoming_id
            if current_id != incoming_id:
                changes.append({"action": "change" if current else "add", "path": name,
                                "before": current_id, "after": incoming_id})
    state_bytes = canonical({"version": 1, "files": next_managed})
    if snapshot.get(STATE) != ("100644", state_bytes):
        before = fingerprint(*snapshot[STATE]) if STATE in snapshot else None
        snapshot[STATE] = ("100644", state_bytes)
        changes.append({"action": "change" if before else "add", "path": STATE,
                        "before": before, "after": fingerprint("100644", state_bytes)})
    folded = {}
    for name in snapshot:
        key = unicodedata.normalize("NFC", name).casefold()
        if key in folded and name != folded[key]:
            raise ExportError("Public snapshot has case/Unicode-colliding paths")
        folded[key] = name
    for change in changes:
        check_destination(target, change["path"], change["path"] in target_files)
    audit_snapshot(checker, target, snapshot, scanner)
    clean_target(target, target_commit, target_files)
    manifest = {"source_commit": source_commit, "target_commit": target_commit,
                "changes": sorted(changes, key=lambda item: item["path"]), "skipped": skipped,
                "managed_files": len(next_managed),
                "adopted_paths": sorted(set(next_managed) - set(managed)),
                "explicit_exclusions": sorted(excluded)}
    manifest["plan_sha256"] = hashlib.sha256(canonical(manifest)).hexdigest()
    return target, target_commit, target_files, snapshot, manifest


def write_file(root, name, mode, data, existed):
    check_destination(root, name, existed)
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".tsx-export-", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
    try:
        temporary.chmod(0o755 if mode == "100755" else 0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def apply_plan(target, target_commit, old_files, snapshot, manifest):
    clean_target(target, target_commit, old_files)
    originals = {change["path"]: (old_files[change["path"]][0], blob(target, old_files[change["path"]]))
                 if change["path"] in old_files else None for change in manifest["changes"]}
    touched = []
    try:
        for change in manifest["changes"]:
            name = change["path"]
            check_destination(target, name, name in old_files)
            touched.append(name)
            if change["action"] == "delete":
                (target / name).unlink()
            else:
                write_file(target, name, *snapshot[name], name in old_files)
    except (OSError, ExportError):
        for name in reversed(touched):
            original = originals[name]
            if original:
                write_file(target, name, *original, (target / name).exists())
            elif (target / name).is_file() and not (target / name).is_symlink():
                (target / name).unlink()
        raise ExportError("Export write failed; reviewed tracked file contents were restored") from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="Private source checkout; only committed blobs are read")
    parser.add_argument("--ref", default="HEAD", help="Committed source ref (default HEAD)")
    parser.add_argument("--target", default=".", help="Independent clean public checkout (default current directory)")
    parser.add_argument("--exclude", action="append", default=[], help="Explicit source path or directory/ to retain privately")
    parser.add_argument("--gitleaks", help="Explicit pinned scanner, otherwise target's verified local installation")
    parser.add_argument("--apply", action="store_true", help="Write the reviewed snapshot, without staging, committing or pushing")
    parser.add_argument("--expect-plan", help="Required with --apply: SHA256 from the exact reviewed preview")
    args = parser.parse_args()
    if args.apply and not args.expect_plan:
        parser.error("--apply requires --expect-plan from a reviewed preview")
    target, target_commit, old_files, snapshot, manifest = plan_export(
        args.source, args.ref, args.target, args.exclude, args.gitleaks)
    if args.expect_plan and args.expect_plan != manifest["plan_sha256"]:
        raise ExportError("Export plan changed; review a new preview before applying")
    if args.apply:
        apply_plan(target, target_commit, old_files, snapshot, manifest)
    manifest["applied"] = args.apply
    print(json.dumps(manifest, indent=2, ensure_ascii=True))


if __name__ == "__main__":
    try:
        main()
    except (ExportError, OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print("Public export stopped: " + str(error), file=sys.stderr)
        raise SystemExit(1) from None
