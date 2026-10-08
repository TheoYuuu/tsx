#!/usr/bin/env python3
"""Download the pinned official Sparkle tools. No credentials or global install."""
import hashlib
import subprocess
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERSION = "2.10.0"
SHA256 = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
BASE = ROOT / ".build/ReleaseTools"
ARCHIVE = BASE / f"Sparkle-{VERSION}.tar.xz"
DESTINATION = BASE / f"Sparkle-{VERSION}"


def main():
    BASE.mkdir(parents=True, exist_ok=True)
    if not ARCHIVE.exists():
        partial = ARCHIVE.with_suffix(".download")
        subprocess.run(["curl", "--fail", "--location", "--retry", "2", "--max-time", "180",
                        "--output", str(partial),
                        f"https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/{ARCHIVE.name}"], check=True)
        if hashlib.sha256(partial.read_bytes()).hexdigest() != SHA256:
            raise SystemExit("Sparkle download checksum mismatch")
        partial.rename(ARCHIVE)
    if hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != SHA256:
        raise SystemExit("Cached Sparkle archive checksum mismatch")
    if not DESTINATION.exists():
        DESTINATION.mkdir()
        with tarfile.open(ARCHIVE, "r:xz") as archive:
            for member in archive.getmembers():
                path = DESTINATION / member.name
                if not path.resolve().is_relative_to(DESTINATION):
                    raise SystemExit("Unsafe archive path")
                if member.issym() and not (path.parent / member.linkname).resolve().is_relative_to(DESTINATION):
                    raise SystemExit("Unsafe archive symlink")
                if not (member.isfile() or member.isdir() or member.issym()):
                    raise SystemExit("Unsupported archive entry")
            # macOS tar preserves framework symlinks and executable modes.
        subprocess.run(["tar", "-xJf", str(ARCHIVE), "-C", str(DESTINATION)], check=True)
    print(f"Verified official Sparkle {VERSION} archive; tools: {DESTINATION / 'bin'}")


if __name__ == "__main__":
    main()
