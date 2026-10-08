#!/usr/bin/env python3
"""Build audited, signed website-channel helpers; never launch an account operation."""

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORK = ROOT / ".build/CodexRuntime"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("runtime_builder", HERE / "build.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
common = builder.common
IDENTIFIER = "com.theoyuuu.LumaxTranslate.CodexRuntime"
BINARY = "translatex-codex-runtime"
RUST_MANIFEST_URL = "https://static.rust-lang.org/dist/channel-rust-1.95.0.toml"
RUST_MANIFEST_SHA = "821ff14e4c4a1cbe1e8915f35aff0a3fbbdf8d293ad48ab8f31e3b0440c581f9"
INTEL_STD_URL = "https://static.rust-lang.org/dist/2026-04-16/rust-std-1.95.0-x86_64-apple-darwin.tar.xz"
INTEL_STD_SHA = "2be13c14122b8d4d09b7f7c434fca9ae7215ec72049944189c88c4d9128ce504"
TARGETS = {"arm64": "aarch64-apple-darwin", "x86_64": "x86_64-apple-darwin"}


def tool_inputs():
    return {str(path.relative_to(ROOT)): digest(path) for path in (
        Path(__file__), HERE / "licenses.py", HERE / "build.py", builder.AUDITOR)}


def digest(path):
    with path.open("rb") as source:
        return common.digest(source)


def fetch(url, destination, expected, maximum):
    if destination.exists():
        common.regular_file(destination, maximum)
        if digest(destination) != expected:
            raise RuntimeError("Cached official download hash mismatch.")
        return
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), common.NoRedirect())
    started = time.monotonic()
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            with opener.open(urllib.request.Request(url, headers={"Accept-Encoding": "identity"}), timeout=15) as response:
                if response.status != 200 or response.url != url:
                    raise RuntimeError("Unexpected official download response.")
                count = 0
                while chunk := response.read1(65536):
                    count += len(chunk)
                    if count > maximum or time.monotonic() - started > 180:
                        raise RuntimeError("Official download exceeded its bound.")
                    output.write(chunk)
            output.flush()
            if digest(temporary) != expected:
                raise RuntimeError("Official download hash mismatch.")
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)


def intel_std(cargo):
    """Copy only verified library files; never execute the archive's installer."""
    downloads = common.directory(WORK / "downloads")
    manifest = downloads / "channel-rust-1.95.0.toml"
    fetch(RUST_MANIFEST_URL, manifest, RUST_MANIFEST_SHA, 2 * 1024 * 1024)
    section = manifest.read_text().split("[pkg.rust-std.target.x86_64-apple-darwin]\n", 1)[1].split("\n[", 1)[0]
    if f'xz_url = "{INTEL_STD_URL}"' not in section or f'xz_hash = "{INTEL_STD_SHA}"' not in section:
        raise RuntimeError("Pinned Rust manifest does not confirm the Intel component.")
    archive_path = downloads / "rust-std-1.95.0-x86_64-apple-darwin.tar.xz"
    fetch(INTEL_STD_URL, archive_path, INTEL_STD_SHA, 128 * 1024 * 1024)
    toolchain = cargo.parent.parent
    target = toolchain / "lib/rustlib/x86_64-apple-darwin"
    prefix = "rust-std-1.95.0-x86_64-apple-darwin/rust-std-x86_64-apple-darwin/lib/rustlib/x86_64-apple-darwin/"
    expected = {}
    with tarfile.open(archive_path, "r:xz") as archive:
        members = archive.getmembers()
        if len(members) > 2000 or sum(member.size for member in members) > 512 * 1024 * 1024:
            raise RuntimeError("Rust component exceeds extraction limits.")
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not (member.isdir() or member.isfile()):
                raise RuntimeError("Unsafe Rust component archive entry.")
            if member.isfile() and member.name.startswith(prefix):
                relative = member.name[len(prefix):]
                if not relative or relative in expected:
                    raise RuntimeError("Duplicate Rust component path.")
                with archive.extractfile(member) as source:
                    expected[relative] = common.digest(source)
        if not expected or not any(name.endswith(".rlib") for name in expected):
            raise RuntimeError("Rust component has no libraries.")
        if not target.exists():
            with tempfile.TemporaryDirectory(prefix="std-stage-", dir=downloads) as temporary:
                stage = Path(temporary) / "x86_64-apple-darwin"
                stage.mkdir()
                for member in members:
                    if member.isfile() and member.name.startswith(prefix):
                        destination = stage / member.name[len(prefix):]
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        with archive.extractfile(member) as source, destination.open("xb") as output:
                            shutil.copyfileobj(source, output)
                        destination.chmod(0o644)
                stage.rename(target)
    actual = {str(path.relative_to(target)) for path in target.rglob("*") if path.is_file()}
    if actual != set(expected) or target.is_symlink():
        raise RuntimeError("Private Intel standard library differs from the verified component.")
    for name, checksum in expected.items():
        path = target / name
        if path.resolve() != path or digest(path) != checksum:
            raise RuntimeError("Private Intel standard library integrity failed.")
    return {"manifestURL": RUST_MANIFEST_URL, "manifestSHA256": RUST_MANIFEST_SHA,
            "componentURL": INTEL_STD_URL, "componentSHA256": INTEL_STD_SHA,
            "installedFiles": expected}


