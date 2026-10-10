#!/usr/bin/env python3
"""Capture only windows explicitly exported by the isolated visual-review app.

Pass a new output directory, followed by native review arguments, e.g.
  python3 Tools/QA/CaptureTranslationServiceReview.py .build/Review --review-batch
For the language card at normal and minimum settings sizes, use
  --review-language-settings --review-interface-language en
and repeat with zh-Hans in a new output directory.
For service rows, secondary usage pages and account fixture states, use
  --review-service-usage --review-interface-language en
and repeat with zh-Hans. All account refresh actions use the isolated loader.
Use --review-service-usage-charts for a targeted rerun of the three chart states.
Use --review-service-editor for page scrolling at both settings sizes.
Use --review-settings-refinement for dropdowns, service rows and statistics pages.
Use --review-scene quick-permission or quick-permission-screen for permission panels;
append -minimum to the scene name to check the smallest resizable panel.
No permissions are requested or changed. Existing capture access is required.
"""
import json
import math
import subprocess
import sys
import time
from pathlib import Path


def check_language_settings_layout(metrics, captured_scenes):
    """Check real SwiftUI frames; screenshots still need text/appearance review."""
    failures = []
    checks = 0
    tolerance = 0.5
    themes = ("light", "dark", "glass")
    expected = {f"{scene}-{theme}" for scene in ("general", "general-minimum") for theme in themes}

    def require(condition, scene, message):
        nonlocal checks
        checks += 1
        if not condition:
            failures.append({"scene": scene, "error": message})

    def frame(values, key, scene):
        value = values.get(key)
        valid = isinstance(value, dict) and all(
            isinstance(value.get(axis), (int, float)) and not isinstance(value.get(axis), bool)
            and math.isfinite(value[axis]) for axis in ("x", "y", "width", "height")
        )
        require(valid, scene, f"Missing or invalid layout metric: {key}")
        if not valid:
            return None
        rect = (value["x"], value["y"], value["width"], value["height"])
        require(rect[2] > 0 and rect[3] > 0, scene, f"Empty layout metric: {key}")
        return rect

    def contains(outer, inner):
        return (inner[0] >= outer[0] - tolerance and inner[1] >= outer[1] - tolerance
                and inner[0] + inner[2] <= outer[0] + outer[2] + tolerance
                and inner[1] + inner[3] <= outer[1] + outer[3] + tolerance)

    require(captured_scenes == expected, "batch", "Capture must contain both settings sizes in all three themes")
    measured = {}
    card_key = "settings.interfaceLanguage"
    option_keys = [f"{card_key}.control"]
    for scene in sorted(expected):
        values = metrics.get(scene, {})
        card = frame(values, card_key, scene)
        options = [frame(values, key, scene) for key in option_keys]
        if card is None or any(option is None for option in options):
            continue
        width, height = (620, 540) if scene.startswith("general-minimum-") else (700, 610)
        require(contains((0, 0, width, height), card), scene, "Language card must be visible without scrolling")
        for key, option in zip(option_keys, options):
            require(contains(card, option), scene, f"Language dropdown must remain inside the card: {key}")
        for left, right in zip(options, options[1:]):
            require(left[0] + left[2] <= right[0] + tolerance, scene, "Language options must keep their order without overlap")
            require(abs(left[1] - right[1]) <= tolerance and abs(left[3] - right[3]) <= tolerance,
                    scene, "Language options must align in one row")
        require(abs(options[0][3] - 30) <= tolerance, scene, "Dropdown height must be 30px")
        require(abs(options[0][2] - 176) <= tolerance, scene, "Settings dropdowns must retain the shared 176px control width")
        require(abs(card[0] + card[2] - options[0][0] - options[0][2] - 17) <= tolerance,
                scene, "Dropdown must align to the card's trailing content edge")
        measured[scene] = dict(zip([card_key, *option_keys], [card, *options]))

    for size in ("general", "general-minimum"):
        baseline = measured.get(f"{size}-light")
        if baseline is None:
            continue
        for theme in ("dark", "glass"):
            scene = f"{size}-{theme}"
            current = measured.get(scene)
            if current is None:
                continue
            card, baseline_card = current[card_key], baseline[card_key]
            # AppKit can reserve scrollbar width differently as independent
            # review windows mount. Compare intrinsic sizes and alignment inside
            # each card, not absolute x positions or the card's available width.
            require(abs(card[3] - baseline_card[3]) <= tolerance, scene,
                    "Changing theme must preserve language card height")
            for key in option_keys:
                rect, baseline_rect = current[key], baseline[key]
                require(abs(rect[2] - baseline_rect[2]) <= tolerance, scene,
                        f"Changing theme must preserve language option width: {key}")
                require(abs(rect[3] - baseline_rect[3]) <= tolerance, scene,
                        f"Changing theme must preserve language option height: {key}")
                right_offset = card[0] + card[2] - rect[0] - rect[2]
                baseline_offset = baseline_card[0] + baseline_card[2] - baseline_rect[0] - baseline_rect[2]
                require(abs(right_offset - baseline_offset) <= tolerance, scene,
                        f"Changing theme must preserve language option alignment inside its card: {key}")
    return checks, failures


