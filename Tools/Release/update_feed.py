"""Build signed-feed inputs; the Sparkle tools remain responsible for signatures."""
from copy import deepcopy
from datetime import datetime, timezone
from email.utils import format_datetime
import json
import re
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

BASE = "https://updates.uuthings.com/tsx/macos"
FEED = BASE + "/stable/appcast.xml"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def tag(name):
    return "{" + SPARKLE + "}" + name


def release_prefix(version, build):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version) or not re.fullmatch(r"[0-9]+", str(build)):
        raise ValueError("Invalid release version/build")
    return f"tsx/macos/releases/{version}-{build}/"


def read_xml(data):
    if len(data) > 2 * 1024 * 1024 or b"<!DOCTYPE" in data or b"<!ENTITY" in data:
        raise ValueError("Feed is oversized or contains a document type/entity")
    root = ET.fromstring(data)
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError("Expected an RSS appcast")
    if len(root.findall("channel/item")) > 200:
        raise ValueError("Too many feed items")
    return root


def allowed_notes_url(raw):
    value = urlsplit(raw)
    return (value.scheme == "https" and value.netloc == "github.com" and not value.query
            and not value.fragment and "%" not in raw and ".." not in value.path.split("/")
            and any(value.path.startswith(prefix) for prefix in
                    ("/TheoYuuu/tsx/releases/tag/", "/uuthings/tsx/releases/tag/")))


def bundle_notes(path, version):
    rows = [row for row in json.loads(path.read_text()) if row["version"] == version]
    if len(rows) != 1:
        raise ValueError("Expected exactly one bundled release note for the candidate version")
    row = rows[0]
    if not row.get("notes") or len(row["notes"].encode()) > 128 * 1024:
        raise ValueError("Release notes are missing or too large")
    return row


def compose(candidate, previous, *, version, build, download_url, published_at, notes):
    """Change feed metadata only; preserve Sparkle's package signature and requirements."""
    root = read_xml(candidate)
    items = root.findall("channel/item")
    if len(items) != 1:
        raise ValueError("Expected exactly one generated candidate item")
    item = items[0]
    enclosure = item.find("enclosure")
    if (item.findtext(tag("version")) != str(build)
            or item.findtext(tag("shortVersionString")) != version
            or enclosure is None or not enclosure.get(tag("edSignature"))):
        raise ValueError("Candidate feed does not match the release identity/signature")
    if not download_url.startswith(BASE + "/"):
        raise ValueError("Unexpected download origin")
    enclosure.set("url", download_url)
    for name in ("description", tag("releaseNotesLink"), tag("fullReleaseNotesLink"), "pubDate"):
        for old in item.findall(name):
            item.remove(old)
    description = ET.SubElement(item, "description", {tag("format"): "plain-text"})
    description.text = notes["notes"]
    if notes.get("url") and allowed_notes_url(notes["url"]):
        ET.SubElement(item, tag("fullReleaseNotesLink")).text = notes["url"]
    date = datetime.fromisoformat(published_at.replace("Z", "+00:00"))
    if date.tzinfo is None:
        raise ValueError("Publication time must include a timezone")
    ET.SubElement(item, "pubDate").text = format_datetime(date.astimezone(timezone.utc))
    if previous:
        channel = root.find("channel")
        for old in read_xml(previous).findall("channel/item"):
            if old.findtext(tag("version")) == str(build):
                raise ValueError("Build already exists in the destination feed; use a new Build")
            channel.append(deepcopy(old))
    # ET intentionally discards the old XML signature comment. Sign the final
    # bytes again, after changing URLs/date/description, before uploading.
    data = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    read_xml(data)
    return data
