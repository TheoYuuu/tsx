#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# != 2 || "$1" != --identity || ! "$2" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo 'Usage: Scripts/prepare-local-trial.sh --identity <existing signing certificate SHA-1>' >&2
    echo 'Creates a locally signed Release app after the full verification suite. Does not launch or publish it.' >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'A local trial build requires macOS and full Xcode.' >&2
    exit 1
fi

# Keep the shared build output and app/receipt replacement under one lock.
# FD 9 remains open through EXIT rollback. Never unlink the lock file: every
# preparation must open the same inode, including after an interrupted run.
mkdir -p .build
exec 9> '.build/local-trial.lock'
if /usr/bin/lockf -s -t 0 9; then
    :
else
    task_lock_status=$?
    if [[ "$task_lock_status" == 75 ]]; then
        echo 'Another local trial preparation is already running. Wait for it to finish before retrying.' >&2
    else
        echo "Could not acquire the local trial lock (lockf exit ${task_lock_status})." >&2
    fi
    exit "$task_lock_status"
fi

task_identity="$2"
task_output='.build/Run/TSX.app'
task_receipt='.build/Run/BuildInfo.txt'

require_app_closed() {
    if pgrep -x 'TSX' >/dev/null || pgrep -x 'Lumax Translate' >/dev/null; then
        echo 'Quit every TSX or legacy Lumax Translate instance before replacing the local trial app.' >&2
        exit 1
    fi
}

require_app_closed
if ! security find-identity -v -p codesigning | /usr/bin/grep -Fqi "$task_identity"; then
    echo 'The requested signing identity is not available. No certificate or account was changed.' >&2
    exit 1
fi

# Include uncommitted tracked content and untracked source files in the identity.
# A build concurrent with an edit/commit must not claim the newer source state.
source_fingerprint() {
    {
        git rev-parse HEAD
        git status --porcelain=v1 --untracked-files=all
        git diff --binary --no-ext-diff --no-textconv HEAD -- .
        while IFS= read -r -d '' task_file; do
            shasum -a 256 -- "$task_file"
        done < <(git ls-files --others --exclude-standard -z)
    } | shasum -a 256 | awk '{print $1}'
}
task_source_fingerprint="$(source_fingerprint)"
task_commit="$(git rev-parse HEAD)"
task_dirty=no
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then task_dirty=yes; fi
require_unchanged_source() {
    if [[ "$(source_fingerprint)" != "$task_source_fingerprint" ]]; then
        echo 'Source changed during preparation. The previous trial app was preserved; run again after edits finish.' >&2
        exit 1
    fi
}
require_unchanged_source

# Build and verify Debug and Release, retaining the direct-distribution
# entitlement and Hardened Runtime checks. The XCTest host is never packaged.
Scripts/verify.sh
require_unchanged_source

task_staging="$(mktemp -d .build/local-trial.XXXXXX)"
task_install_complete=no
cleanup() {
    local task_status=$?
    # If replacement is interrupted, the previous app must survive cleanup.
    if [[ "$task_install_complete" != yes && -e "$task_staging/previous.app" ]]; then
        if [[ -e "$task_output" ]] && ! mv "$task_output" "$task_staging/incomplete.app"; then
            echo "Could not roll back. Previous app retained at: $task_staging/previous.app" >&2
            return 1
        fi
        if ! mv "$task_staging/previous.app" "$task_output"; then
            echo "Could not restore the previous app. Backup retained at: $task_staging/previous.app" >&2
            return 1
        fi
        if [[ -e "$task_staging/previous-BuildInfo.txt" ]]; then
            cp "$task_staging/previous-BuildInfo.txt" "$task_receipt" || return 1
        else
            rm -f "$task_receipt"
        fi
    fi
    rm -rf "$task_staging"
    return "$task_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
task_app="$task_staging/TSX.app"
ditto '.build/DerivedData/Build/Products/Release/TSX.app' "$task_app"
codesign --force --sign "$task_identity" --options runtime --timestamp=none \
    --identifier com.theoyuuu.LumaxTranslate.CodexRuntime \
    "$task_app/Contents/Helpers/translatex-codex-runtime"
codesign --force --sign "$task_identity" --options runtime --timestamp=none \
    --entitlements Config/TranslateX.entitlements "$task_app"
codesign --verify --deep --strict "$task_app"
python3 Tools/CodexRuntime/verify_bundle.py "$task_app" --configuration Release

task_signature="$(codesign -dv --verbose=4 "$task_app" 2>&1)"
if ! /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' <<< "$task_signature"; then
    echo 'The staged local app lost Hardened Runtime.' >&2
    exit 1
fi
codesign -d --entitlements :- "$task_app" 2>/dev/null > "$task_staging/entitlements.plist"
if [[ -s "$task_staging/entitlements.plist" ]]; then
    plutil -lint "$task_staging/entitlements.plist"
    for task_key in com.apple.security.app-sandbox com.apple.security.get-task-allow \
        com.apple.security.cs.disable-library-validation com.apple.security.cs.allow-jit \
        com.apple.security.cs.allow-unsigned-executable-memory \
        com.apple.security.cs.allow-dyld-environment-variables \
        com.apple.security.cs.disable-executable-page-protection; do
        if /usr/libexec/PlistBuddy -c "Print :${task_key}" "$task_staging/entitlements.plist" >/dev/null 2>&1; then
            echo "Unexpected local Release entitlement: $task_key" >&2
            exit 1
        fi
    done
fi

task_hash="$(shasum -a 256 "$task_app/Contents/MacOS/TSX" | awk '{print $1}')"
task_architectures="$(lipo -archs "$task_app/Contents/MacOS/TSX")"
cat > "$task_staging/BuildInfo.txt" <<EOF
TSX local trial
Source commit: $task_commit
Source state SHA-256: $task_source_fingerprint
Uncommitted source changes: $task_dirty
Prepared UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Configuration: Release
Architectures: $task_architectures
Runtime validation host: $(uname -m)
Channel: Direct, non-sandboxed, Hardened Runtime
Signing: Explicitly selected local certificate; not notarized
Executable SHA-256: $task_hash
Validation: Scripts/verify.sh and staged signature/entitlement checks passed
System interaction coverage: See Docs/Validation.md; a successful build is not full product acceptance
EOF

# Do not overwrite an app that was started during the build. Keep the previous
# artifact intact until the new one has passed all checks, then replace its path.
require_unchanged_source
require_app_closed
mkdir -p .build/Run
if [[ -e "$task_receipt" ]]; then cp "$task_receipt" "$task_staging/previous-BuildInfo.txt"; fi
if [[ -e "$task_output" ]]; then mv "$task_output" "$task_staging/previous.app"; fi
mv "$task_app" "$task_output"
if ! mv "$task_staging/BuildInfo.txt" "$task_receipt"; then
    # A first installation has no previous app to restore. Never leave a stale
    # receipt beside its new binary; existing installations roll back in cleanup.
    rm -f "$task_receipt"
    exit 1
fi
task_install_complete=yes
printf 'Local trial app: %s/%s\nBuild receipt: %s/%s\n' "$PWD" "$task_output" "$PWD" "$task_receipt"
