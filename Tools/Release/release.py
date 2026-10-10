#!/usr/bin/env python3
"""Archive in Xcode, verify its notarized export, then package a DMG. Never publishes."""
import argparse
from datetime import datetime
import json
import plistlib
import re
import shlex
import shutil
import subprocess
import uuid
from pathlib import Path

import archive_evidence as evidence
from archive_evidence import sha

ROOT = Path(__file__).resolve().parents[2]
TEAM = "97K37J92QD"
ACCOUNT = "com.lumax.tsx"
TOOLS = ROOT / ".build/ReleaseTools/Sparkle-2.10.0/bin"
MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def run(*args, capture=False):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, check=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout.decode().strip() if capture else None


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def write_record(directory, metadata):
    write(directory / "release.json", metadata)
    source = directory / "source.json"
    provenance = json.loads(source.read_text()) if source.exists() else {}
    version = metadata.get("version", "pending archive")
    build = metadata.get("build", "pending archive")
    (directory / "INDEX.md").write_text(
        f"# TSX {version} ({build})\n\n"
        f"- State: `{metadata['state']}`\n"
        f"- Source commit: `{metadata.get('commit', '')}`\n"
        f"- Organizer archive: `{provenance.get('archivePath', '')}`\n"
        f"- Durable archive copy: `{directory / 'TSX.xcarchive'}` (created by prepare)\n"
        f"- Xcode submission: `{metadata.get('xcodeSubmissionID', 'pending Xcode distribution')}`\n"
        f"- DMG submission: `{metadata.get('dmgSubmissionID', 'not submitted')}`\n"
        f"- Developer ID certificate SHA-1: `{metadata.get('identity', 'pending Xcode distribution')}`\n\n"
        "App distribution must be completed in Xcode Organizer. This tool never submits an App or ZIP.\n"
        "The completed archive retains Xcode Submissions and Info.plist distribution records.\n"
        "App and DMG logs, checksums, release notes and the final appcast are kept beside this index.\n\n"
        "The submitted DMG remains unchanged. Stapling logs and failed packaging attempts are preserved in "
        "`finish-*` directories; the completed distributable and appcast are in `artifacts/`.\n\n"
        "Query an already submitted DMG without uploading it again:\n\n"
        "```sh\npython3 Tools/Release/release.py status --directory "
        + shlex.quote(str(directory)) + " --stage dmg --profile '<keychain-profile>'\n```\n"
    )


def clean_source(expected=None):
    if run("git", "status", "--porcelain", capture=True):
        raise RuntimeError("Commit reviewed source changes before releasing")
    source = run("git", "rev-parse", "HEAD", capture=True)
    if expected is not None and source != expected:
        raise RuntimeError("Source HEAD differs from the recorded archive commit")
    return source


def recorded_command(directory, name, *args):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, capture_output=True)
    (directory / f"{name}.log").write_bytes(result.stdout + result.stderr)
    result.check_returncode()
    return result.stdout.decode().strip()


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


