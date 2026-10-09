#!/bin/bash
# Builds an isolated native UI review app. Never installs, launches, or publishes it.
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -x "TranslateX Visual Review" >/dev/null; then
    echo "请先退出视觉核查应用，再重新构建。" >&2
    exit 1
fi
python3 - <<'PY'
from pathlib import Path
import plistlib
import subprocess
import shutil
root = Path('.build/NativeVisualReview/TranslateX Visual Review.app/Contents')
(root / 'MacOS').mkdir(parents=True, exist_ok=True)
sparkle = Path('.build/ReleaseTools/Sparkle-2.10.0/Sparkle.framework')
if not sparkle.is_dir():
    raise SystemExit('Run python3 Tools/Release/setup_sparkle.py first.')
# The fixture imports the actual UI and replaces Apple/remote translation execution.
# Synthetic review states must never download languages or send network requests.
excluded = {'TranslateXApp.swift', 'AppDelegate.swift', 'AppleTranslationHost.swift', 'RemoteTranslationProvider.swift', 'DedicatedTranslationProvider.swift', 'ClaudeTranslationProvider.swift', 'QwenMTTranslationProvider.swift', 'GoogleCloudTranslationProvider.swift', 'TencentTranslationProvider.swift', 'TranslationServiceModelCatalog.swift', 'TranslationAccountUsageLoader.swift'}
sources = sorted(str(p) for p in Path('TranslateX').rglob('*.swift') if p.name not in excluded)
arch = subprocess.check_output(['uname', '-m'], text=True).strip()
keychain_bridge = Path('.build/NativeVisualReview/KeychainInteraction.o')
subprocess.run(['xcrun', 'clang', '-c', '-Werror', '-target', f'{arch}-apple-macos15.0',
                'TranslateX/System/Security/KeychainInteraction.c', '-o', str(keychain_bridge)], check=True)
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                '-strict-concurrency=complete', '-warnings-as-errors', '-D', 'TRANSLATEX_DIRECT', '-D', 'TRANSLATEX_VISUAL_QA',
                '-F', str(sparkle.parent), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
                '-target', f'{arch}-apple-macos15.0', '-import-objc-header', 'TranslateX/System/Security/KeychainInteraction.h', str(keychain_bridge), *sources, 'Tools/QA/VisualCatalog.swift', 'Tools/QA/TranslationServiceVisualReview.swift', 'Tools/QA/ScreenshotReviewFixture.swift',
                '-o', str(root / 'MacOS/TranslateX Visual Review')], check=True)
(root / 'Frameworks').mkdir(exist_ok=True)
if (root / 'Frameworks/Sparkle.framework').exists():
    shutil.rmtree(root / 'Frameworks/Sparkle.framework')
shutil.copytree(sparkle, root / 'Frameworks/Sparkle.framework', symlinks=True)
(root / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'TranslateX Visual Review',
    'CFBundleIdentifier': 'com.theoyuuu.TranslateX.VisualReview',
    'CFBundleName': 'TranslateX Visual Review', 'CFBundlePackageType': 'APPL',
    'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'zh-Hans'],
}))
for lang in ['en', 'zh-Hans']:
    dest = root / 'Resources' / f'{lang}.lproj'
    dest.mkdir(parents=True, exist_ok=True)
    (dest / 'Localizable.strings').write_bytes(Path(f'TranslateX/Resources/{lang}.lproj/Localizable.strings').read_bytes())
shutil.copy2('TranslateX/Resources/PublishedReleaseNotes.json', root / 'Resources/PublishedReleaseNotes.json')
subprocess.run(['xcrun', 'actool', '--compile', str(root / 'Resources'), '--platform', 'macosx',
                '--minimum-deployment-target', '15.0', '--target-device', 'mac',
                'TranslateX/Resources/Assets.xcassets'], check=True)
print((root.parent).resolve())
PY