def audit_private_toolchain(cargo):
    archives = ROOT / ".build/QA/CodexTranslationPrototype/downloads"
    pinned = {
        "cargo": "6c2ffed8e1ac9cf4dc9e80f282a869a6b237a153e7c55cca039d33de29d80aaf",
        "rustc": "149e85a285b6eba58eb6c8bdf7deb1b93763890598e62cb635a712e3a8454f04",
        "rust-std": "9b30089b0f767cb91b2190ffec55a9beeb2a21a1405d8da0f664d7e09d08e6d8",
    }
    result = {}
    for component, checksum in pinned.items():
        name = component + "-1.95.0-aarch64-apple-darwin"
        path = archives / (name + ".tar.xz")
        common.regular_file(path, 128 * 1024 * 1024)
        if digest(path) != checksum:
            raise RuntimeError("Private toolchain component archive checksum failed.")
        prefix = name + "/" + ("rust-std-aarch64-apple-darwin" if component == "rust-std" else component) + "/"
        files = {}
        with tarfile.open(path, "r:xz") as archive:
            for item in archive:
                if not item.isfile() or not item.name.startswith(prefix):
                    continue
                relative = item.name[len(prefix):]
                if relative == "manifest.in":
                    continue
                installed = cargo.parent.parent / relative
                with archive.extractfile(item) as original:
                    expected = common.digest(original)
                if installed.resolve() != installed or digest(installed) != expected:
                    raise RuntimeError("Installed private toolchain differs from its official archive.")
                files[relative] = expected
        result[component] = {"url": f"https://static.rust-lang.org/dist/2026-04-16/{name}.tar.xz",
                             "archiveSHA256": checksum, "installedFiles": files}
    return result


def command_output(command, env, cwd):
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, timeout=30, check=True)
    return result.stdout + result.stderr


def build_environment(cargo, cargo_home):
    env = common.build_environment(cargo)
    env.update(CARGO_HOME=str(builder.local_directory(cargo_home)),
               CARGO_TARGET_DIR=str(common.directory(WORK / "package-target")),
               RUSTUP_HOME=str(common.directory(WORK / "rustup-home")),
               TMPDIR=str(common.directory(WORK / "tmp")), MACOSX_DEPLOYMENT_TARGET="15.0")
    # Neither a developer's alternate SDK nor caller proxy/token variables enter.
    env.pop("SDKROOT", None)
    env.pop("DEVELOPER_DIR", None)
    env["SDKROOT"] = command_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], env, WORK).strip()
    for name in ("config", "config.toml", "credentials", "credentials.toml"):
        if (cargo_home / name).exists() or (cargo_home / name).is_symlink():
            raise RuntimeError("Private Cargo cache contains ambient configuration or credentials.")
    return env


