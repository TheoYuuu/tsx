#!/usr/bin/env python3
"""Prepare, review and upload TSX updates. No build, notarization or website deployment."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.request
import uuid

import archive_evidence
import update_feed
import cloudflare_audit
from release import ACCOUNT, TOOLS

XML_TYPE = "application/xml; charset=utf-8"
DMG_TYPE = "application/x-apple-diskimage"
TEXT_TYPE = "text/plain; charset=utf-8"
IMMUTABLE = "public, max-age=31536000, immutable"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def keychain(service, account):
    result = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account, "-w"],
                            capture_output=True)
    if result.returncode:
        raise RuntimeError("Required Keychain credential is unavailable")
    return result.stdout.decode().strip()


def config(path):
    value = json.loads(path.read_text())
    if not re.fullmatch(r"[a-f0-9]{32}", value["account_id"]):
        raise ValueError("Invalid Cloudflare account ID")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", value["bucket"]):
        raise ValueError("Invalid R2 bucket")
    if value.get("public_origin") != "https://updates.uuthings.com":
        raise ValueError("Unexpected update origin")
    return value


def client(settings):
    import boto3
    from botocore.config import Config
    credentials = json.loads(keychain(settings["publisher_keychain_service"], settings["keychain_account"]))
    # Never inherit a broader AWS profile, Wrangler login or alternate endpoint.
    return boto3.client("s3", endpoint_url=f"https://{settings['account_id']}.r2.cloudflarestorage.com",
                        region_name="auto", aws_access_key_id=credentials["access_key_id"],
                        aws_secret_access_key=credentials["secret_access_key"],
                        aws_session_token=credentials.get("session_token"),
                        config=Config(retries={"total_max_attempts": 1}, connect_timeout=20, read_timeout=120,
                                      request_checksum_calculation="when_required",
                                      response_checksum_validation="when_required"))


def object_state(s3, bucket, key, limit=2 * 1024 * 1024):
    from botocore.exceptions import ClientError
    try:
        response = s3.get_object(Bucket=bucket, Key=key)
    except ClientError as error:
        if error.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
            return None, None
        raise
    with response["Body"] as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise RuntimeError("Remote object exceeds the expected size")
    return response["ETag"], data


def verify_object(s3, bucket, key, path, content_type, cache_control):
    response = s3.get_object(Bucket=bucket, Key=key)
    if response.get("ContentType") != content_type or response.get("CacheControl") != cache_control:
        response["Body"].close()
        raise RuntimeError("Uploaded object headers differ from the prepared plan")
    checksum = hashlib.sha256()
    total = 0
    with response["Body"] as stream:
        while chunk := stream.read(1024 * 1024):
            total += len(chunk)
            if total > path.stat().st_size:
                raise RuntimeError("Remote object is larger than the local candidate")
            checksum.update(chunk)
    if checksum.hexdigest() != archive_evidence.sha(path):
        raise RuntimeError("Uploaded object differs from the local candidate")
    return response["ETag"]


def put_immutable(s3, bucket, key, path, content_type, cache_control):
    from botocore.exceptions import BotoCoreError, ClientError
    try:
        with path.open("rb") as stream:
            s3.put_object(Bucket=bucket, Key=key, Body=stream, ContentLength=path.stat().st_size,
                          ContentType=content_type, CacheControl=cache_control, IfNoneMatch="*")
    except (BotoCoreError, ClientError):
        # A timeout may have committed; an existing identical object is also an
        # idempotent retry. In both cases read and compare actual bytes/headers.
        return verify_object(s3, bucket, key, path, content_type, cache_control)
    return verify_object(s3, bucket, key, path, content_type, cache_control)


def put_manifest(s3, bucket, key, path, expected_etag, cache_control):
    from botocore.exceptions import BotoCoreError, ClientError
    condition = {"IfMatch": expected_etag} if expected_etag else {"IfNoneMatch": "*"}
    try:
        s3.put_object(Bucket=bucket, Key=key, Body=path.read_bytes(), ContentType=XML_TYPE,
                      CacheControl=cache_control, **condition)
    except ClientError as error:
        if error.response.get("ResponseMetadata", {}).get("HTTPStatusCode") in (409, 412):
            raise RuntimeError("Manifest changed since preparation; prepare and review again") from None
        raise
    except BotoCoreError:
        # Do not blindly retry a manifest mutation after an uncertain response.
        return verify_object(s3, bucket, key, path, XML_TYPE, cache_control)
    return verify_object(s3, bucket, key, path, XML_TYPE, cache_control)


def sparkle_verify(path):
    subprocess.run([str(TOOLS / "sign_update"), "--account", ACCOUNT, "--verify", str(path)],
                   check=True, capture_output=True)


def prepare(args, settings, s3):
    output = archive_evidence.persistent_directory(args.output)
    if output.exists():
        raise RuntimeError("Use a new preparation directory; existing evidence is not overwritten")
    metadata = json.loads((args.candidate / "release.json").read_text())
    if metadata.get("state") != "notarized-ready-for-install-test" or metadata.get("workflow") != "xcode-organizer":
        raise RuntimeError("Candidate must have completed the Xcode and DMG notarization workflow")
    version, build = metadata["version"], str(metadata["build"])
    formal_prefix = update_feed.release_prefix(version, build)
    artifacts = args.candidate / "artifacts"
    filename = f"TSX-{version}-macOS-universal.dmg"
    dmg = artifacts / filename
    if archive_evidence.sha(dmg) != metadata["dmgSHA256"]:
        raise RuntimeError("Final DMG no longer matches its verified candidate")
    sparkle_verify(artifacts / "appcast.xml")
    package = update_feed.read_xml((artifacts / "appcast.xml").read_bytes()).find("channel/item/enclosure")
    if package is None or package.get("length") != str(dmg.stat().st_size):
        raise RuntimeError("Candidate feed length differs from the final package")
    subprocess.run([str(TOOLS / "sign_update"), "--account", ACCOUNT, "--verify", str(dmg),
                    package.get(update_feed.tag("edSignature"), "")], check=True, capture_output=True)
    feed_key = f"tsx/macos/{args.channel}/appcast.xml"
    etag, previous = object_state(s3, settings["bucket"], feed_key)
    output.mkdir(parents=True)
    if previous:
        (output / "previous-appcast.xml").write_bytes(previous)
        sparkle_verify(output / "previous-appcast.xml")
    batch = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8]
    prefix = formal_prefix if args.channel == "stable" else f"tsx/macos/qa/artifacts/{batch}/"
    notes = update_feed.bundle_notes(args.candidate / "published-release-notes.json", version)
    data = update_feed.compose((artifacts / "appcast.xml").read_bytes(), previous,
                              version=version, build=build, download_url=settings["public_origin"] + "/" + prefix + filename,
                              published_at=args.published_at, notes=notes)
    feed = output / "appcast.xml"
    feed.write_bytes(data)
    subprocess.run([str(TOOLS / "sign_update"), "--account", ACCOUNT, str(feed)], check=True, capture_output=True)
    sparkle_verify(feed)
    sums = output / "SHA256SUMS.txt"
    sums.write_text(f"{metadata['dmgSHA256']}  {filename}\n")
    plan = {"schema": 1, "channel": args.channel, "bucket": settings["bucket"],
            "account_id": settings["account_id"], "version": version, "build": build,
            "source_commit": metadata["commit"], "feed_key": feed_key, "expected_etag": etag,
            "objects": [
                {"key": prefix + filename, "path": str(dmg.resolve()), "sha256": metadata["dmgSHA256"], "type": DMG_TYPE},
                {"key": prefix + sums.name, "path": str(sums), "sha256": archive_evidence.sha(sums), "type": TEXT_TYPE}],
            "feed_sha256": archive_evidence.sha(feed), "prepared_at": datetime.now(timezone.utc).isoformat()}
    (output / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    print(f"Prepared {args.channel} plan for TSX {version} ({build}). No objects uploaded.\n{output / 'plan.json'}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def public_verify(key, path, content_type, cache_control):
    request = urllib.request.Request("https://updates.uuthings.com/" + key,
                                     headers={"Accept-Encoding": "identity", "User-Agent": "UUThings-Update-Service/1.0"})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=120) as response:
        if response.status != 200 or response.headers.get("Content-Type") != content_type:
            raise RuntimeError("Public response has unexpected status or content type")
        if response.headers.get("Cache-Control") != cache_control:
            raise RuntimeError("Public cache policy differs from the prepared plan")
        status = response.headers.get("CF-Cache-Status", "")
        if cache_control != IMMUTABLE and status in ("HIT", "STALE", "UPDATING", "REVALIDATED"):
            raise RuntimeError("Mutable/test object was served from the CDN cache")
        checksum = hashlib.sha256()
        total = 0
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            total += len(chunk)
            if total > path.stat().st_size:
                raise RuntimeError("Public object is larger than the local candidate")
            checksum.update(chunk)
        if checksum.hexdigest() != archive_evidence.sha(path):
            raise RuntimeError("Public bytes differ from the prepared local file")
        return {"key": key, "sha256": checksum.hexdigest(), "content_type": content_type,
                "cache_control": cache_control, "cf_cache_status": status}


def upload(args, settings, s3):
    plan = json.loads((args.directory / "plan.json").read_text())
    if (plan["bucket"], plan["account_id"]) != (settings["bucket"], settings["account_id"]):
        raise RuntimeError("Plan belongs to a different bucket/account")
    channel = plan["channel"]
    if channel not in ("qa", "stable") or plan["feed_key"] != f"tsx/macos/{channel}/appcast.xml":
        raise RuntimeError("Unexpected channel or manifest path")
    if channel == "stable" and not args.confirm_production:
        raise RuntimeError("Stable publication requires explicit authorization and --confirm-production")
    audit_result = cloudflare_audit.audit(settings, keychain(settings["audit_keychain_service"], settings["keychain_account"]))
    prefix = update_feed.release_prefix(plan["version"], plan["build"]) if channel == "stable" else "tsx/macos/qa/artifacts/"
    feed = args.directory / "appcast.xml"
    if archive_evidence.sha(feed) != plan["feed_sha256"]:
        raise RuntimeError("Prepared feed changed; prepare and review again")
    sparkle_verify(feed)
    if len(plan["objects"]) != 2:
        raise RuntimeError("Expected one DMG and one checksum object")
    dmg, sums = plan["objects"]
    filename = f"TSX-{plan['version']}-macOS-universal.dmg"
    if (not dmg["key"].endswith("/" + filename) or dmg["type"] != DMG_TYPE
            or sums["key"] != dmg["key"].removesuffix(filename) + "SHA256SUMS.txt"
            or sums["type"] != TEXT_TYPE):
        raise RuntimeError("Unexpected release artifact names or types")
    item = update_feed.read_xml(feed.read_bytes()).find("channel/item")
    enclosure = item.find("enclosure") if item is not None else None
    if (enclosure is None or enclosure.get("url") != settings["public_origin"] + "/" + dmg["key"]
            or enclosure.get("length") != str(Path(dmg["path"]).stat().st_size)
            or item.findtext(update_feed.tag("version")) != plan["build"]
            or item.findtext(update_feed.tag("shortVersionString")) != plan["version"]):
        raise RuntimeError("Prepared manifest does not describe its planned artifact")
    if Path(sums["path"]).read_text() != f"{dmg['sha256']}  {filename}\n":
        raise RuntimeError("Checksum file differs from the planned DMG")
    for obj in plan["objects"]:
        if not obj["key"].startswith(prefix) or ".." in obj["key"].split("/"):
            raise RuntimeError("Object is outside its approved channel prefix")
        if archive_evidence.sha(Path(obj["path"])) != obj["sha256"]:
            raise RuntimeError("Prepared artifact changed")
    # Fail before uploading any artifact when another publisher has moved the feed.
    current, _ = object_state(s3, settings["bucket"], plan["feed_key"])
    if current != plan["expected_etag"]:
        raise RuntimeError("Manifest changed since preparation; prepare and review again")
    artifact_cache = IMMUTABLE if channel == "stable" else "no-store"
    records = []
    for obj in plan["objects"]:
        path = Path(obj["path"])
        put_immutable(s3, settings["bucket"], obj["key"], path, obj["type"], artifact_cache)
        records.append(public_verify(obj["key"], path, obj["type"], artifact_cache))
    cache = "no-cache" if channel == "stable" else "no-store"
    etag = put_manifest(s3, settings["bucket"], plan["feed_key"], feed, plan["expected_etag"], cache)
    records.append(public_verify(plan["feed_key"], feed, XML_TYPE, cache))
    receipt = {"time": datetime.now(timezone.utc).isoformat(), "manifest_etag": etag,
               "configuration_audit": audit_result, "verified": records}
    (args.directory / ("receipt-" + uuid.uuid4().hex + ".json")).write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Uploaded and verified {channel}; {len(records)} public objects match local bytes.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True, help="Private config outside Git; contains Keychain references, not credentials")
    commands = parser.add_subparsers(dest="command", required=True)
    stage = commands.add_parser("prepare", help="Read current manifest and prepare a signed reviewable plan, without uploads")
    stage.add_argument("--candidate", type=Path, required=True)
    stage.add_argument("--output", type=Path, required=True)
    stage.add_argument("--channel", choices=("qa", "stable"), default="qa")
    stage.add_argument("--published-at", required=True, help="Actual planned publication timestamp with timezone")
    send = commands.add_parser("upload")
    send.add_argument("--directory", type=Path, required=True)
    send.add_argument("--confirm-production", action="store_true")
    args = parser.parse_args()
    settings = config(args.config)
    s3 = client(settings)
    {"prepare": prepare, "upload": upload}[args.command](args, settings, s3)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # SDK errors can contain request URLs or headers. Do not echo credentials
        # or underlying service responses into terminal output or release logs.
        message = str(error) if type(error) in (ValueError, RuntimeError) else type(error).__name__
        sys.exit("Update operation stopped: " + message)
