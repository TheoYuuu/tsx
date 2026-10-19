#!/usr/bin/env python3
"""Verify equal native panes, dividers, containment and stable theme geometry."""
import json
import sys
from pathlib import Path

metrics = json.loads(Path(sys.argv[1]).read_text())
checks = 0


def equal(actual, expected, description):
    global checks
    assert abs(actual - expected) <= 0.5, f"{description}: {actual} != {expected}"
    checks += 1


scenes = {
    "main": (980, 598), "main-stacked": (760, 780), "main-stacked-minimum": (660, 640),
    # Captured text now uses the same main workspace; retain fixture scene names.
    "quick": (980, 598), "quick-stacked": (760, 780),
    "quick-stacked-long": (760, 780), "quick-stacked-minimum": (660, 640),
}
for theme in ("light", "dark", "glass"):
    for scene, (width, height) in scenes.items():
        key = f"{scene}-{theme}"
        current = metrics[key]
        prefix = "main"
        source, result = current[f"{prefix}.sourceColumn"], current[f"{prefix}.resultColumn"]
        for axis in ("width", "height", "x" if "stacked" in scene else "y"):
            equal(source[axis], result[axis], f"{key} equal panes {axis}")
        axis, extent = ("y", "height") if "stacked" in scene else ("x", "width")
        equal(result[axis] - source[axis] - source[extent], 1, f"{key} divider")
        for name in (f"{prefix}.sourceColumn", f"{prefix}.resultColumn"):
            frame = current[name]
            assert frame["height"] >= 150, f"{key} pane too short: {frame}"
            assert 0 <= frame["x"] < width and 0 <= frame["y"] < height, key
            assert frame["x"] + frame["width"] <= width + 0.5, key
            assert frame["y"] + frame["height"] <= height + 0.5, key
            checks += 4
            for axis in ("x", "y", "width", "height"):
                equal(frame[axis], metrics[f"{scene}-light"][name][axis], f"{key} stable {name} {axis}")
        if prefix == "main":
            assert "main.brand" not in current, f"{key} unexpected brand"
            equal(current["main.titlebar"]["height"], 44, f"{key} compact titlebar height")
            lights = current["main.trafficLights"]
            equal(lights["x"], 12, f"{key} traffic light leading inset")
            equal(lights["y"] + lights["height"] / 2, 22, f"{key} traffic light center")
            equal(source["x"], 12, f"{key} workspace leading inset")
            equal(width - result["x"] - result["width"], 12, f"{key} workspace trailing inset")
            equal(height - result["y"] - result["height"], 12, f"{key} workspace bottom inset")
print(f"Passed {checks} native window geometry comparisons (0.5 pt tolerance).")
