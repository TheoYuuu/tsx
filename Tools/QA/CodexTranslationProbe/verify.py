#!/usr/bin/env python3
"""Build the fixed, account-free Codex client prototype and run local fixtures."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unicodedata
import urllib.request


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
WORK = REPO / ".build/QA/CodexTranslationPrototype"
COMMIT = "36650394c5b38c2990ccf2a3457165ca3e9d9726"
SOURCE_NAME = f"codex-{COMMIT}"
SOURCE_URL = f"https://codeload.github.com/openai/codex/tar.gz/{COMMIT}"
SOURCE_SHA256 = "392ac15292437f4163fc6b05cdcc53e80cdc15f88459fd969673e6ac717d7af5"
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_EXPANDED = 256 * 1024 * 1024
MAX_FILE = 16 * 1024 * 1024
MAX_ENTRIES = 20_000
BUILD_TIMEOUT = 900
PROBE_TIMEOUT = 300
SHARED_INPUTS = {"src/sse_guard.rs": REPO / "Runtime/CodexHelper/src/sse_guard.rs"}
INPUTS = ("src/main.rs", "src/translation.rs", "Cargo.toml", "Cargo.lock", "probe.py")


def digest(stream):
    result = hashlib.sha256()
    while chunk := stream.read(1024 * 1024):
        result.update(chunk)
    return result.hexdigest()


def regular_file(path, limit):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
        raise RuntimeError(f"Expected a bounded regular file: {path.name}")
    return info


def directory(path):
    """Create task-owned directories without following an existing symlink."""
    relative = path.relative_to(REPO)
    current = REPO
    for part in relative.parts:
        current /= part
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            if not stat.S_ISDIR(current.lstat().st_mode):
                raise RuntimeError("A task directory is not a real directory.")
    return path


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("The fixed source download unexpectedly redirected.")


def archive_path():
    downloads = directory(WORK / "downloads")
    archive = downloads / "codex-36650394.tar.gz"
    if not archive.exists() and not archive.is_symlink():
        # No environment proxy, authentication handler, cookies, or netrc.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        request = urllib.request.Request(SOURCE_URL, headers={"Accept-Encoding": "identity"})
        started = time.monotonic()
        with tempfile.NamedTemporaryFile(dir=downloads, prefix="source-", delete=False) as output:
            temporary = Path(output.name)
            try:
                with opener.open(request, timeout=10) as response:
                    if response.status != 200 or response.url != SOURCE_URL:
                        raise RuntimeError("Unexpected source download response.")
                    size = response.headers.get("Content-Length")
                    if size is not None and (not size.isdecimal() or int(size) > MAX_ARCHIVE):
                        raise RuntimeError("Source archive exceeds the download limit.")
                    total = 0
                    # read1 returns after at most one buffered socket read, so
                    # a slow trickle cannot hide the overall deadline inside
                    # a request to fill a large buffer.
                    while chunk := response.read1(64 * 1024):
                        total += len(chunk)
                        if total > MAX_ARCHIVE or time.monotonic() - started > 120:
                            raise RuntimeError("Source download exceeded its size or time limit.")
                        output.write(chunk)
                output.flush()
                with temporary.open("rb") as stream:
                    if digest(stream) != SOURCE_SHA256:
                        raise RuntimeError("Source archive SHA-256 does not match the pinned source.")
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
    regular_file(archive, MAX_ARCHIVE)
    with archive.open("rb") as stream:
        if digest(stream) != SOURCE_SHA256:
            raise RuntimeError("Cached archive SHA-256 mismatch; existing evidence was preserved.")
    return archive


def audited_members(archive):
    """Audit every header and link before creating any extracted file."""
    members = {}
    spellings = set()
    expanded = 0
    for item in archive:
        name = item.name.rstrip("/")
        path = PurePosixPath(name)
        if (not name or len(name) > 1024 or "\\" in name or path.is_absolute()
                or any(ord(char) < 32 for char in name)
                or any(part in ("", ".", "..") for part in name.split("/"))
                or path.parts[0] != SOURCE_NAME):
            raise RuntimeError("Unsafe path in source archive.")
        spelling = unicodedata.normalize("NFC", name).casefold()
        if name in members or spelling in spellings:
            raise RuntimeError("Duplicate or ambiguous path in source archive.")
        if (not (item.isdir() or item.isfile() or item.issym()) or item.mode & 0o7000
                or (not item.issym() and item.mode & 0o002)):
            raise RuntimeError("Unsupported file type or privileged mode in source archive.")
        if item.size < 0 or item.size > MAX_FILE:
            raise RuntimeError("Source archive member exceeds its size limit.")
        expanded += item.size
        members[name] = item
        spellings.add(spelling)
        if len(members) > MAX_ENTRIES or expanded > MAX_EXPANDED:
            raise RuntimeError("Source archive exceeds extraction limits.")
    if SOURCE_NAME not in members or not members[SOURCE_NAME].isdir():
        raise RuntimeError("Source archive has no expected root directory.")
    for name, item in members.items():
        for parent in PurePosixPath(name).parents:
            if str(parent) == ".":
                break
            if str(parent) not in members or not members[str(parent)].isdir():
                raise RuntimeError("Archive member has a non-directory ancestor.")
        if item.issym():
            link = PurePosixPath(item.linkname)
            if (not item.linkname or "\\" in item.linkname or link.is_absolute()
                    or any(ord(char) < 32 for char in item.linkname)
                    or any(part in ("", ".", "..") for part in item.linkname.split("/"))):
                raise RuntimeError("Unsafe source archive symlink.")
            target = str(PurePosixPath(name).parent / link)
            if target not in members or not members[target].isfile():
                raise RuntimeError("Source symlink does not point to a regular archive member.")
    return members


def extract_source(archive, members, parent):
    # Never use extractall: do not apply uid/gid, timestamps, extended metadata,
    # setuid/setgid/sticky bits, or group/other write permissions from tar.
    with tempfile.TemporaryDirectory(dir=parent, prefix="unpack-") as temporary:
        stage = Path(temporary)
        for name, item in sorted(members.items(), key=lambda pair: len(PurePosixPath(pair[0]).parts)):
            if item.isdir():
                (stage / name).mkdir(mode=0o755)
        for name, item in members.items():
            destination = stage / name
            if item.isfile():
                with archive.extractfile(item) as source, destination.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                destination.chmod(0o755 if item.mode & 0o111 else 0o644)
        # Links are created last and never serve as extraction ancestors.
        for name, item in members.items():
            if item.issym():
                (stage / name).symlink_to(item.linkname)
        (stage / SOURCE_NAME).rename(parent / SOURCE_NAME)


def check_source(archive, members, parent):
    source = parent / SOURCE_NAME
    if not stat.S_ISDIR(source.lstat().st_mode):
        raise RuntimeError("Source root is not a real directory.")
    actual = {SOURCE_NAME}
    for location, directories, files in os.walk(source, followlinks=False):
        actual.update(str((Path(location) / name).relative_to(parent)) for name in directories + files)
    if actual != set(members):
        raise RuntimeError("Existing upstream source contains missing or additional paths; no files were changed.")
    # Check all directories first, before any read could traverse a local link.
    for name, item in members.items():
        if item.isdir() and not stat.S_ISDIR((parent / name).lstat().st_mode):
            raise RuntimeError("Upstream source directory type changed.")
    manifest = []
    for name, item in members.items():
        path = parent / name
        info = path.lstat()
        entry = {"path": name}
        if item.issym():
            if not stat.S_ISLNK(info.st_mode) or os.readlink(path) != item.linkname:
                raise RuntimeError("Upstream source symlink changed.")
            entry.update(type="symlink", target=item.linkname)
        else:
            # Older pristine extractions preserve the official tar's 664/775
            # modes. Permit its original group-write bit when reusing them,
            # never an added one. Fresh extraction above is always 644/755.
            if info.st_mode & 0o7002 or (info.st_mode & 0o020 and not item.mode & 0o020):
                raise RuntimeError("Upstream source has unsafe local permissions.")
            if item.isdir():
                entry.update(type="directory")
            else:
                if (not stat.S_ISREG(info.st_mode) or info.st_size != item.size
                        or info.st_mode & 0o111 != item.mode & 0o111):
                    raise RuntimeError("Upstream source file type, size, or executable bits changed.")
                with archive.extractfile(item) as original, path.open("rb") as local:
                    expected = digest(original)
                    if digest(local) != expected:
                        raise RuntimeError("Upstream source file contents changed; no files were replaced.")
                entry.update(type="file", sha256=expected)
        manifest.append(entry)
    return manifest


def stop_group(process):
    # Only this Popen's new session is targeted; never signal the caller's group.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def run(command, cwd, env, log, timeout):
    with log.open("xb") as output:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            stop_group(process)
            raise
    if code:
        raise RuntimeError(f"Command failed ({code}); inspect {log.name} in the run directory.")


def build_environment(cargo):
    home = os.environ.get("HOME")
    if not home:
        raise RuntimeError("The parent HOME is required and must retain its original meaning.")
    env = {
        "HOME": home, "PATH": f"{cargo.parent}:/usr/bin:/bin:/usr/sbin:/sbin",
        "CARGO_HOME": str(directory(WORK / "cargo-home")),
        "RUSTUP_HOME": str(directory(WORK / "rustup-home")),
        "CARGO_TARGET_DIR": str(directory(WORK / "target")),
        "TMPDIR": str(directory(WORK / "tmp")),
        "RUSTC": str(cargo.with_name("rustc")), "RUSTUP_AUTO_INSTALL": "0",
        "CARGO_BUILD_JOBS": "4", "RUSTFLAGS": "-D warnings",
        "CARGO_NET_GIT_FETCH_WITH_CLI": "true", "CARGO_HTTP_TIMEOUT": "60",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
        "GIT_SSH_COMMAND": "/usr/bin/false", "GIT_CONFIG_COUNT": "2",
        "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": "",
        "GIT_CONFIG_KEY_1": "core.hooksPath", "GIT_CONFIG_VALUE_1": "/dev/null",
        "LANG": "C", "LC_ALL": "C", "PYTHONDONTWRITEBYTECODE": "1",
    }
    for key in ("DEVELOPER_DIR", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET"):
        if key in os.environ:
            env[key] = os.environ[key]
    # Cargo otherwise consults ancestor .cargo configs even with CARGO_HOME.
    for parent in (WORK, *WORK.parents):
        for name in ("config", "config.toml"):
            path = parent / ".cargo" / name
            if path.exists() or path.is_symlink():
                raise RuntimeError("An ancestor Cargo configuration exists; isolated build was not started.")
    for name in ("config", "config.toml", "credentials", "credentials.toml"):
        path = Path(env["CARGO_HOME"]) / name
        if path.exists() or path.is_symlink():
            raise RuntimeError("Private Cargo home contains configuration or credentials; build was not started.")
    return env


def load_inputs():
    result = {}
    for name in (*INPUTS, *SHARED_INPUTS):
        path = SHARED_INPUTS.get(name, HERE / name)
        if path.resolve(strict=True) != path:
            raise RuntimeError("Tracked probe inputs must not be symlinks.")
        regular_file(path, MAX_FILE)
        result[name] = path.read_bytes()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cargo", required=True, type=Path, help="Existing Cargo 1.95 executable; sibling rustc 1.95 is required.")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This prototype's fixture isolation requires macOS.")
    cargo = args.cargo.expanduser().resolve(strict=True)
    rustc = cargo.with_name("rustc")
    if not cargo.is_file() or not os.access(cargo, os.X_OK) or not rustc.is_file() or not os.access(rustc, os.X_OK):
        parser.error("Provide an existing Cargo executable with an executable sibling rustc.")
    inputs = load_inputs()
    directory(WORK)
    lock_path = WORK / "verify.lock"
    with os.fdopen(os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "r+") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise RuntimeError("Verification lock is not a regular file.")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another prototype verification is running.") from None
        logs = directory(WORK / "builds")
        evidence = Path(tempfile.mkdtemp(prefix="verify-", dir=logs))
        print(f"Verification evidence: {evidence}", flush=True)
        env = build_environment(cargo)
        for program, name in ((cargo, "cargo"), (rustc, "rustc")):
            log = evidence / f"{name}-version.log"
            run([str(program), "--version"], WORK, env, log, 15)
            if not re.match(rf"{name} 1\.95\.\d+\b", log.read_text()):
                raise RuntimeError("Cargo and rustc must both be existing version 1.95; no toolchain is installed automatically.")

        archive_file = archive_path()
        parent = directory(WORK / "source")
        with tarfile.open(archive_file, "r:gz") as archive:
            members = audited_members(archive)
            source = parent / SOURCE_NAME
            if not source.exists() and not source.is_symlink():
                extract_source(archive, members, parent)
            manifest = check_source(archive, members, parent)
        (evidence / "source-integrity.json").write_text(json.dumps({
            "commit": COMMIT, "archiveSHA256": SOURCE_SHA256, "members": manifest,
        }, indent=2) + "\n")

        staged = Path(tempfile.mkdtemp(prefix="staged-app-", dir=WORK))
        (staged / "src").mkdir(mode=0o700)
        hashes = {}
        for name, content in inputs.items():
            hashes[name] = hashlib.sha256(content).hexdigest()
            destination = staged / name
            destination.write_bytes(content)
        (evidence / "inputs.json").write_text(json.dumps(hashes, indent=2) + "\n")
        run([str(cargo), "build", "--locked", "--manifest-path", str(staged / "Cargo.toml")],
            staged, env, evidence / "build.log", BUILD_TIMEOUT)
        for name, expected in hashes.items():
            with (staged / name).open("rb") as stream:
                if digest(stream) != expected:
                    raise RuntimeError("Staged probe input changed during the build.")
        if load_inputs() != inputs:
            raise RuntimeError("Tracked probe input changed; freeze inputs before running verification.")
        with archive_file.open("rb") as stream:
            if digest(stream) != SOURCE_SHA256:
                raise RuntimeError("Pinned source archive changed during the build.")
        with tarfile.open(archive_file, "r:gz") as archive:
            check_source(archive, audited_members(archive), parent)

        # probe.py intentionally locates target/debug and per-run evidence from
        # its own directory. Replace only this generated copy, never app/.
        probe = WORK / "probe.py"
        if probe.exists() or probe.is_symlink():
            regular_file(probe, MAX_FILE)
        temporary = WORK / f"probe-{evidence.name}.py"
        with temporary.open("xb") as output:
            output.write((staged / "probe.py").read_bytes())
        temporary.replace(probe)
        run([sys.executable, "-I", str(probe)], WORK, env, evidence / "probe.log", PROBE_TIMEOUT)
        print(f"Local fixture process completed successfully; inspect {evidence / 'probe.log'}.")
        print("No account or AuthManager behavior was verified; this is not product acceptance.")
    return 0


if __name__ == "__main__":
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Verification interrupted; its active process group was terminated.", file=sys.stderr)
        raise SystemExit(130) from None
    except (OSError, RuntimeError, tarfile.TarError, subprocess.TimeoutExpired) as error:
        print(f"Verification failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None
