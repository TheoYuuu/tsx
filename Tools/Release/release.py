#!/usr/bin/env python3
"""Prepare, notarize and verify a TSX release. Never pushes, tags or publishes."""
import argparse
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TEAM = "97K37J92QD"
ACCOUNT = "com.lumax.tsx"
TOOLS = ROOT / ".build/ReleaseTools/Sparkle-2.10.0/bin"
MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def run(*args, capture=False):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, check=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout.decode().strip() if capture else None


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def code_paths(app):
    files = []
    bundles = []
    for path in app.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MAGIC:
                    files.append(path)
        elif path.suffix in {".app", ".xpc", ".framework"}:
            bundles.append(path)
    return files, sorted(bundles, key=lambda p: len(p.parts), reverse=True) + [app]


def verify(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != ACCOUNT:
        raise RuntimeError("Unexpected app identity")
    if info.get("SUFeedURL") != "https://lumaxspace.com/updates/tsx/appcast.xml":
        raise RuntimeError("Unexpected update feed")
    if not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        raise RuntimeError("Update signature verification must be enabled")
    for source, name in [("LICENSE", "TSX-LICENSE.txt"),
                         ("THIRD_PARTY_NOTICES.md", "TSX-ThirdPartyNotices.md"),
                         ("Config/Licenses/Sparkle-LICENSE.txt", "Sparkle-LICENSE.txt")]:
        if (app / "Contents/Resources" / name).read_bytes() != (ROOT / source).read_bytes():
            raise RuntimeError(f"Missing or changed distribution license: {name}")
    public = run(TOOLS / "generate_keys", "--account", ACCOUNT, "-p", capture=True)
    if info.get("SUPublicEDKey") != public:
        raise RuntimeError("Release key does not match this Mac's update signing key")
    run("codesign", "--verify", "--deep", "--strict", "--all-architectures", app)
    files, bundles = code_paths(app)
    for path in files + bundles:
        detail = subprocess.run(["codesign", "-dv", "--verbose=4", str(path)], check=True,
                                capture_output=True).stderr.decode()
        if f"TeamIdentifier={TEAM}\n" not in detail or "Authority=Developer ID Application:" not in detail:
            raise RuntimeError(f"Missing Developer ID signature: {path.name}")
        if not re.search(r"flags=.*\bruntime\b", detail) or "Timestamp=" not in detail:
            raise RuntimeError(f"Missing runtime or secure timestamp: {path.name}")
        payload = run("codesign", "-d", "--entitlements", ":-", path, capture=True)
        entitlements = plistlib.loads(payload.encode()) if payload else {}
        # Xcode preserves this identity-only entitlement from the pinned Sparkle
        # binary. No debugging, sandbox or runtime exceptions are permitted.
        sparkle_autoupdate = app / "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
        allowed = {"com.apple.application-identifier": "org.sparkle-project.Sparkle.Autoupdate"}
        if entitlements and not (path == sparkle_autoupdate and entitlements == allowed):
            raise RuntimeError(f"Unexpected release entitlements: {path.name}")
    arches = run("lipo", "-archs", app / "Contents/MacOS/TSX", capture=True).split()
    if set(arches) != {"arm64", "x86_64"}:
        raise RuntimeError("Release must contain both Mac architectures")
    run("python3", "Tools/CodexRuntime/verify_bundle.py", app, "--configuration", "Release")
    return info


def prepare(args):
    if run("git", "status", "--porcelain", capture=True):
        raise RuntimeError("Commit reviewed source changes before preparing a release")
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", args.identity or ""):
        raise RuntimeError("Supply an existing Developer ID certificate SHA-1")
    if args.directory.exists():
        raise RuntimeError("Use a new release directory; existing evidence is never overwritten")
    source = run("git", "rev-parse", "HEAD", capture=True)
    run("python3", "Tools/CodexRuntime/package.py", "--configuration", "Release", "--verify-only")
    args.directory.mkdir(parents=True)
    derived = args.directory / "DerivedData"
    with (args.directory / "build.log").open("w") as log:
        subprocess.run(["xcodebuild", "-project", "TranslateX.xcodeproj", "-scheme", "TranslateX",
                        "-configuration", "Release", "-destination", "generic/platform=macOS",
                        "-derivedDataPath", str(derived), "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=YES",
                        "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "-quiet", "build"],
                       cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    app = args.directory / "TSX.app"
    run("ditto", derived / "Build/Products/Release/TSX.app", app)
    files, bundles = code_paths(app)
    for path in files + bundles:
        run("codesign", "--force", "--sign", args.identity, "--preserve-metadata=identifier",
            "--options", "runtime", "--timestamp", path)
    info = verify(app)
    if run("git", "status", "--porcelain", capture=True) or source != run("git", "rev-parse", "HEAD", capture=True):
        raise RuntimeError("Source changed during preparation; candidate cannot be released")
    run("ditto", "-c", "-k", "--keepParent", app, args.directory / "notarization.zip")
    write(args.directory / "release.json", {
        "commit": source, "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "identity": args.identity, "appZipSHA256": sha(args.directory / "notarization.zip"),
        "state": "signed-awaiting-notarization", "architectures": ["arm64", "x86_64"]})
    print(f"Signed candidate: {app}. Not notarized or published.")


def submit(args, metadata):
    stage = args.stage
    expected = "signed-awaiting-notarization" if stage == "app" else "app-notarized-dmg-signed"
    if metadata["state"] != expected:
        raise RuntimeError(f"Cannot submit {stage} in state {metadata['state']}")
    record = args.directory / f"notary-{stage}.json"
    if record.exists():
        raise RuntimeError("Submission already recorded. Inspect its status; do not upload again")
    asset = args.directory / ("notarization.zip" if stage == "app" else metadata["dmg"])
    expected_sha = metadata["appZipSHA256"] if stage == "app" else metadata["submittedDmgSHA256"]
    if sha(asset) != expected_sha:
        raise RuntimeError("Notarization input changed")
    result = run("xcrun", "notarytool", "submit", asset, "--keychain-profile", args.profile,
                 "--output-format", "json", capture=True)
    record.write_text(result + "\n")
    print(f"Submitted {stage}: {json.loads(result)['id']}. Run finish after Apple accepts it.")


def finish(args, metadata):
    stage = args.stage
    record = json.loads((args.directory / f"notary-{stage}.json").read_text())
    result = run("xcrun", "notarytool", "info", record["id"], "--keychain-profile", args.profile,
                 "--output-format", "json", capture=True)
    status = json.loads(result)
    write(args.directory / f"notary-{stage}-status.json", status)
    if status["status"] != "Accepted":
        raise RuntimeError(f"Apple status: {status['status']}; no release artifacts published")
    app = args.directory / "TSX.app"
    if stage == "app":
        if metadata["state"] != "signed-awaiting-notarization":
            raise RuntimeError("App stage already finalized")
        verify(app)
        run("xcrun", "stapler", "staple", app)
        run("xcrun", "stapler", "validate", app)
        run("spctl", "--assess", "--type", "execute", "--verbose=4", app)
        layout = args.directory / "dmg-layout"
        layout.mkdir()
        run("ditto", app, layout / "TSX.app")
        (layout / "Applications").symlink_to("/Applications", target_is_directory=True)
        dmg = f"TSX-{metadata['version']}-macOS-universal.dmg"
        run("hdiutil", "create", "-volname", "TSX", "-srcfolder", layout, "-format", "UDZO", args.directory / dmg)
        run("codesign", "--sign", metadata["identity"], "--timestamp", args.directory / dmg)
        run("codesign", "--verify", "--strict", args.directory / dmg)
        metadata.update(state="app-notarized-dmg-signed", dmg=dmg, submittedDmgSHA256=sha(args.directory / dmg))
    else:
        if metadata["state"] != "app-notarized-dmg-signed":
            raise RuntimeError("DMG stage already finalized")
        dmg = args.directory / metadata["dmg"]
        if sha(dmg) != metadata["submittedDmgSHA256"]:
            raise RuntimeError("Submitted DMG changed")
        run("xcrun", "stapler", "staple", dmg)
        run("xcrun", "stapler", "validate", dmg)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", dmg)
        artifacts = args.directory / "artifacts"
        artifacts.mkdir()
        shutil.copyfile(dmg, artifacts / dmg.name)
        run(TOOLS / "generate_appcast", "--account", ACCOUNT, "--maximum-deltas", "0",
            "--download-url-prefix", f"https://github.com/TheoYuuu/tsx/releases/download/v{metadata['version']}/",
            "--link", "https://lumaxspace.com/products/tsx/", artifacts)
        run(TOOLS / "sign_update", "--account", ACCOUNT, "--verify", artifacts / "appcast.xml")
        (artifacts / "SHA256SUMS.txt").write_text(f"{sha(artifacts / dmg.name)}  {dmg.name}\n")
        metadata.update(state="notarized-ready-for-install-test", dmgSHA256=sha(dmg))
    write(args.directory / "release.json", metadata)
    print(metadata["state"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "submit", "finish", "verify"])
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--identity")
    parser.add_argument("--stage", choices=["app", "dmg"])
    parser.add_argument("--profile", help="Keychain profile name only; never supply a password")
    args = parser.parse_args()
    args.directory = args.directory.resolve()
    if not args.directory.is_relative_to(ROOT / ".build/Releases"):
        parser.error("Artifacts must remain under .build/Releases")
    if args.command == "prepare":
        prepare(args)
    elif args.command == "verify":
        verify(args.directory / "TSX.app")
    else:
        if not args.profile or not args.stage:
            parser.error("--profile and --stage are required")
        metadata = json.loads((args.directory / "release.json").read_text())
        (submit if args.command == "submit" else finish)(args, metadata)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release stopped: {error}") from None
