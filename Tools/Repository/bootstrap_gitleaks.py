#!/usr/bin/env python3
"""Install the pinned official scanner into ignored project-local storage."""
import hashlib
import io
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = "8.30.1"
# Published in the official v8.30.1 checksums asset; changes require policy review.
CHECKSUMS = {
    ("Darwin", "arm64"): "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    ("Darwin", "x64"): "dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709",
    ("Linux", "arm64"): "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080",
    ("Linux", "x64"): "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb",
}


def main():
    system = platform.system()
    machine = {"aarch64": "arm64", "x86_64": "x64", "AMD64": "x64"}.get(platform.machine(), platform.machine())
    expected = CHECKSUMS.get((system, machine))
    if not expected:
        raise SystemExit("No verified Gitleaks archive for this platform")
    asset = f"gitleaks_{VERSION}_{system.lower()}_{machine}.tar.gz"
    url = f"https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/{asset}"
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read(40 * 1024 * 1024 + 1)
    if hashlib.sha256(archive).hexdigest() != expected:
        raise SystemExit("Gitleaks archive checksum mismatch; nothing installed")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
        member = bundle.getmember("gitleaks")
        if not member.isfile() or member.size > 40 * 1024 * 1024:
            raise SystemExit("Unexpected Gitleaks archive entry")
        binary = bundle.extractfile(member).read()
    destination = Path(__file__).resolve().parents[2] / ".build/RepositoryTools"
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(binary)
    try:
        temporary.chmod(0o755)
        actual = subprocess.check_output([str(temporary), "version"], text=True).strip()
        if actual != VERSION:
            raise SystemExit("Gitleaks executable version mismatch")
        os.replace(temporary, destination / "gitleaks")
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Installed checksum-verified Gitleaks {VERSION} in .build/RepositoryTools")


if __name__ == "__main__":
    main()
