#!/usr/bin/env python3
"""Compare two native captures of the automatic translation capsule.

Use --review-toolbar-motion with CaptureTranslationServiceReview.py first.
Pixels outside the owned capsule are ignored; no desktop or API data is read.
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageChops

output = Path(sys.argv[1])
metrics = json.loads((output / "metrics.json").read_text())
results = []
for key, frames in metrics.items():
    scene, theme = key.rsplit('-', 1)
    if 'motion' not in scene:
        continue
    prefix = 'main' if scene.startswith('main') else 'quick'
    first = Image.open(output / f'{key}.png').convert('RGB')
    later = Image.open(output / f'{key}-later.png').convert('RGB')
    assert first.size == later.size, f'{key}: window changed size'
    scale = first.width / (frames[f'{prefix}.commandBar']['width'] + 24)
    frame = frames[f'{prefix}.automatic']
    # Inset the capsule's antialiased edge. Changes must come from its contents.
    bounds = tuple(round(value * scale) for value in (
        frame['x'] + 2, frame['y'] + 2,
        frame['x'] + frame['width'] - 2, frame['y'] + frame['height'] - 2))
    difference = ImageChops.difference(first.crop(bounds), later.crop(bounds))
    changed = sum(max(pixel) >= 8 for pixel in difference.getdata())
    expected_motion = 'reduced' not in scene and 'off' not in scene
    assert changed >= 30 if expected_motion else changed == 0, f'{key}: changed pixels {changed}, expected motion {expected_motion}'
    results.append({'scene': key, 'changed_pixels': changed, 'expected_motion': expected_motion})
assert len(results) == 18, f'Expected both windows, three themes and three motion states; got {len(results)}'
(output / 'motion-result.json').write_text(json.dumps(results, indent=2))
print(f'Passed {len(results)} native temporal comparisons: moving when enabled, static when off or reduced motion.')
