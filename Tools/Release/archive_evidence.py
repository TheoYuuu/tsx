"""Local Xcode provenance and durable-storage checks. Never signs or uploads."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import tempfile


ARCHIVES = Path.home() / "Library/Developer/Xcode/Archives"
DEFAULT_RELEASES = Path.home() / "Library/Application Support/TSX/ReleaseArchives"
TEMPORARY_ROOTS = tuple({Path(tempfile.gettempdir()).resolve(), Path("/tmp").resolve(),
                         Path("/var/tmp").resolve(), Path("/var/folders").resolve()})
FORBIDDEN_PARTS = {".build", "build", "deriveddata", "cache", "caches", ".cache", ".git", "temporaryitems"}


def git_worktree_marker(path):
    if path.is_symlink() or path.is_file():
        return True
    # Some desktop tools keep unrelated metadata in ~/.git/gk even when the
    # home directory is not a repository. Actual and partial Git stores still
    # have at least one of these anchors; linked worktrees use a .git file.
    return path.is_dir() and any((path / name).exists() or (path / name).is_symlink()
                                for name in ("HEAD", "config", "objects", "commondir", "refs"))


def persistent_directory(path):
    """Reject both the written path and its destination, including Git worktrees."""
    original = Path(path).expanduser().absolute()
    resolved = original.resolve()
    for candidate in (original, resolved):
        if any(part.casefold() in FORBIDDEN_PARTS for part in candidate.parts):
            raise RuntimeError("Release evidence cannot be stored in build or cache directories")
        if any(candidate == root or candidate.is_relative_to(root) for root in TEMPORARY_ROOTS):
            raise RuntimeError("Release evidence cannot be stored in a temporary directory")
        if any(git_worktree_marker(parent / ".git") for parent in (candidate, *candidate.parents)):
            raise RuntimeError("Release evidence must be outside every Git working tree")
    if resolved.exists() and not resolved.is_dir():
        raise RuntimeError("Release evidence path is not a directory")
    return resolved


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def manifest(directory, *, internal_links=False):
    """Compare all file bytes, executable modes and symlink targets, without following links."""
    if directory.is_symlink() or not directory.is_dir():
        raise RuntimeError(f"Expected an actual directory: {directory.name}")
    result = {".": {"type": "directory", "mode": stat.S_IMODE(directory.stat().st_mode)}}
    for base, directories, files in os.walk(directory, followlinks=False):
        for name in sorted(directories + files):
            path = Path(base) / name
            key = str(path.relative_to(directory))
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                if internal_links and not path.resolve().is_relative_to(directory.resolve()):
                    raise RuntimeError(f"Archive symlink escapes its self-contained backup: {key}")
                result[key] = {"type": "symlink", "target": os.readlink(path)}
            elif stat.S_ISREG(mode):
                result[key] = {"type": "file", "sha256": sha(path), "mode": stat.S_IMODE(mode)}
            elif stat.S_ISDIR(mode):
                result[key] = {"type": "directory", "mode": stat.S_IMODE(mode)}
            else:
                raise RuntimeError(f"Unsupported archive entry: {key}")
    return result


def manifest_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def app_info(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())


def validate_version(app, source):
    info = app_info(app)
    if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), str(info.get("CFBundleVersion"))) != (
            "com.lumax.tsx", source["version"], source["build"]):
        raise RuntimeError("App identity, version or build does not match the recorded archive")
    return info


def archive_product(archive):
    info = plistlib.loads((archive / "Info.plist").read_bytes())
    properties = info["ApplicationProperties"]
    relative = Path(properties["ApplicationPath"])
    if relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError("Invalid archived application path")
    product = archive / "Products" / relative
    if not product.resolve().is_relative_to(archive.resolve() / "Products"):
        raise RuntimeError("Archived application escapes the Products directory")
    return product, properties


def validate_source_archive(source, directory):
    if source.get("schema") != 2 or source.get("workflow") != "xcode-organizer":
        raise RuntimeError("Run the archive command first; legacy command-line App notarization is not accepted")
    archive = Path(source["archivePath"])
    if not archive.is_absolute() or archive.suffix != ".xcarchive" or archive.is_symlink():
        raise RuntimeError("Invalid Xcode archive path")
    if not archive.resolve().is_relative_to(ARCHIVES.resolve()):
        raise RuntimeError("The source archive must remain in Xcode's standard Archives directory")
    product, properties = archive_product(archive)
    if properties != source["applicationProperties"]:
        raise RuntimeError("The archive's original application properties changed")
    recorded = json.loads((directory / "archived-app-manifest.json").read_text())
    if manifest_digest(recorded) != source["archivedAppManifestSHA256"] or manifest(product) != recorded:
        raise RuntimeError("The original archived app changed after the clean source build")
    validate_version(product, source)
    return archive


def xcode_distribution(archive, exported, source, team, identity, cdhash):
    """Require an accepted Xcode submission whose ticket and app match the export."""
    validate_version(exported, source)
    exported_manifest = manifest(exported)
    submissions = archive / "Submissions"
    if (submissions.is_symlink() or not submissions.is_dir()
            or not submissions.resolve().is_relative_to(archive.resolve())):
        raise RuntimeError("Xcode Submissions must be a real directory inside the archive")
    distributions = plistlib.loads((archive / "Info.plist").read_bytes()).get("Distributions", [])
    failures = []
    for item in distributions:
        if (item.get("task"), item.get("destination"), item.get("uploadDestination")) != (
                "distribute", "upload", "Developer ID"):
            continue
        try:
            identifier = item.get("identifier", "")
            if not re.fullmatch(r"[0-9a-fA-F-]{36}", identifier):
                raise RuntimeError("Invalid Xcode submission identifier")
            if item.get("teamID") != team or item.get("certificateSHA1", "").upper() != identity.upper():
                raise RuntimeError("Xcode distribution signing identity does not match")
            if str(item.get("uploadedBuildNumber")) != source["build"]:
                raise RuntimeError("Xcode distribution build does not match")
            for name in ("preparationEvent", "uploadEvent"):
                event = item.get(name, {})
                if event.get("state") != "success" or event.get("errors") not in ([], None):
                    raise RuntimeError("Xcode preparation and upload must both have succeeded")
            submission = submissions / identifier
            if submission.is_symlink() or not submission.resolve().is_relative_to(submissions.resolve()):
                raise RuntimeError("Xcode submission path escapes the archive")
            log_path = submission / "notarization-log.json"
            if not log_path.resolve().is_relative_to(archive.resolve()):
                raise RuntimeError("Xcode notarization log escapes the archive")
            log = json.loads(log_path.read_text())
            if str(log.get("jobId", "")).lower() != identifier.lower():
                raise RuntimeError("Xcode submission and notarization job do not match")
            if (log.get("status"), log.get("statusCode")) != ("Accepted", 0) or log.get("issues") not in (None, []):
                raise RuntimeError("Xcode App notarization has not been accepted")
            if not re.fullmatch(r"[0-9a-fA-F]{64}", log.get("sha256", "")):
                raise RuntimeError("Xcode notarization log has no valid upload checksum")
            submitted_app = submission / exported.name
            validate_version(submitted_app, source)
            if manifest(submitted_app) != exported_manifest:
                raise RuntimeError("Exported App differs from the accepted Xcode submission")
            filename = log.get("archiveFilename", "")
            if not filename or Path(filename).name != filename:
                raise RuntimeError("Invalid notarized archive filename")
            prefix = filename + "/" + exported.name
            root_architectures = set()
            tickets = log.get("ticketContents", [])
            if not tickets:
                raise RuntimeError("Xcode notarization log has no signing tickets")
            for ticket in tickets:
                ticket_path = ticket.get("path", "")
                if ticket_path != prefix and not ticket_path.startswith(prefix + "/"):
                    raise RuntimeError("Notarization ticket is outside the exported App")
                relative = Path(ticket_path[len(prefix):].lstrip("/"))
                target = exported / relative
                if ".." in relative.parts or not target.resolve().is_relative_to(exported.resolve()):
                    raise RuntimeError("Notarization ticket path escapes the exported App")
                architecture = ticket.get("arch")
                expected = ticket.get("cdhash", "")
                if (architecture not in {"arm64", "x86_64"} or ticket.get("digestAlgorithm") != "SHA-256"
                        or not re.fullmatch(r"[0-9a-fA-F]{40}", expected)):
                    raise RuntimeError("Unsupported notarization signing ticket")
                if cdhash(target, architecture).lower() != expected.lower():
                    raise RuntimeError("Exported App code does not match Apple's notarization ticket")
                if ticket_path == prefix:
                    root_architectures.add(architecture)
            if root_architectures != {"arm64", "x86_64"}:
                raise RuntimeError("Notarization tickets must cover both App architectures")
            return {"submissionID": identifier, "uploadSHA256": log["sha256"],
                    "status": log["status"], "statusSummary": log.get("statusSummary"),
                    "certificateSHA1": item["certificateSHA1"], "teamID": team,
                    "ticketCount": len(tickets), "appManifestSHA256": manifest_digest(exported_manifest)}
        except (OSError, ValueError, KeyError, RuntimeError) as error:
            failures.append(str(error))
    reason = failures[-1] if failures else "No successful Xcode Developer ID upload record"
    raise RuntimeError(reason + "; finish distribution in Xcode Organizer; there is no command-line App fallback")
