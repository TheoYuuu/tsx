#!/usr/bin/env python3
"""Check production toolbar/editor geometry against the approved TSX design.

Native coordinates use logical points. This does not claim pixel similarity.
"""
import json
import sys
from pathlib import Path

metrics = json.loads(Path(sys.argv[1]).read_text())
checks = 0


def require(condition, description):
    global checks
    assert condition, description
    checks += 1


def equal(actual, expected, description):
    require(abs(actual - expected) <= 0.5, f"{description}: {actual} != {expected}")


def center(frame, axis):
    return frame[axis] + frame['width' if axis == 'x' else 'height'] / 2


def overlaps(a, b):
    return not (a['x'] + a['width'] <= b['x'] + .5 or b['x'] + b['width'] <= a['x'] + .5 or
                a['y'] + a['height'] <= b['y'] + .5 or b['y'] + b['height'] <= a['y'] + .5)


for key, current in metrics.items():
    scene, theme = key.rsplit('-', 1)
    if scene.startswith(('list', 'usage-card')):
        rows = [(name, f) for name, f in current.items() if name in ('list.apple', 'list.deepSeek', 'list.openAI', 'list.claude')]
        expected_count = 1 if scene == 'list-empty' else 2 if scene in ('list-untested', 'list-selected') else 3
        require(len(rows) >= expected_count, f'{key} real service rows present')
        for name, row in rows:
            # Service cards now have identity and action rows, and can also
            # contain historical test feedback. Check control containment and
            # usable actions instead of assuming a fixed one-line row height.
            require(row['width'] > 0 and row['height'] > 0, f'{key} {name} nonempty card')
            for suffix in ('icon', 'name', 'usage'):
                require(f'{name}.{suffix}' in current, f'{key} {name} {suffix} present')
            for control_name, control in current.items():
                if not control_name.startswith(name + '.'):
                    continue
                require(control['x'] >= row['x'] - .5 and control['y'] >= row['y'] - .5
                        and control['x'] + control['width'] <= row['x'] + row['width'] + .5
                        and control['y'] + control['height'] <= row['y'] + row['height'] + .5,
                        f'{key} {control_name} contained in card')
                if control_name.rsplit('.', 1)[-1] in ('use', 'usage', 'check', 'more'):
                    require(control['width'] >= 24 and control['height'] >= 24,
                            f'{key} {control_name} usable action size')
        ordered = sorted((row for _, row in rows), key=lambda row: row['y'])
        for upper, lower in zip(ordered, ordered[1:]):
            equal(upper['x'], lower['x'], f'{key} service cards align')
            equal(upper['width'], lower['width'], f'{key} service cards share width')
            equal(lower['y'] - upper['y'] - upper['height'], 10, f'{key} service card spacing')
        continue
    if not scene.startswith(('main', 'quick')):
        continue
    prefix = 'main' if scene.startswith('main') else 'quick'
    compact, stacked = prefix == 'quick', 'stacked' in scene
    bar = current[f'{prefix}.commandBar']
    width = bar['width'] + 24
    require(bar['height'] in (42, 72), f'{key} compact toolbar height')
    equal(bar['x'], 12, f'{key} toolbar inset')
    equal(bar['y'], 38 if compact else 44, f'{key} toolbar follows compact titlebar')
    source, target = (current[f'{prefix}.{name}Column'] for name in ('source', 'result'))
    for axis in ('width', 'height', 'x' if stacked else 'y'):
        equal(source[axis], target[axis], f'{key} equal panes {axis}')
    axis, extent = ('y', 'height') if stacked else ('x', 'width')
    equal(target[axis] - source[axis] - source[extent], 1, f'{key} divider')
    equal(source['y'] - bar['y'] - bar['height'], 10, f'{key} toolbar/editor gap')
    height = target['y'] + target['height'] + 12
    for side, column in (('source', source), ('target', target)):
        require(f'{prefix}.{side}Feedback' not in current, f'{key} no single-sided feedback')
        editor = current[f'{prefix}.{side}Editor']
        require(editor['height'] >= 45, f'{key} usable {side} editor')
        require(editor['x'] >= column['x'] and editor['y'] >= column['y'], f'{key} editor origin')
        require(editor['x'] + editor['width'] <= column['x'] + column['width'] + .5, f'{key} editor right')
        require(editor['y'] + editor['height'] <= column['y'] + column['height'] + .5, f'{key} editor bottom')
    feedback = current[f'{prefix}.feedback']
    equal(center(feedback, 'x'), width / 2, f'{key} status centers on entire window')
    swap = current[f'{prefix}.swap']
    equal(center(swap, 'x'), width / 2, f'{key} swap on center axis')
    if stacked:
        equal(center(swap, 'y'), target['y'] - .5, f'{key} swap centers on horizontal divider')
    else:
        equal(center(swap, 'y'), center(source, 'y'), f'{key} swap centers on vertical divider')
    actions = [current[f'{prefix}.{name}'] for name in ('service', 'automatic', 'primary', 'captureSelection', 'captureScreenshot', 'undo', 'clear', 'settings')]
    for i, frame in enumerate(actions):
        equal(frame['height'], 28, f'{key} action height')
        require(frame['width'] >= 24, f'{key} usable hit width')
        require(not overlaps(frame, feedback), f'{key} action/status overlap')
        require(frame['x'] >= bar['x'] and frame['y'] >= bar['y'] and frame['x'] + frame['width'] <= bar['x'] + bar['width'] + .5 and frame['y'] + frame['height'] <= bar['y'] + bar['height'] + .5, f'{key} action within toolbar')
        for other in actions[i+1:]:
            require(not overlaps(frame, other), f'{key} actions do not overlap')
    automatic, primary = current[f'{prefix}.automatic'], current[f'{prefix}.primary']
    equal(center(automatic, 'y'), center(primary, 'y'), f'{key} translation actions on same row')
    equal(primary['x'] - automatic['x'] - automatic['width'], 6, f'{key} translation group gap')
    require(primary['width'] >= 72, f'{key} slightly wider translate button')
    for name in ('captureSelection', 'captureScreenshot', 'undo', 'settings'):
        frame = current[f'{prefix}.{name}']
        equal(frame['width'], frame['height'], f'{key} square {name} button')
    for name, frame in current.items():
        require(frame['x'] >= -.5 and frame['y'] >= -.5 and frame['x'] + frame['width'] <= width + .5 and frame['y'] + frame['height'] <= height + .5, f'{key} {name} containment')
        for axis in ('x', 'y', 'width', 'height'):
            equal(frame[axis], metrics[f'{scene}-light'][name][axis], f'{key} stable {name} {axis}')
    if prefix == 'main':
        require('main.brand' not in current, f'{key} no header brand')
        equal(current['main.titlebar']['height'], 44, f'{key} titlebar')
        equal(center(current['main.trafficLights'], 'y'), 22, f'{key} traffic light center')

print(f'Passed {checks} native layout checks across {len(metrics)} scenes (0.5 pt tolerance).')