def check_service_usage_layout(metrics, captured_scenes, chart_only=False, requested_scenes=None):
    """Check shipping service rows and secondary pages, including hover/gutters."""
    scenes = (
        "usage-card", "usage-card-hover-minimum", "usage-7", "usage-30-minimum", "usage-day-minimum",
        "usage-samples-minimum", "usage-empty-minimum", "usage-account-empty",
        "usage-account-deepseek-minimum", "usage-account-deepl-minimum",
    )
    if chart_only:
        scenes = ("usage-7", "usage-30-minimum", "usage-samples-minimum")
    if requested_scenes is not None:
        scenes = requested_scenes
    expected = {f"{scene}-{theme}" for scene in scenes for theme in ("light", "dark", "glass")}
    failures, checks = [], 0
    tolerance = 1

    def require(condition, scene, message):
        nonlocal checks
        checks += 1
        if not condition:
            failures.append({"scene": scene, "error": message})

    def frame(values, key, scene):
        value = values.get(key)
        valid = isinstance(value, dict) and all(
            isinstance(value.get(axis), (int, float)) and not isinstance(value.get(axis), bool)
            and math.isfinite(value[axis]) for axis in ("x", "y", "width", "height")
        )
        require(valid, scene, f"Missing or invalid layout metric: {key}")
        if not valid:
            return None
        rect = (value["x"], value["y"], value["width"], value["height"])
        require(rect[2] > 0 and rect[3] > 0, scene, f"Empty layout metric: {key}")
        return rect

    def contains(outer, inner, vertical=True):
        return (inner[0] >= outer[0] - tolerance
                and inner[0] + inner[2] <= outer[0] + outer[2] + tolerance
                and (not vertical or (inner[1] >= outer[1] - tolerance
                     and inner[1] + inner[3] <= outer[1] + outer[3] + tolerance)))

    require(captured_scenes == expected, "batch", "Capture must cover all requested service states and themes")
    for scene in sorted(expected):
        values = metrics.get(scene, {})
        width, height = (620, 540) if "minimum" in scene else (700, 610)
        window = (0, 0, width, height)
        if "manager" in scene:
            panel = frame(values, "usage.manager", scene)
            back = frame(values, "usage.manager.back", scene)
            viewport = frame(values, "usage.manager.scroll", scene)
            if panel and back and viewport:
                require(contains(window, panel) and contains(panel, back), scene, "Statistics management must be an inline settings page")
                require(abs(panel[0]) <= tolerance and abs(panel[2] - width) <= tolerance,
                        scene, "Statistics management must fill the settings page width")
                require(abs(viewport[0] + viewport[2] - width) <= tolerance,
                        scene, "Statistics management scrollbar must sit at the window edge")
            for provider in ("apple", "deepSeek", "openAI"):
                row = frame(values, f"usage.manager.row.{provider}", scene)
                toggle = frame(values, f"usage.manager.switch.{provider}", scene)
                if panel and row and toggle:
                    require(contains(panel, row) and contains(row, toggle), scene, "Independent switch must stay inside its service row")
                    require(abs(toggle[0] + toggle[2] - row[0] - row[2]) <= tolerance,
                            scene, "Statistics switches must align to the trailing edge")
            continue
        is_list = "card" in scene or "account" in scene
        if not is_list:
            panel = frame(values, "usage.panel", scene)
            back = frame(values, "usage.back", scene)
            if panel is None:
                continue
            require(contains(window, panel) and panel[1] >= 100, scene,
                    "Usage must remain below settings navigation inside the original window")
            require(abs(panel[0]) <= tolerance and abs(panel[2] - width) <= tolerance,
                    scene, "Usage must fill the settings page instead of a modal panel")
            if back:
                require(contains(panel, back), scene, "Usage must offer in-page back navigation")
            window = panel
        viewport = frame(values, "list.scroll" if is_list else "usage.scroll", scene)
        if viewport is None:
            continue
        require(contains(window, viewport), scene, "Scroll viewport must stay inside its settings window")
        require(abs(viewport[0] + viewport[2] - window[0] - window[2]) <= tolerance,
                scene, "Page scrollbar must sit at the outer trailing edge")
        if is_list:
            require("usage.panel" not in values, scene, "A service list must not embed an inline usage panel")
            provider = "deepL" if "deepl" in scene else "deepSeek"
            card = frame(values, f"list.{provider}", scene)
            selected_action = "current" if f"list.{provider}.current" in values else "use"
            names = ("icon", "name", "balance", "actions", selected_action, "edit", "copy", "check", "usage", "delete")
            controls = {name: frame(values, f"list.{provider}.{name}", scene) for name in names}
            if card is None or any(rect is None for rect in controls.values()):
                continue
            for name, rect in controls.items():
                require(contains(card, rect), scene, f"Service control must stay inside its row: {name}")
            for left, right in (("icon", "name"), ("name", "balance"), ("balance", "actions")):
                a, b = controls[left], controls[right]
                require(a[0] + a[2] <= b[0] + tolerance or a[1] + a[3] <= b[1] + tolerance
                        or b[1] + b[3] <= a[1] + tolerance,
                        scene, f"Responsive service fields must not overlap: {left}/{right}")
            for name in ("edit", "copy", "check", "usage", "delete"):
                rect = controls[name]
                require(abs(rect[2] - 28) <= tolerance and abs(rect[3] - 28) <= tolerance,
                        scene, f"Icon action must be a 28px square: {name}")
            for left, right in zip(("edit", "copy", "check", "usage"), ("copy", "check", "usage", "delete")):
                require(controls[left][0] + controls[left][2] <= controls[right][0] + tolerance,
                        scene, "Icon actions must not overlap")
            refresh = frame(values, f"list.{provider}.refresh", scene)
            if refresh:
                require(abs(refresh[2] - 22) <= tolerance and abs(refresh[3] - 24) <= tolerance,
                        scene, "Balance refresh must remain a compact target")
                require(contains(controls["balance"], refresh), scene, "Refresh must remain in the balance line")
            start = controls[selected_action]
            require(abs(start[1] + start[3] / 2 - controls["edit"][1] - controls["edit"][3] / 2) <= tolerance,
                    scene, "Start and secondary actions must share one line")
            apple = frame(values, "list.apple.balance", scene)
            if apple:
                require(apple[3] <= 16, scene, "Apple account and local translation labels must share one line")
            continue

        header = frame(values, "usage.header", scene)
        footer = frame(values, "usage.footer", scene)
        for rect in (header, footer):
            if rect is not None:
                require(contains(window, rect), scene, "Secondary page header/footer must remain visible")
        if header is not None and footer is not None:
            require(header[1] + header[3] <= viewport[1] + tolerance and
                    viewport[1] + viewport[3] <= footer[1] + tolerance,
                    scene, "Fixed page chrome must not overlap the scroll viewport")
        if "day" not in scene:
            require("usage.details" not in values, scene, "Requests must expand only after explicit selection")
        if "empty" in scene:
            empty = frame(values, "usage.empty", scene)
            if empty is not None:
                require(contains(viewport, empty), scene, "Empty state must be visible")
            continue
        summary = frame(values, "usage.summary", scene)
        for key in ("usage.period", "usage.purpose", "usage.metrics"):
            rect = frame(values, key, scene)
            if summary and rect:
                require(contains(summary, rect), scene, "Summary controls must stay within the page content")
        if "summary" in scene:
            require("usage.chart" not in values and "usage.requests" not in values,
                    scene, "Statistics opens with optional detail sections collapsed")
            continue
        chart = frame(values, "usage.chart", scene) if "usage.chart" in values else None
        table = frame(values, "usage.requests", scene) if "usage.requests" in values else None
        picker = frame(values, "usage.metric", scene) if "usage.metric" in values else None
        if chart is not None and table is not None:
            require(chart[1] + chart[3] <= table[1] + tolerance, scene,
                    "Individual requests must follow the curve without overlap")
            for rect in (chart, table):
                require(contains(viewport, rect, vertical=False), scene, "Usage content must stay within page width")
                require(rect[0] + rect[2] <= viewport[0] + viewport[2] - 36 + tolerance,
                        scene, "Usage content must retain its standard page inset")
        if chart is not None and picker is not None:
            require(contains(chart, picker), scene, "Metric menu must remain inside the trend section")
        if "day" in scene:
            details = frame(values, "usage.details", scene)
            inner = frame(values, "usage.detailsInner", scene)
            if details is not None and inner is not None:
                require(contains(viewport, details), scene, "Scrolled expanded request must be fully visible")
                require(contains(details, inner), scene, "Request details must stay inside the expansion")
                require(inner[1] - details[1] >= 12 - tolerance, scene, "Expansion needs top whitespace")
                require(details[1] + details[3] - inner[1] - inner[3] >= 12 - tolerance,
                        scene, "Expansion needs bottom whitespace")

    if not chart_only:
        for theme in ("light", "dark", "glass"):
            idle = metrics.get(f"usage-account-deepseek-minimum-{theme}", {}).get("list.deepSeek.balance")
            hover = metrics.get(f"usage-card-hover-minimum-{theme}", {}).get("list.deepSeek.balance")
            if idle and hover:
                require(all(abs(idle[k] - hover[k]) <= tolerance for k in ("x", "y", "width", "height")),
                        f"usage-card-hover-minimum-{theme}", "Showing actions must preserve the balance frame")
    return checks, failures


