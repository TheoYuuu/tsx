#!/usr/bin/env python3
"""Normalize local upstream SVG syntax for Apple's SVG reader; no downloads."""
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT.parents[2] / "TranslateX/Resources/Assets.xcassets"
NUMBER = re.compile(r"[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?")
ARITY = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7}


def path_with_separated_flags(source):
    # Optimized SVGs join arc flags, e.g. "0 01.683". CoreSVG logs
    # errors for those otherwise valid paths. Keep every numeric literal and
    # geometry, but emit explicit commands with space-separated arguments.
    index, command, output = 0, None, []
    while index < len(source):
        while index < len(source) and source[index] in " ,\t\n\r":
            index += 1
        if index == len(source):
            break
        if source[index].isalpha():
            command = source[index]
            index += 1
            if command.upper() == "Z":
                output.append(command)
                command = None
                continue
        if command is None or command.upper() not in ARITY:
            raise ValueError("Unsupported SVG path command")
        arguments = []
        for position in range(ARITY[command.upper()]):
            while index < len(source) and source[index] in " ,\t\n\r":
                index += 1
            if command.upper() == "A" and position in (3, 4):
                if index == len(source) or source[index] not in "01":
                    raise ValueError("Invalid SVG arc flag")
                arguments.append(source[index])
                index += 1
            else:
                match = NUMBER.match(source, index)
                if not match:
                    raise ValueError("Invalid SVG path argument")
                arguments.append(match.group())
                index = match.end()
        output.append(command + " " + " ".join(arguments))
        if command in "Mm":
            command = "L" if command == "M" else "l"
    return " ".join(output)


def main():
    manifest = json.loads((ROOT / "sources.json").read_text())
    ET.register_namespace("", "http://www.w3.org/2000/svg")
    for entry in manifest["assets"]:
        upstream = (ROOT / "Source" / (entry["name"] + ".svg")).read_bytes()
        if hashlib.sha256(upstream).hexdigest() != entry["sha256"]:
            raise ValueError("Upstream source checksum mismatch")
        svg = ET.fromstring(upstream)
        svg.set("width", "24")
        svg.set("height", "24")
        svg.attrib.pop("style", None)  # Browser-only flex and font-relative sizing.
        for element in svg.iter():
            if "d" in element.attrib:
                element.set("d", path_with_separated_flags(element.get("d")))
            for key, value in list(element.attrib.items()):
                if value == "currentColor":
                    element.set(key, "#000")  # SVG's default color; templates tint at runtime.
        asset = entry["asset"]
        folder = ASSETS / (asset + ".imageset")
        (folder / (asset + ".svg")).write_text(ET.tostring(svg, encoding="unicode") + "\n")
    print(f'Prepared {len(manifest["assets"])} native SVG assets')


if __name__ == "__main__":
    main()