def audit_dependencies(metadata, lock_text, upstream, env):
    """Verify cached published source files against the lock's crate checksum."""
    checksums = {}
    for block in lock_text.split("[[package]]")[1:]:
        values = dict(re.findall(r'^(name|version|source|checksum) = "([^"\n]+)"$', block, re.M))
        if "checksum" in values:
            checksums[(values["name"], values["version"], values["source"])] = values["checksum"]
    records = []
    for package in metadata["packages"]:
        root = Path(package["manifest_path"]).parent
        source = package.get("source")
        if source and source.startswith("registry+"):
            expected = checksums.get((package["name"], package["version"], source))
            crate_archive = root.parent.parent.parent / "cache" / root.parent.name / (root.name + ".crate")
            common.regular_file(crate_archive, 128 * 1024 * 1024)
            if not expected or digest(crate_archive) != expected:
                raise RuntimeError("Registry source does not match the locked package checksum.")
            recorded = {}
            with tarfile.open(crate_archive, "r:gz") as archive:
                for item in archive:
                    if item.isdir():
                        continue
                    parts = PurePosixPath(item.name).parts
                    if (not item.isfile() or len(parts) < 2 or parts[0] != root.name
                            or ".." in parts or item.size > common.MAX_FILE):
                        raise RuntimeError("Locked crate archive contains an unexpected entry.")
                    name = str(PurePosixPath(*parts[1:]))
                    if name in recorded:
                        raise RuntimeError("Locked crate archive contains duplicate files.")
                    with archive.extractfile(item) as content:
                        recorded[name] = common.digest(content)
            actual_files = {str(path.relative_to(root)) for path in root.rglob("*") if path.is_file()}
            if actual_files - {".cargo-ok", ".cargo-checksum.json"} != set(recorded):
                raise RuntimeError("Cached registry source has unexpected or missing files.")
            for name, checksum in recorded.items():
                path = root / name
                if path.resolve() != path or not path.is_relative_to(root) or digest(path) != checksum:
                    raise RuntimeError("Cached registry source integrity failed.")
            records.append({"name": package["name"], "version": package["version"],
                            "packageSHA256": expected, "files": len(recorded),
                            "fileManifestSHA256": hashlib.sha256(json.dumps(recorded, sort_keys=True).encode()).hexdigest()})
        elif source and source.startswith("git+"):
            commit = source.rsplit("#", 1)[-1]
            actual = command_output(["/usr/bin/git", "-C", str(root), "rev-parse", "HEAD"], env, WORK).strip()
            if actual != commit:
                raise RuntimeError("Git dependency does not match the locked commit.")
            command_output(["/usr/bin/git", "-C", str(root), "diff", "--exit-code", "HEAD", "--"], env, WORK)
            git_root = command_output(["/usr/bin/git", "-C", str(root), "rev-parse", "--show-toplevel"], env, WORK).strip()
            status = command_output(["/usr/bin/git", "-C", git_root, "status", "--porcelain", "--untracked-files=all"], env, WORK)
            if any(line != "?? .cargo-ok" for line in status.splitlines()):
                raise RuntimeError("Git dependency contains unexpected working-tree changes.")
            records.append({"name": package["name"], "version": package["version"], "commit": commit})
        elif package["name"] != BINARY and not root.is_relative_to(upstream):
            raise RuntimeError("Unexpected path dependency outside the audited upstream source.")
    return records


