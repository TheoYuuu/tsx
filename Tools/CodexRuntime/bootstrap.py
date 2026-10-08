#!/usr/bin/env python3
"""Prepare pinned build inputs on Apple Silicon, without installing global tools."""
import argparse
import importlib.util
from pathlib import Path, PurePosixPath
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("runtime_package", HERE / "package.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)
common = package.common
ROOT = package.ROOT
PINNED = {
    "cargo": "6c2ffed8e1ac9cf4dc9e80f282a869a6b237a153e7c55cca039d33de29d80aaf",
    "rustc": "149e85a285b6eba58eb6c8bdf7deb1b93763890598e62cb635a712e3a8454f04",
    "rust-std": "9b30089b0f767cb91b2190ffec55a9beeb2a21a1405d8da0f664d7e09d08e6d8",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        parser.error("This pinned compiler setup currently supports Apple Silicon build hosts only")
    base = ROOT / ".build/QA/CodexTranslationPrototype"
    downloads = common.directory(base / "downloads")
    toolchain = base / "toolchain"
    cargo = toolchain / "bin/cargo"
    if args.verify_only:
        package.audit_private_toolchain(cargo)
        print("Pinned Rust compiler files match the official archives")
        return
    for component, checksum in PINNED.items():
        name = f"{component}-1.95.0-aarch64-apple-darwin"
        package.fetch(f"https://static.rust-lang.org/dist/2026-04-16/{name}.tar.xz",
                      downloads / f"{name}.tar.xz", checksum, 128 * 1024 * 1024)
    if not toolchain.exists():
        with tempfile.TemporaryDirectory(prefix="toolchain-stage-", dir=base) as temporary:
            stage = Path(temporary) / "toolchain"
            stage.mkdir()
            for component in PINNED:
                name = f"{component}-1.95.0-aarch64-apple-darwin"
                prefix = name + "/" + ("rust-std-aarch64-apple-darwin" if component == "rust-std" else component) + "/"
                with tarfile.open(downloads / f"{name}.tar.xz", "r:xz") as archive:
                    for member in archive.getmembers():
                        if not member.isfile() or not member.name.startswith(prefix):
                            continue
                        relative = PurePosixPath(member.name[len(prefix):])
                        if relative.is_absolute() or ".." in relative.parts:
                            raise RuntimeError("Unsafe compiler archive entry")
                        if str(relative) == "manifest.in":
                            continue
                        destination = stage / relative
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        with archive.extractfile(member) as source, destination.open("xb") as output:
                            shutil.copyfileobj(source, output)
                        destination.chmod(0o755 if member.mode & 0o111 else 0o644)
            stage.rename(toolchain)
    package.audit_private_toolchain(cargo)
    package.intel_std(cargo)
    work = common.directory(package.WORK)
    source_parent = common.directory(work / "source")
    with tarfile.open(common.archive_path(), "r:gz") as archive:
        members = common.audited_members(archive)
        if not (source_parent / common.SOURCE_NAME).exists():
            common.extract_source(archive, members, source_parent)
        common.check_source(archive, members, source_parent)
    cargo_home = common.directory(ROOT / ".build/QA/CodexAuthPrototype/cargo-home")
    env = package.build_environment(cargo, cargo_home)
    # The actual build remains locked/offline; fetching is a separate explicit step.
    with tempfile.TemporaryDirectory(prefix="bootstrap-crate-", dir=work) as temporary:
        stage = Path(temporary)
        for name, data in package.builder.inputs().items():
            path = stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        subprocess.run([str(cargo), "fetch", "--locked", "--manifest-path", str(stage / "Cargo.toml")],
                       cwd=stage, env=env, check=True)
    subprocess.run([sys.executable, str(HERE / "package.py"), "--configuration", "All"], cwd=ROOT, check=True)
    print("Runtime prepared. Open TranslateX.xcodeproj or run Scripts/verify.sh")


if __name__ == "__main__":
    main()
