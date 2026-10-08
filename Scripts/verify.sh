#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Validation requires macOS and full Xcode.' >&2
    exit 1
fi

task_sdk="$(xcrun --sdk macosx --show-sdk-path)"
task_arch="$(uname -m)"
task_project_check='.build/QA/validate-project'

mkdir -p .build/QA
# Account operations never run during compilation. These artifacts are built
# explicitly with the pinned private toolchain when missing or stale.
python3 Tools/CodexRuntime/package.py --configuration All --verify-only
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -warnings-as-errors -sdk "$task_sdk" -target "${task_arch}-apple-macos15.0" \
    Tools/QA/ValidateProject.swift -o "$task_project_check"
"$task_project_check" "$PWD"

plutil -lint Config/TranslateX.entitlements
plutil -lint Config/Info.plist
xcrun swiftc -typecheck -swift-version 6 -strict-concurrency=complete \
    -warnings-as-errors -sdk "$task_sdk" -target "${task_arch}-apple-macos15.0" \
    Tools/Probes/APICompileProbe.swift

# XCTest loads its test bundle into a host process. Ad-hoc signatures have no
# team identity, so keep this test-only host separate from the hardened apps.
# Use a distinct bundle identity too: AppKit activation must target this host,
# not an already-running user trial app with the deliverable's bundle ID.
# No relaxed signing option is used for either application build below.
xcodebuild -project TranslateX.xcodeproj -scheme TranslateX \
    -configuration Debug -destination "platform=macOS,arch=${task_arch}" \
    -derivedDataPath .build/TestDerivedData -parallel-testing-enabled NO \
    TRANSLATEX_APP_BUNDLE_IDENTIFIER=com.lumax.tsx.TestHost \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES \
    ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS= \
    -quiet test

task_test_host='.build/TestDerivedData/Build/Products/Debug/TSX.app'
task_test_identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_test_host/Contents/Info.plist")"
if [[ "$task_test_identity" != com.lumax.tsx.TestHost ]]; then
    echo 'XCTest must use its isolated application identity.' >&2
    exit 1
fi

for task_configuration in Debug Release; do
    xcodebuild -project TranslateX.xcodeproj -scheme TranslateX \
        -configuration "$task_configuration" -destination "platform=macOS,arch=${task_arch}" \
        -derivedDataPath .build/DerivedData \
        CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES \
        -quiet build
done

# These expectations are specific to both direct-distribution app products;
# the isolated XCTest host above is never treated as a deliverable application.
for task_configuration in Debug Release; do
    task_app=".build/DerivedData/Build/Products/${task_configuration}/TSX.app"
    task_entitlements=".build/${task_configuration}-entitlements.plist"
    "$task_project_check" "$PWD" "$task_app"
    codesign --verify --deep --strict "$task_app"
    python3 Tools/CodexRuntime/verify_bundle.py "$task_app" --configuration "$task_configuration"
    cmp LICENSE "$task_app/Contents/Resources/TSX-LICENSE.txt"
    cmp THIRD_PARTY_NOTICES.md "$task_app/Contents/Resources/TSX-ThirdPartyNotices.md"
    cmp Config/Licenses/Sparkle-LICENSE.txt "$task_app/Contents/Resources/Sparkle-LICENSE.txt"
    codesign -d --entitlements :- "$task_app" 2>/dev/null > "$task_entitlements"

    # An empty entitlement payload is valid. A nonempty payload must parse,
    # and must not contain App Sandbox or security-relaxation entitlements.
    if [[ -s "$task_entitlements" ]]; then
        plutil -lint "$task_entitlements"
        for task_forbidden_entitlement in \
            com.apple.security.app-sandbox \
            com.apple.security.cs.disable-library-validation \
            com.apple.security.cs.allow-dyld-environment-variables \
            com.apple.security.cs.allow-unsigned-executable-memory \
            com.apple.security.cs.allow-jit \
            com.apple.security.cs.disable-executable-page-protection; do
            if /usr/libexec/PlistBuddy -c "Print :${task_forbidden_entitlement}" \
                "$task_entitlements" >/dev/null 2>&1; then
                echo "Unexpected entitlement in ${task_configuration}: ${task_forbidden_entitlement}" >&2
                exit 1
            fi
        done
        if [[ "$task_configuration" == Release ]] && \
            /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' \
                "$task_entitlements" >/dev/null 2>&1; then
            echo 'Release must not include the debugger entitlement.' >&2
            exit 1
        fi
    fi

    task_signature="$(codesign -dv --verbose=4 "$task_app" 2>&1)"
    if ! /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' <<< "$task_signature"; then
        echo "Hardened Runtime is missing from ${task_configuration}." >&2
        exit 1
    fi
    task_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$task_app/Contents/Info.plist")"
    if [[ "$task_bundle_id" != com.lumax.tsx ]]; then
        echo "Unexpected application identity in ${task_configuration}: ${task_bundle_id}" >&2
        exit 1
    fi

    for task_name_key in CFBundleName CFBundleDisplayName CFBundleExecutable; do
        task_name="$(/usr/libexec/PlistBuddy -c "Print :${task_name_key}" "$task_app/Contents/Info.plist")"
        if [[ "$task_name" != TSX ]]; then
            echo "Unexpected product name in ${task_configuration}: ${task_name_key}=${task_name}" >&2
            exit 1
        fi
    done

    task_icon="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$task_app/Contents/Info.plist")"
    if [[ "$task_icon" != AppIcon || ! -s "$task_app/Contents/Resources/AppIcon.icns" ]]; then
        echo "Compiled application icon is missing from ${task_configuration}." >&2
        exit 1
    fi

    task_capture_usage="$(/usr/libexec/PlistBuddy -c 'Print :NSScreenCaptureUsageDescription' "$task_app/Contents/Info.plist")"
    if [[ -z "$task_capture_usage" ]]; then
        echo "Screen capture usage explanation is missing from ${task_configuration}." >&2
        exit 1
    fi
    for task_language in en zh-Hans; do
        task_localized_info="$task_app/Contents/Resources/${task_language}.lproj/InfoPlist.strings"
        plutil -lint "$task_localized_info"
        task_localized_usage="$(/usr/libexec/PlistBuddy -c 'Print :NSScreenCaptureUsageDescription' "$task_localized_info")"
        if [[ -z "$task_localized_usage" ]]; then
            echo "Screen capture usage explanation is not localized for ${task_language}." >&2
            exit 1
        fi
    done
done

echo 'Validation passed: source lists, bilingual resources, API typecheck, Debug/Release builds, unit tests, app/helper signatures and packaging, application icons, direct-channel entitlements and Hardened Runtime.'