def inspect_binary(path, expected_arches, env, evidence):
    arches = command_output(["/usr/bin/lipo", "-archs", str(path)], env, WORK).strip().split()
    if set(arches) != set(expected_arches):
        raise RuntimeError("Packaged helper architecture mismatch.")
    loads = command_output(["/usr/bin/otool", "-l", str(path)], env, WORK)
    minimums = re.findall(r"\bminos\s+(\d+(?:\.\d+){0,2})", loads)
    if len(minimums) != len(expected_arches) or any(value not in ("15.0", "15.0.0") for value in minimums):
        raise RuntimeError("Packaged helper must have an exact macOS 15 minimum for every slice.")
    libraries = command_output(["/usr/bin/otool", "-L", str(path)], env, WORK)
    for line in libraries.splitlines():
        if line.startswith("\t") and not line.lstrip().startswith(("/usr/lib/", "/System/Library/")):
            raise RuntimeError("Packaged helper refers to a non-system dynamic library.")
    common.run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(path)],
               WORK, env, evidence / (path.parent.name + "-signature-verify.log"), 30)
    signature = command_output(["/usr/bin/codesign", "-d", "--verbose=4", str(path)], env, WORK)
    if f"Identifier={IDENTIFIER}\n" not in signature or "runtime" not in signature:
        raise RuntimeError("Packaged helper code identity or Hardened Runtime is missing.")
    (evidence / (path.parent.name + "-load-commands.log")).write_text(loads)
    (evidence / (path.parent.name + "-libraries.log")).write_text(libraries)
    (evidence / (path.parent.name + "-signature.log")).write_text(signature)
    return {"architectures": arches, "minimumMacOS": "15.0", "identifier": IDENTIFIER,
            "hardenedRuntime": True, "bytes": path.stat().st_size, "sha256": digest(path)}


