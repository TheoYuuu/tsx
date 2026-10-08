#!/bin/bash
# Xcode embeds an already audited artifact. Compilation/downloads stay explicit.
set -euo pipefail
cd "${SRCROOT:?}"

task_configuration="${CONFIGURATION:?}"
case "$task_configuration" in Debug|Release) ;; *) exit 2 ;; esac
task_package="$SRCROOT/.build/CodexRuntime/package/$task_configuration"
if [[ ! -f "$task_package/package-manifest.json" ]]; then
    echo 'Codex runtime is missing. Run: python3 Tools/CodexRuntime/package.py --configuration All' >&2
    exit 1
fi
python3 Tools/CodexRuntime/package.py --configuration "$task_configuration" --verify-only

task_app="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}"
mkdir -p "$task_app/Helpers" "$task_app/Resources"
install -m 755 "$task_package/translatex-codex-runtime" "$task_app/Helpers/translatex-codex-runtime"
install -m 644 "$task_package/THIRD-PARTY-NOTICES.txt" "$task_app/Resources/CodexThirdPartyNotices.txt"
install -m 644 "$SRCROOT/LICENSE" "$task_app/Resources/TSX-LICENSE.txt"
install -m 644 "$SRCROOT/THIRD_PARTY_NOTICES.md" "$task_app/Resources/TSX-ThirdPartyNotices.md"
install -m 644 "$SRCROOT/Config/Licenses/Sparkle-LICENSE.txt" "$task_app/Resources/Sparkle-LICENSE.txt"
task_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ -z "$task_identity" ]]; then task_identity=-; fi
task_timestamp=--timestamp=none
# Direct Developer ID archives need a secure timestamp too. Development archives
# are re-signed by Xcode when exporting for Direct Distribution.
if [[ "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" == "Developer ID Application:"* ]]; then
    task_timestamp=--timestamp
fi
/usr/bin/codesign --force --sign "$task_identity" \
    --identifier com.theoyuuu.LumaxTranslate.CodexRuntime \
    --options runtime "$task_timestamp" "$task_app/Helpers/translatex-codex-runtime"
/usr/bin/codesign --verify --strict --all-architectures "$task_app/Helpers/translatex-codex-runtime"