def archive(args):
    source = clean_source()
    if args.directory.exists():
        raise RuntimeError("Use a new release directory; existing evidence is never overwritten")
    run("python3", "Tools/CodexRuntime/package.py", "--configuration", "Release", "--verify-only")
    xcode_version = run("xcodebuild", "-version", capture=True)
    args.directory.mkdir(parents=True)
    now = datetime.now()
    identifier = now.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8]
    archive_path = evidence.ARCHIVES / now.strftime("%Y-%m-%d") / f"TSX {identifier}.xcarchive"
    if archive_path.exists():
        raise RuntimeError("The new Xcode archive path already exists")
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    derived = ROOT / ".build/ReleaseArchives" / identifier / "DerivedData"
    metadata = {"schema": 2, "workflow": "xcode-organizer", "commit": source,
                "state": "archiving", "archivePath": str(archive_path)}
    write_record(args.directory, metadata)
    with (args.directory / "archive.log").open("w") as log:
        subprocess.run(["xcodebuild", "-project", "TranslateX.xcodeproj", "-scheme", "TranslateX",
                        "-configuration", "Release", "-destination", "generic/platform=macOS",
                        "-archivePath", str(archive_path), "-derivedDataPath", str(derived),
                        "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "-quiet", "archive"],
                       cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    clean_source(source)
    product, properties = evidence.archive_product(archive_path)
    info = evidence.app_info(product)
    if info.get("CFBundleIdentifier") != ACCOUNT:
        raise RuntimeError("The archive contains a different application")
    product_manifest = evidence.manifest(product)
    provenance = {"schema": 2, "workflow": "xcode-organizer", "commit": source,
                  "repository": str(ROOT), "archivePath": str(archive_path),
                  "xcodeVersion": xcode_version,
                  "version": info["CFBundleShortVersionString"], "build": str(info["CFBundleVersion"]),
                  "applicationProperties": properties,
                  "archivedAppManifestSHA256": evidence.manifest_digest(product_manifest)}
    clean_source(source)
    write(args.directory / "archived-app-manifest.json", product_manifest)
    write(args.directory / "source.json", provenance)
    metadata.update(version=provenance["version"], build=provenance["build"], state="awaiting-xcode-distribution")
    write_record(args.directory, metadata)
    print(f"Archive created: {archive_path}\nDurable record: {args.directory}")
    print("Stop here. In Xcode Organizer confirm this archive is visible, choose Distribute App / Direct Distribution "
          "(or Developer ID > Upload), wait for Ready to distribute, then Export Notarized App. "
          "Run prepare with --app only after that succeeds. No App command-line notarization fallback is permitted.")


def code_hash(path, architecture):
    result = subprocess.run(["codesign", "-d", "--verbose=4", "--arch", architecture, str(path)],
                            capture_output=True, check=True)
    found = re.search(r"^CDHash=([0-9a-fA-F]{40})$", result.stderr.decode(), re.MULTILINE)
    if not found:
        raise RuntimeError("Cannot read an exported App signing hash")
    return found[1]


def prepare(args):
    if not args.app:
        raise RuntimeError("prepare requires --app from Xcode Organizer's notarized export")
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", args.identity or ""):
        raise RuntimeError("Supply the existing Developer ID certificate SHA-1 used by Xcode")
    metadata = json.loads((args.directory / "release.json").read_text())
    if metadata.get("state") != "awaiting-xcode-distribution":
        raise RuntimeError("prepare requires a new archive awaiting Xcode distribution; legacy App candidates are rejected")
    source = json.loads((args.directory / "source.json").read_text())
    if source.get("repository") != str(ROOT) or source.get("commit") != metadata.get("commit"):
        raise RuntimeError("Source record does not match this repository and release")
    if (metadata.get("version"), str(metadata.get("build"))) != (source["version"], source["build"]):
        raise RuntimeError("Release version and build differ from the recorded archive")
    clean_source(source["commit"])
    archive_path = evidence.validate_source_archive(source, args.directory)
    exported = args.app.expanduser().absolute()
    if exported.is_symlink() or not exported.is_dir():
        raise RuntimeError("The Xcode export must be an actual App directory, not a symlink")
    distribution = evidence.xcode_distribution(archive_path, exported, source, TEAM, args.identity, code_hash)
    info = verify(exported)
    recorded_command(args.directory, "app-signature", "codesign", "-d", "--verbose=4", exported)
    recorded_command(args.directory, "app-stapler", "xcrun", "stapler", "validate", exported)
    recorded_command(args.directory, "app-gatekeeper", "spctl", "--assess", "--type", "execute", "--verbose=4", exported)
    for name in ("TSX.app", "TSX.xcarchive", "dmg-layout"):
        if (args.directory / name).exists():
            raise RuntimeError("An existing preparation artifact must not be overwritten")
    archive_manifest = evidence.manifest(archive_path, internal_links=True)
    run("ditto", archive_path, args.directory / "TSX.xcarchive")
    if evidence.manifest(args.directory / "TSX.xcarchive", internal_links=True) != archive_manifest:
        raise RuntimeError("The durable archive backup does not match its source")
    write(args.directory / "archive-backup-manifest.json", archive_manifest)
    app = args.directory / "TSX.app"
    run("ditto", exported, app)
    if evidence.manifest(app) != evidence.manifest(exported):
        raise RuntimeError("The durable notarized App copy does not match the Xcode export")
    recorded_command(args.directory, "copied-app-stapler", "xcrun", "stapler", "validate", app)
    submission = archive_path / "Submissions" / distribution["submissionID"]
    shutil.copyfile(submission / "notarization-log.json", args.directory / "notary-app-log.json")
    write(args.directory / "notary-app-status.json", distribution)
    write(args.directory / "verification.json", {"xcodeDistribution": distribution, "appSignatureVerified": True,
          "appStapledTicketVerified": True, "appGatekeeperAccepted": True, "archiveBackupVerified": True,
          "archiveBackupManifestSHA256": evidence.manifest_digest(archive_manifest)})
    shutil.copyfile(ROOT / "TranslateX/Resources/PublishedReleaseNotes.json", args.directory / "published-release-notes.json")
    clean_source(source["commit"])
    layout = args.directory / "dmg-layout"
    layout.mkdir()
    run("ditto", app, layout / "TSX.app")
    (layout / "Applications").symlink_to("/Applications", target_is_directory=True)
    dmg = f"TSX-{info['CFBundleShortVersionString']}-macOS-universal.dmg"
    run("hdiutil", "create", "-volname", "TSX", "-srcfolder", layout, "-format", "UDZO", args.directory / dmg)
    run("codesign", "--sign", args.identity, "--timestamp", args.directory / dmg)
    run("codesign", "--verify", "--strict", args.directory / dmg)
    clean_source(source["commit"])
    metadata.update(state="app-notarized-dmg-signed", identity=args.identity, dmg=dmg,
                    submittedDmgSHA256=sha(args.directory / dmg), xcodeSubmissionID=distribution["submissionID"],
                    appManifestSHA256=distribution["appManifestSHA256"], architectures=["arm64", "x86_64"])
    write_record(args.directory, metadata)
    print(f"Verified Xcode-notarized App and archive backed up. DMG awaits its separate notarization: {dmg}")


def submit(args, metadata):
    require_dmg(args)
    require_xcode_release(metadata)
    if metadata["state"] != "app-notarized-dmg-signed":
        raise RuntimeError(f"Cannot submit DMG in state {metadata['state']}")
    record = args.directory / "notary-dmg.json"
    attempt = args.directory / "notary-dmg-attempt.json"
    if record.exists() or attempt.exists():
        raise RuntimeError("Submission already recorded or attempted. Query the existing job; never upload it again")
    asset = dmg_path(args.directory, metadata)
    if sha(asset) != metadata["submittedDmgSHA256"]:
        raise RuntimeError("Notarization input changed")
    write(attempt, {"asset": asset.name, "sha256": metadata["submittedDmgSHA256"], "startedAt": datetime.now().isoformat()})
    result = run("xcrun", "notarytool", "submit", asset, "--keychain-profile", args.profile,
                 "--output-format", "json", capture=True)
    record.write_text(result + "\n")
    metadata["dmgSubmissionID"] = json.loads(result)["id"]
    write_record(args.directory, metadata)
    print(f"Submitted DMG: {metadata['dmgSubmissionID']}. Query status or run finish; do not submit again.")


def require_dmg(args):
    if args.stage != "dmg":
        raise RuntimeError("App submit/finish is forbidden. Use Xcode Organizer distribution and prepare --app; only --stage dmg is supported")


def require_xcode_release(metadata):
    if metadata.get("schema") != 2 or metadata.get("workflow") != "xcode-organizer" or not metadata.get("xcodeSubmissionID"):
        raise RuntimeError("Only a verified Xcode archive/export may enter DMG notarization; legacy App candidates are rejected")


def dmg_path(directory, metadata):
    name = metadata["dmg"]
    if Path(name).name != name or not name.endswith(".dmg"):
        raise RuntimeError("Only the recorded DMG may be submitted")
    path = directory / name
    if path.is_symlink() or not path.resolve().is_relative_to(directory.resolve()):
        raise RuntimeError("The recorded DMG must remain in its release directory")
    return path


def status(args, metadata):
    require_dmg(args)
    record = json.loads((args.directory / "notary-dmg.json").read_text())
    result = run("xcrun", "notarytool", "info", record["id"], "--keychain-profile", args.profile,
                 "--output-format", "json", capture=True)
    current = json.loads(result)
    write(args.directory / "notary-dmg-status.json", current)
    if str(current.get("id", "")).lower() != str(record["id"]).lower():
        raise RuntimeError("Apple status belongs to a different submission")
    if current["status"] in {"Accepted", "Invalid", "Rejected"}:
        log = json.loads(run("xcrun", "notarytool", "log", record["id"], "--keychain-profile", args.profile, capture=True))
        write(args.directory / "notary-dmg-log.json", log)
        if (str(log.get("jobId", "")).lower() != str(record["id"]).lower()
                or log.get("sha256") != metadata["submittedDmgSHA256"]
                or log.get("archiveFilename") != metadata["dmg"]
                or log.get("status") != current["status"]):
            raise RuntimeError("Apple notarization log does not match the submitted DMG")
    print(f"DMG submission {record['id']}: {current['status']}")
    return current


def finish(args, metadata):
    require_dmg(args)
    require_xcode_release(metadata)
    if metadata["state"] != "app-notarized-dmg-signed":
        raise RuntimeError("DMG stage already finalized or not ready; use status to query it")
    current = status(args, metadata)
    if current["status"] != "Accepted":
        raise RuntimeError(f"Apple status: {current['status']}; no release artifacts generated")
    dmg = dmg_path(args.directory, metadata)
    if sha(dmg) != metadata["submittedDmgSHA256"]:
        raise RuntimeError("Submitted DMG changed")
    artifacts = args.directory / "artifacts"
    if artifacts.exists() or artifacts.is_symlink():
        raise RuntimeError("Release artifacts already exist; they will not be overwritten")
    # Stapling changes the DMG bytes. Keep Apple's submitted input immutable so
    # a later packaging failure can be retried without another upload.
    attempt = args.directory / ("finish-" + uuid.uuid4().hex)
    candidate = attempt / "artifacts"
    candidate.mkdir(parents=True)
    final_dmg = candidate / dmg.name
    shutil.copyfile(dmg, final_dmg)
    recorded_command(attempt, "dmg-staple", "xcrun", "stapler", "staple", final_dmg)
    recorded_command(attempt, "dmg-stapler", "xcrun", "stapler", "validate", final_dmg)
    recorded_command(attempt, "dmg-gatekeeper", "spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", final_dmg)
    run(TOOLS / "generate_appcast", "--account", ACCOUNT, "--maximum-deltas", "0",
        "--download-url-prefix", f"https://github.com/TheoYuuu/tsx/releases/download/v{metadata['version']}/",
        "--link", "https://lumaxspace.com/products/tsx/", candidate)
    run(TOOLS / "sign_update", "--account", ACCOUNT, "--verify", candidate / "appcast.xml")
    final_hash = sha(final_dmg)
    (candidate / "SHA256SUMS.txt").write_text(f"{final_hash}  {dmg.name}\n")
    candidate.rename(artifacts)
    metadata.update(state="notarized-ready-for-install-test", dmgSHA256=final_hash,
                    finishAttempt=attempt.name)
    write_record(args.directory, metadata)
    print(metadata["state"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["archive", "prepare", "submit", "status", "finish", "verify"])
    parser.add_argument("--directory", type=Path, help="New durable directory outside Git, build, temporary and cache folders")
    parser.add_argument("--app", type=Path, help="Notarized TSX.app exported from this archive in Xcode Organizer")
    parser.add_argument("--identity", help="Existing Developer ID certificate SHA-1 used by the Xcode distribution")
    parser.add_argument("--stage", metavar="dmg", help="DMG only; App notarization must use Xcode Organizer")
    parser.add_argument("--profile", help="Keychain profile name only; never supply a password")
    args = parser.parse_args()
    if args.stage not in (None, "dmg"):
        parser.error("App command-line notarization is forbidden; use Xcode Organizer distribution, then prepare --app")
    if args.directory is None:
        if args.command != "archive":
            parser.error("--directory is required for this command")
        args.directory = evidence.DEFAULT_RELEASES / (datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
    args.directory = evidence.persistent_directory(args.directory)
    if args.command == "archive":
        archive(args)
    elif args.command == "prepare":
        prepare(args)
    elif args.command == "verify":
        verify(args.directory / "TSX.app")
    else:
        if not args.profile or not args.stage:
            parser.error("--profile and --stage are required")
        metadata = json.loads((args.directory / "release.json").read_text())
        {"submit": submit, "status": status, "finish": finish}[args.command](args, metadata)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release stopped: {error}") from None
