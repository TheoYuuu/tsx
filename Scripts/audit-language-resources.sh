#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
qa_output="$PWD/.build/QA/LanguageAudit"
mkdir -p "$qa_output"
qa_sdk="$(xcrun --sdk macosx --show-sdk-path)"
qa_arch="$(uname -m)"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -warnings-as-errors -target "$qa_arch-apple-macos15.0" -sdk "$qa_sdk" -O \
    Tools/QA/LanguageAudit.swift TranslateX/Translation/LanguageCatalog.swift \
    TranslateX/Translation/Services/TranslationServiceConfiguration.swift \
    TranslateX/Translation/Services/DedicatedTranslationLanguages.swift \
    TranslateX/Translation/Services/GoogleTranslationLanguages.swift \
    TranslateX/Translation/Services/TencentTranslationLanguages.swift \
    TranslateX/Translation/Services/QwenMTTranslationLanguages.swift \
    TranslateX/Support/L10n.swift \
    -o "$qa_output/audit"
"$qa_output/audit" > "$qa_output/latest.json"
printf 'Language resource report: %s/latest.json\n' "$qa_output"
