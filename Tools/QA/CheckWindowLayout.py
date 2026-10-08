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
    "quick": (720, 430), "quick-stacked": (540, 620),
    "quick-stacked-long": (540, 620), "quick-stacked-minimum": (460, 480),
}
for theme in ("light", "dark", "glass"):
    for scene, (width, height) in scenes.items():
        key = f"{scene}-{theme}"
        current = metrics[key]
        prefix = "main" if scene.startswith("main") else "quick"
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
            equal(current["main.titlebar"]["height"], 44, f"{key} compact titlebar")
print(f"Passed {checks} native window geometry comparisons (0.5 pt tolerance).")
