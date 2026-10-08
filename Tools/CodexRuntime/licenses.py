#!/usr/bin/env python3
"""Collect actual dependency license texts, including fixed-revision omissions.

The notice set deliberately includes build-time/transitive packages as a
conservative superset. It is a provenance inventory, not a legal opinion.
"""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import html
import json
from pathlib import Path
import re
import tempfile
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / ".build/CodexRuntime/license-cache"
LIMIT = 4 * 1024 * 1024
NAMES = ("LICENSE", "LICENSE-MIT", "LICENSE-APACHE", "LICENSE.md", "LICENSE.txt",
         "LICENSE.MIT", "LICENSE.APACHE", "COPYING", "LICENCE", "LICENSE-BSD", "LICENSE-ZLIB",
         "LICENSES/MIT.txt", "LICENSES/Apache-2.0.txt")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, newurl):
        raise RuntimeError("A fixed license URL redirected.")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_license(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > LIMIT:
        raise RuntimeError("License source is not a bounded regular file.")
    return path.read_text(encoding="utf-8")


def remote_license(url):
    key = sha(url.encode())
    cached = CACHE / (key + ".json")
    if cached.exists():
        value = json.loads(read_license(cached))
        if value["url"] != url:
            raise RuntimeError("License cache URL mismatch.")
        if value["text"] is not None and sha(value["text"].encode()) != value["sha256"]:
            raise RuntimeError("License cache hash mismatch.")
        return value
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(urllib.request.Request(url, headers={"Accept-Encoding": "identity"}), timeout=12) as response:
            data = response.read(LIMIT + 1)
            if response.status != 200 or response.url != url or len(data) > LIMIT:
                raise RuntimeError("Unexpected license download response.")
            text = data.decode("utf-8")
            value = {"url": url, "sha256": sha(text.encode()), "text": text}
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        value = {"url": url, "sha256": None, "text": None}
    with tempfile.NamedTemporaryFile(mode="w", dir=CACHE, delete=False) as output:
        json.dump(value, output)
        temporary = Path(output.name)
    temporary.replace(cached)
    return value


def fixed_repository_licenses(package, root):
    vcs_path = root / ".cargo_vcs_info.json"
    if not vcs_path.is_file():
        return []
    vcs = json.loads(read_license(vcs_path))
    commit = vcs.get("git", {}).get("sha1", "")
    repository = urllib.parse.urlparse(package.get("repository") or "")
    parts = repository.path.strip("/").split("/")
    if (repository.scheme != "https" or repository.netloc != "github.com" or len(parts) < 2
            or not re.fullmatch(r"[0-9a-f]{40}", commit)
            or not all(re.fullmatch(r"[A-Za-z0-9_.-]+", part) for part in parts[:2])):
        return []
    prefix = f"https://raw.githubusercontent.com/{parts[0]}/{parts[1].removesuffix('.git')}/{commit}/"
    # A monorepo normally places shared license texts at its root. A crate
    # directory is checked only when the root has none, never a moving branch.
    locations = [""]
    location = vcs.get("path_in_vcs", "")
    if location and not any(part in ("", ".", "..") for part in location.split("/")):
        locations.append(location + "/")
    for location in locations:
        with ThreadPoolExecutor(max_workers=6) as executor:
            values = list(executor.map(remote_license, [prefix + location + name for name in NAMES]))
        values = [value for value in values if value["text"] is not None]
        if values:
            return values
    return []


def package_licenses(package, upstream, toolchain):
    root = Path(package["manifest_path"]).parent
    if package["name"] == "translatex-codex-runtime":
        return []
    paths = sorted(path for path in root.rglob("*") if path.is_file()
                   and re.match(r"(?i)^(licen[sc]e|copying|notice|copyright|unlicense)([._-].*)?$", path.name))
    values = []
    for path in paths:
        source_path = path
        if path.is_symlink():
            # The pinned nucleo Git crate shares ../LICENSE with its matcher.
            # Its repository/links are verified by the packager's Git audit.
            source_path = path.resolve()
            if (not (package.get("source") or "").startswith("git+")
                    or not source_path.is_relative_to(root.parent) or source_path.name != "LICENSE"):
                raise RuntimeError("Unexpected linked license source.")
        text = read_license(source_path)
        values.append({"url": f"crate:{package['name']}@{package['version']}/{path.relative_to(root)}",
                       "sha256": sha(text.encode()), "text": text})
    if root.is_relative_to(upstream):
        values += [{"url": f"https://github.com/openai/codex/blob/{upstream.name.removeprefix('codex-')}/{name}",
                    "sha256": sha(read_license(upstream / name).encode()), "text": read_license(upstream / name)}
                   for name in ("LICENSE", "NOTICE")]
    if not values:
        values = fixed_repository_licenses(package, root)
    if not values and (root / "src/lib.rs").is_file():
        header = re.match(r"\A(?://[^\n]*\n)+", read_license(root / "src/lib.rs"))
        if header and "Permission is hereby granted" in header[0] and "THE SOFTWARE." in header[0]:
            text = header[0]
            values = [{"url": f"crate:{package['name']}@{package['version']}/src/lib.rs#license-header",
                       "sha256": sha(text.encode()), "text": text}]
    if not values:
        declared = package.get("license")
        selection = "Apache-2.0" if declared in ("Apache-2.0", "MIT OR Apache-2.0", "Apache-2.0/MIT") else (
            "MIT" if declared == "MIT" else None)
        if selection:
            # These published crates explicitly declare the license but omit
            # its text. Reproduce the standard terms without inventing a
            # copyright year/holder; retain supplied authors and source notices.
            license_path = toolchain / "share/doc/rust/licenses" / (selection + ".txt")
            text = read_license(license_path)
            text = text.replace("Copyright (c) <year> <copyright holders>\n\n", "")
            copyright_lines = set()
            for path in root.rglob("*.rs"):
                for line in read_license(path).splitlines():
                    if re.search(r"(?i)copyright (?:\(c\)|[0-9]|[A-Z])", line):
                        copyright_lines.add(line.strip())
            preamble = (f"{package['name']} {package['version']} declares {declared} in its published Cargo.toml.\n"
                        f"Selected terms: {selection}. The published crate and fixed source omit a license file.\n"
                        "The following standard text supplements that declaration; it is not an upstream license file.\n"
                        f"Package authors (published metadata): {', '.join(package.get('authors', [])) or 'not specified'}\n"
                        + "\n".join(sorted(copyright_lines)) + "\n\n")
            text = preamble + text
            values = [{"url": f"declared-license:{package['name']}@{package['version']}/{selection}",
                       "sha256": sha(text.encode()), "text": text, "standardTextSupplement": True}]
    return values


def generate(metadata, output, upstream, toolchain):
    CACHE.mkdir(parents=True, exist_ok=True)
    if CACHE.resolve() != CACHE or CACHE.is_symlink():
        raise RuntimeError("License cache path is unsafe.")
    packages = sorted(metadata["packages"], key=lambda package: (package["name"], package["version"]))
    sections = ["TSX — Codex runtime third-party notices\n\n"
                "This inventory includes the pinned runtime's dependency graph, including build-time packages.\n"
                "No license is assigned here to TranslateX's own source. Upstream files are reproduced below;\n"
                "where a published crate omits them, standard-text supplements are explicitly identified.\n"
                "Dependency source archives are available at the listed crates.io/version URLs; upstream Codex\n"
                "and repository-only licenses link to immutable revisions. No upstream source was modified.\n"]
    records = []
    missing = []
    supplements = []
    texts = {}
    for package in packages:
        if package["name"] == "translatex-codex-runtime":
            continue
        values = package_licenses(package, upstream, toolchain)
        item = {"name": package["name"], "version": package["version"], "license": package.get("license"),
                "repository": package.get("repository"), "texts": []}
        if not values:
            missing.append(package["name"] + "@" + package["version"])
        sections.append(f"\n{package['name']} {package['version']}\nDeclared license: {package.get('license') or 'see upstream license'}\n")
        if package.get("source", "") and package["source"].startswith("registry+"):
            source_url = f"https://crates.io/api/v1/crates/{package['name']}/{package['version']}/download"
            item["sourceArchiveURL"] = source_url
            sections.append(f"Unmodified source: {source_url}\n")
        elif package.get("repository"):
            sections.append(f"Repository: {package['repository']}\n")
        for value in values:
            item["texts"].append({"url": value["url"], "sha256": value["sha256"],
                                  "standardTextSupplement": value.get("standardTextSupplement", False)})
            if value.get("standardTextSupplement"):
                supplements.append(package["name"] + "@" + package["version"])
            sections.append(f"License text {value['sha256']} — {value['url']}\n")
            texts[value["sha256"]] = value["text"]
        records.append(item)
    # The standard library is statically linked and is not in Cargo metadata.
    rust_notices = toolchain / "share/doc/rust/COPYRIGHT-library.html"
    rust_text = html.unescape(re.sub(r"<[^>]+>", "", read_license(rust_notices)))
    sections.append("\nRust standard library 1.95.0 — bundled library copyright and license notice\n" + rust_text)
    for checksum, text in sorted(texts.items()):
        sections.append(f"\n{'=' * 72}\nLicense text {checksum}\n{'=' * 72}\n{text}\n")
    (output / "THIRD-PARTY-NOTICES.txt").write_text("".join(sections), encoding="utf-8")
    (output / "licenses.json").write_text(json.dumps({"packages": records, "missingLicenseTexts": missing,
        "standardTextSupplements": supplements,
        "rustLibraryNoticeSHA256": sha(rust_notices.read_bytes())}, indent=2) + "\n")
    if missing:
        raise RuntimeError(f"License texts are missing for {len(missing)} dependencies; inspect licenses.json.")
    return {"dependencyCount": len(records), "uniqueLicenseTexts": len(texts),
            "missingLicenseTexts": [], "standardTextSupplements": supplements, "rustStandardLibrary": "1.95.0",
            "noticeInventorySHA256": sha((output / "licenses.json").read_bytes())}
