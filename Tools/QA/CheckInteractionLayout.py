#!/usr/bin/env python3
"""Check native settings alignment and equal quick columns from review metrics."""
import json
import sys
from pathlib import Path

metrics = json.loads(Path(sys.argv[1]).read_text())
checks = 0


def equal(actual, expected, description):
    global checks
    assert abs(actual - expected) <= 0.5, f"{description}: {actual} != {expected}"
    checks += 1


for theme in ("light", "dark", "glass"):
    baseline = metrics[f"general-{theme}"]
    for scene in ("general", "shortcuts", "privacy", "list"):
        current = metrics[f"{scene}-{theme}"]
        for axis in ("x", "y", "width", "height"):
            equal(current["settings.tabs"][axis], baseline["settings.tabs"][axis], f"{scene}-{theme} tabs {axis}")
        for axis in ("x", "y", "height"):
            equal(current["settings.pageHeading"][axis], baseline["settings.pageHeading"][axis], f"{scene}-{theme} heading {axis}")
    for scene in ("quick", "quick-long", "quick-minimum"):
        current = metrics[f"{scene}-{theme}"]
        left, right = current["quick.sourceColumn"], current["quick.resultColumn"]
        for axis in ("width", "height", "y"):
            equal(left[axis], right[axis], f"{scene}-{theme} columns {axis}")
        equal(right["x"] - left["x"] - left["width"], 1, f"{scene}-{theme} divider")
        for column in ("quick.sourceColumn", "quick.resultColumn"):
            for axis in ("x", "y", "width", "height"):
                equal(current[column][axis], metrics[f"{scene}-light"][column][axis], f"{scene}-{theme} stable {column} {axis}")
print(f"Passed {checks} native layout comparisons (0.5 pt tolerance).")