def check_service_editor_gutters(metrics, captured_scenes):
    expected = {f"{scene}-{theme}" for scene in ("edit", "edit-minimum") for theme in ("light", "dark", "glass")}
    failures, checks = [], 0
    if captured_scenes != expected:
        failures.append({"scene": "batch", "error": "Capture must cover editor sizes and themes"})
    for scene in sorted(expected):
        values = metrics.get(scene, {})
        viewport = values.get("editor.scroll")
        for key in ("identity.group", "connection.group", "field.name", "field.website", "field.endpoint", "field.key", "field.model"):
            rect = values.get(key)
            checks += 1
            if not viewport or not rect or rect["x"] + rect["width"] > viewport["x"] + viewport["width"] - 36 + 1:
                failures.append({"scene": scene, "error": f"Editor content must retain its standard page inset: {key}"})
    return checks, failures


root = Path(__file__).resolve().parents[2]
if subprocess.run(["pgrep", "-x", "TranslateX Visual Review"], capture_output=True).returncode == 0:
    raise SystemExit("Finish the active native review before starting another capture batch.")
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
if (output / "ready.txt").exists():
    raise SystemExit("Choose a new output directory to preserve the previous evidence.")
app = root / ".build/NativeVisualReview/TranslateX Visual Review.app"
subprocess.run(["open", "-n", str(app), "--args", "--translation-services-review",
                "--review-external-capture", "--review-output", str(output),
                *sys.argv[2:]], check=True)