def verify_existing(configurations):
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"}
    current = {name: hashlib.sha256(data).hexdigest() for name, data in builder.inputs().items()}
    for configuration in configurations:
        directory = WORK / "package" / configuration
        for name in (BINARY, "THIRD-PARTY-NOTICES.txt", "package-manifest.json"):
            path = directory / name
            common.regular_file(path, 512 * 1024 * 1024)
            if path.resolve() != path:
                raise RuntimeError("Package artifact path is not canonical.")
        manifest = json.loads((directory / "package-manifest.json").read_text())
        arches = [platform.machine()] if configuration == "Debug" else ["arm64", "x86_64"]
        if (manifest.get("schema") != 1 or manifest.get("configuration") != configuration
                or manifest.get("runtimeInputs") != current or manifest.get("toolInputs") != tool_inputs()
                or manifest.get("sha256") != digest(directory / BINARY)
                or manifest.get("noticesSHA256") != digest(directory / "THIRD-PARTY-NOTICES.txt")
                or set(manifest.get("architectures", [])) != set(arches)
                or manifest.get("identifier") != IDENTIFIER or manifest.get("minimumMacOS") != "15.0"
                or manifest.get("qaFeatures") is not False or manifest.get("accountAccess") is not False
                or manifest.get("cargoLocked") is not True or manifest.get("cargoOffline") is not True
                or manifest.get("sourceCommit") != common.COMMIT
                or manifest.get("sourceArchiveSHA256") != common.SOURCE_SHA256
                or manifest.get("licenses", {}).get("missingLicenseTexts") != []):
            raise RuntimeError("Package is missing or stale; run Tools/CodexRuntime/package.py before Xcode.")
        command_output(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(directory / BINARY)], env, WORK)
        actual = command_output(["/usr/bin/lipo", "-archs", str(directory / BINARY)], env, WORK).strip().split()
        if set(actual) != set(arches):
            raise RuntimeError("Package architecture check failed.")
        print(f"Verified {configuration} package against current sources and notices.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("Debug", "Release", "All"), default="All")
    parser.add_argument("--cargo", type=Path, default=ROOT / ".build/QA/CodexTranslationPrototype/toolchain/bin/cargo")
    parser.add_argument("--cargo-home", type=Path, default=ROOT / ".build/QA/CodexAuthPrototype/cargo-home")
    parser.add_argument("--sign-identity", default="-", help="Ad-hoc by default; use an explicitly authorized existing certificate SHA-1")
    parser.add_argument("--verify-only", action="store_true", help="Validate cached package/inputs without building, downloading or signing")
    args = parser.parse_args()
    if args.sign_identity != "-" and not re.fullmatch(r"[0-9A-Fa-f]{40}", args.sign_identity):
        parser.error("Use '-' or the SHA-1 of an existing authorized signing identity.")
    if sys.platform != "darwin" or platform.machine() not in TARGETS:
        parser.error("Packaging requires a supported macOS host.")
    configurations = ["Debug", "Release"] if args.configuration == "All" else [args.configuration]
    if args.verify_only:
        verify_existing(configurations)
        return 0
    cargo = args.cargo.absolute()
    if cargo.resolve(strict=True) != cargo or not cargo.is_relative_to(ROOT / ".build"):
        parser.error("Use the verified private Cargo under this checkout's .build.")
    common.directory(WORK)
    with os.fdopen(os.open(WORK / "package.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "r+") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise RuntimeError("Package lock is not a regular file.")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        frozen = builder.inputs()
        frozen_tools = tool_inputs()
        evidence = Path(tempfile.mkdtemp(prefix="package-", dir=common.directory(WORK / "builds")))
        print(f"Package evidence: {evidence}", flush=True)
        archive_path = common.archive_path()
        source_parent = common.directory(WORK / "source")
        with tarfile.open(archive_path, "r:gz") as archive:
            members = common.audited_members(archive)
            if not (source_parent / common.SOURCE_NAME).exists():
                common.extract_source(archive, members, source_parent)
            source_manifest = common.check_source(archive, members, source_parent)
        env = build_environment(cargo, args.cargo_home.absolute())
        for executable, name in ((cargo, "cargo"), (cargo.with_name("rustc"), "rustc")):
            value = command_output([str(executable), "--version"], env, WORK)
            if not re.match(rf"{name} 1\.95\.0\b", value):
                raise RuntimeError("Packaging requires the pinned private Rust 1.95.0 toolchain.")
            (evidence / (name + "-version.log")).write_text(value)
        (evidence / "private-toolchain-integrity.json").write_text(json.dumps(audit_private_toolchain(cargo), indent=2) + "\n")
        if args.configuration in ("Release", "All"):
            (evidence / "intel-standard-library.json").write_text(json.dumps(intel_std(cargo), indent=2) + "\n")
        staged = Path(tempfile.mkdtemp(prefix="staged-package-", dir=WORK))
        for name, data in frozen.items():
            destination = staged / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        input_hashes = {name: hashlib.sha256(data).hexdigest() for name, data in frozen.items()}
        (evidence / "inputs.json").write_text(json.dumps(input_hashes, indent=2) + "\n")
        (evidence / "source-integrity.json").write_text(json.dumps({"commit": common.COMMIT,
            "archiveSHA256": common.SOURCE_SHA256, "members": source_manifest}, indent=2) + "\n")
        metadata_path = evidence / "cargo-metadata.json"
        common.run([str(cargo), "metadata", "--format-version", "1", "--locked", "--offline",
                    "--filter-platform", TARGETS[platform.machine()], "--manifest-path", str(staged / "Cargo.toml")],
                   staged, env, metadata_path, 120)
        metadata = json.loads(metadata_path.read_text())
        dependencies = audit_dependencies(metadata, frozen["Cargo.lock"].decode(), source_parent / common.SOURCE_NAME, env)
        (evidence / "dependency-integrity.json").write_text(json.dumps(dependencies, indent=2) + "\n")
        products = {}
        for configuration in configurations:
            arches = [platform.machine()] if configuration == "Debug" else ["arm64", "x86_64"]
            slices = []
            for arch in arches:
                target = TARGETS[arch]
                command = [str(cargo), "build", "--release", "--locked", "--offline", "--no-default-features",
                           "--bin", BINARY, "--target", target, "--manifest-path", str(staged / "Cargo.toml")]
                print(f"Building {configuration} {arch}…", flush=True)
                common.run(command, staged, env, evidence / f"{configuration}-{arch}-build.log", 3600)
                slices.append(Path(env["CARGO_TARGET_DIR"]) / target / "release" / BINARY)
            output = evidence / configuration
            output.mkdir()
            executable = output / BINARY
            if len(slices) == 1:
                shutil.copyfile(slices[0], executable)
            else:
                common.run(["/usr/bin/lipo", "-create", *map(str, slices), "-output", str(executable)],
                           WORK, env, evidence / f"{configuration}-lipo.log", 30)
            executable.chmod(0o755)
            # Both app configurations use optimized helpers. Strip the final
            # executable, never proc-macro metadata needed during compilation.
            common.run(["/usr/bin/strip", "-S", "-x", str(executable)], WORK, env,
                       evidence / f"{configuration}-strip.log", 30)
            common.run(["/usr/bin/codesign", "--force", "--sign", args.sign_identity, "--identifier", IDENTIFIER,
                        "--options", "runtime", "--timestamp=none", str(executable)], WORK, env,
                       evidence / f"{configuration}-sign.log", 30)
            products[configuration] = inspect_binary(executable, arches, env, evidence)
            # Invalid IPC is rejected before account_root(), runtime creation,
            # management policy loading, or any Keychain/network operation.
            checked = subprocess.run([str(executable)], input="{}\n", text=True, capture_output=True,
                                     env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": env["TMPDIR"]},
                                     cwd=evidence, timeout=5)
            if checked.returncode != 64 or checked.stdout or checked.stderr:
                raise RuntimeError("Signed host helper did not reject invalid IPC cleanly.")
        license_spec = importlib.util.spec_from_file_location("runtime_licenses", HERE / "licenses.py")
        license_module = importlib.util.module_from_spec(license_spec)
        license_spec.loader.exec_module(license_module)
        notices = license_module.generate(json.loads(metadata_path.read_text()), evidence,
                                          source_parent / common.SOURCE_NAME, cargo.parent.parent)
        if (builder.inputs() != frozen or tool_inputs() != frozen_tools
                or any((staged / name).read_bytes() != data for name, data in frozen.items())):
            raise RuntimeError("Runtime inputs changed during packaging; frozen evidence was preserved.")
        with tarfile.open(archive_path, "r:gz") as archive:
            common.check_source(archive, common.audited_members(archive), source_parent)
        if audit_dependencies(metadata, frozen["Cargo.lock"].decode(), source_parent / common.SOURCE_NAME, env) != dependencies:
            raise RuntimeError("Dependency inputs changed during packaging.")
        for configuration, product in products.items():
            output = evidence / configuration
            shutil.copyfile(evidence / "THIRD-PARTY-NOTICES.txt", output / "THIRD-PARTY-NOTICES.txt")
            manifest = {"schema": 1, "configuration": configuration, "binary": BINARY, **product,
                        "sourceCommit": common.COMMIT, "sourceArchiveSHA256": common.SOURCE_SHA256,
                        "runtimeInputs": input_hashes, "cargoLocked": True, "cargoOffline": True,
                        "toolInputs": frozen_tools,
                        "qaFeatures": False, "accountAccess": False, "intelRuntimeTested": False,
                        "noticesSHA256": digest(output / "THIRD-PARTY-NOTICES.txt"), "licenses": notices,
                        "evidence": str(evidence.relative_to(ROOT))}
            (output / "package-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            destination = common.directory(WORK / "package" / configuration)
            for name in (BINARY, "THIRD-PARTY-NOTICES.txt", "package-manifest.json"):
                temporary = destination / ("." + name + ".new")
                shutil.copyfile(output / name, temporary)
                temporary.chmod(0o755 if name == BINARY else 0o644)
                temporary.replace(destination / name)
        (evidence / "result.json").write_text(json.dumps({"passed": True, "products": products,
            "licenses": notices, "accountAccess": False, "intelRuntimeTested": False}, indent=2) + "\n")
        print(f"Packaged {', '.join(configurations)}; no account operation was executed.", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        print(f"Runtime packaging failed: {error}", file=sys.stderr)
        raise SystemExit(1) from None
