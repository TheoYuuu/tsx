<p align="center">
  <img src="assets/app-icon.png" width="112" height="112" alt="TSX app icon">
</p>

<h1 align="center">TSX · Translate X</h1>

<p align="center">Translation, native to Mac. Select text, find clarity, keep working.</p>

<p align="center">
  <a href="README.md">简体中文</a> · English
</p>

**TSX 1.0.0 · A free, open-source translation app for Mac.** This repository brings together application source, documentation, feedback, and official installers.

[Releases](https://github.com/TheoYuuu/tsx/releases) · [Usage guide](Docs/USAGE.md#english) · [Privacy and data](Docs/PRIVACY.md#english) · [Report an issue](https://github.com/TheoYuuu/tsx/issues/new/choose)

## Translation that fits your workflow

- **Selected text**: translate a selection in another app with a shortcut and read the result in a floating window.
- **Screenshot translation**: select a screen region, recognize text on your Mac, and read the translated text or compare it at its original position.
- **Two-way editing**: edit either side, enable automatic translation when needed, switch languages, copy, and undo.
- **Apple local translation by default**: translate supported languages on your Mac once the necessary language resources are ready.
- **Your choice of service**: configure a translation API, compatible endpoint, or local model service.
- **At home on macOS**: menu bar access, customizable shortcuts, Chinese and English interfaces, and light, dark, and glass appearances.

See release notes for changes and known issues. Text selection depends on the source app exposing readable selected text.

## Requirements and services

- Requires **macOS 15 or later**. The universal installer includes Apple silicon and Intel architectures.
- Apple translation languages depend on system availability. Some languages require an initial online download.
- External services are configured by you and may require a separate API key, account, usage allowance, or payment. They receive the text submitted for translation.
- Whether a local model service works entirely offline depends on its actual configuration and behavior.

## Downloads and updates

Download **TSX-1.1.0-macOS-universal.dmg** from the [latest release](https://github.com/TheoYuuu/tsx/releases/latest), open it, and drag TSX into Applications. Official installers are signed with Developer ID and notarized by Apple.

GitHub's automatic **Source code (zip / tar.gz)** archives contain the project source at that version. They are **not installable TSX applications**; download the installer attached to the release.

Choose Check for Updates in the app menu or Settings → About. The app checks at launch without downloading or installing by default. Enabling Automatic updates allows downloading, installation, and restart. Copy any source text and translations you want to keep before quitting to update. You can also choose **Watch → Custom → Releases** on GitHub.

[Product website](https://lumaxspace.com/products/tsx/) · [Release workflow](Docs/RELEASING.md)

## Feedback and project status

Use [Issues](https://github.com/TheoYuuu/tsx/issues/new/choose) for bug reports and feature suggestions in Chinese or English. Search existing reports first and use examples without private information.

Official TSX releases will remain free of charge, with no paid features or subscription. Third-party services you configure may charge separately. The project is licensed under the [MIT License](LICENSE); third-party components retain their own licenses and notices.

## Development

The product name is **TSX**. Its Xcode project, scheme, Swift module, and source directory use `TranslateX`; tests use `TranslateXTests`. Stable application identities and legacy storage identifiers are documented in the [distribution notes](Docs/Distribution.md#应用身份与存储兼容).

TSX uses Swift 6, AppKit, and SwiftUI, with a Rust component for optional account-based services. Read the [build notes](Docs/BUILDING.md#english), [development conventions](AGENTS.md), [public repository rules](Docs/PUBLIC_REPOSITORY.md), and [third-party notices](THIRD_PARTY_NOTICES.md). The deployment target is macOS 15; Intel and minimum-OS hardware coverage remains limited. See the [validation record](Docs/Validation.md).

## Source and contributions

This repository contains buildable MIT-licensed source and retains subsequent public change history. The initial source snapshot matches the application code and build inputs of the existing release; repository preparation did not rebuild or replace its installer.

Issues and pull requests are welcome. Use constructed test data and exclude real accounts, private screenshots, local paths, and credentials. Review the [public repository policy](Docs/PUBLIC_REPOSITORY.md) before contributing.