seen = set()
failures = []
deadline = time.monotonic() + 300
while time.monotonic() < deadline:
    job_path = output / "capture-job.json"
    if job_path.exists():
        job = json.loads(job_path.read_text())
        scene = job["scene"]
        if scene not in seen:
            if scene.startswith("usage-") and job.get("sheetCount") != 0:
                failures.append({"scene": scene, "error": "Usage must open in the settings page, never as a sheet"})
            destination = Path(job["output"])
            if destination.parent != output or destination.suffix != ".png":
                raise SystemExit("Unexpected review capture destination")
            # Window-only screenshots omit the native glass backdrop. Capture the
            # exact exported review window rectangle over our constructed backdrop.
            rect = job["region"]
            if len(rect) != 4 or rect[2:] not in ([700, 610], [620, 540], [720, 430], [600, 340],
                    [980, 598], [760, 780], [660, 640], [540, 620], [460, 480], [660, 440], [660, 390],
                    [440, 320], [340, 300]):
                raise SystemExit("Unexpected review window rectangle")
            region = ",".join(str(round(value)) for value in rect)
            capture = subprocess.run(["/usr/sbin/screencapture", "-x", "-R", region,
                                      str(destination)], capture_output=True, text=True)
            if capture.returncode or not destination.exists():
                failures.append({"scene": scene, "error": capture.stderr.strip()})
            seen.add(scene)
            (output / "capture-done.txt").write_text(scene)
    if (output / "ready.txt").exists():
        break
    time.sleep(0.1)
