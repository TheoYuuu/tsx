#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
qa_output="$PWD/.build/QA/LanguageAudit"
mkdir -p "$qa_output"
qa_sdk="$(xcrun --sdk macosx --show-sdk-path)"
qa_arch="$(uname -m)"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -warnings-as-errors -target "$qa_arch-apple-macos15.0" -sdk "$qa_sdk" -O \
    Tools/QA/LanguageAudit.swift LumaxTranslate/Translation/LanguageCatalog.swift \
    LumaxTranslate/Translation/Services/TranslationServiceConfiguration.swift \
    LumaxTranslate/Translation/Services/DedicatedTranslationLanguages.swift \
    LumaxTranslate/Translation/Services/GoogleTranslationLanguages.swift \
    LumaxTranslate/Translation/Services/TencentTranslationLanguages.swift \
    LumaxTranslate/Translation/Services/QwenMTTranslationLanguages.swift \
    LumaxTranslate/Support/L10n.swift \
    -o "$qa_output/audit"
"$qa_output/audit" > "$qa_output/latest.json"
printf 'Language resource report: %s/latest.json\n' "$qa_output"