else:
    raise SystemExit("Native review timed out; partial evidence preserved.")
layout_checks = 0
layout_failures = []
if "--review-settings-refinement" in sys.argv[2:]:
    metrics = json.loads((output / "metrics.json").read_text())
    language_scenes = {scene for scene in seen if scene.startswith("general") and "controls" not in scene}
    layout_checks, layout_failures = check_language_settings_layout(metrics, language_scenes)
    usage_scenes = {scene for scene in seen if scene.startswith("usage-")}
    count, errors = check_service_usage_layout(metrics, usage_scenes, requested_scenes=(
        "usage-card", "usage-card-hover-minimum", "usage-summary-minimum", "usage-manager-minimum", "usage-empty-minimum"))
    layout_checks += count
    layout_failures += errors
    for scene in sorted(s for s in seen if "general-controls" in s):
        values = metrics[scene]
        width, height = (620, 540) if "minimum" in scene else (700, 610)
        for key in ("settings.updates", "settings.updates.action", "settings.updates.version"):
            rect = values.get(key)
            layout_checks += 1
            if not rect or rect["x"] < 0 or rect["y"] < 0 or rect["x"] + rect["width"] > width or rect["y"] + rect["height"] > height:
                layout_failures.append({"scene": scene, "error": f"Update controls must stay visible after scrolling: {key}"})
if "--review-language-settings" in sys.argv[2:]:
    metrics_path = output / "metrics.json"
    if metrics_path.exists():
        layout_checks, layout_failures = check_language_settings_layout(json.loads(metrics_path.read_text()), seen)
    else:
        layout_failures.append({"scene": "batch", "error": "Native layout metrics were not produced"})
if "--review-service-usage" in sys.argv[2:] or "--review-service-usage-charts" in sys.argv[2:]:
    metrics_path = output / "metrics.json"
    if metrics_path.exists():
        layout_checks, layout_failures = check_service_usage_layout(
            json.loads(metrics_path.read_text()), seen, chart_only="--review-service-usage-charts" in sys.argv[2:])
    else:
        layout_failures.append({"scene": "batch", "error": "Native usage layout metrics were not produced"})
if "--review-service-editor" in sys.argv[2:]:
    layout_checks, layout_failures = check_service_editor_gutters(json.loads((output / "metrics.json").read_text()), seen)
(output / "capture-result.json").write_text(json.dumps({
    "scenes": len(seen), "failures": failures,
    "layoutChecks": layout_checks, "layoutFailures": layout_failures,
}, indent=2))
print(f"Captured {len(seen) - len(failures)}/{len(seen)} owned review windows")
if layout_checks:
    print(f"Passed {layout_checks - len(layout_failures)}/{layout_checks} native geometry checks")
if failures or layout_failures:
    print(json.dumps(failures + layout_failures, indent=2))
    raise SystemExit(1)
