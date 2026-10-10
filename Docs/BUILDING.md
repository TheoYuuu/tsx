# 源码构建说明

[返回首页](../README.md) · [English](#english)

TSX 的应用、测试、账号组件与构建工具源码均在本仓库。项目使用 Swift 6、AppKit、SwiftUI、Apple Translation、Vision 与 ScreenCaptureKit；可选账号服务包含 Rust 运行组件及固定版本的第三方依赖，并非无依赖项目。

## 环境与首次准备

- macOS 和完整 Xcode，需要支持工程使用的 Swift 6 与 macOS SDK API；最低部署目标为 macOS 15。
- Python 3，以及 Rust/Cargo 1.95.0。账号组件使用仓库 `.build` 下隔离的工具链和依赖缓存，不修改系统 Rust。
- 修改 `project.yml` 时使用 XcodeGen 2.46 或更新版本重新生成工程；已提交生成的 Xcode 工程。
- 首次构建要下载并校验固定的官方源码、Rust 组件及锁定依赖，可能使用数 GiB 磁盘空间。具体来源和摘要由 [package.py](../Tools/CodexRuntime/package.py)、[构建工具](../Tools/CodexRuntime/build.py)及[来源检查](../Tools/QA/CodexTranslationProbe/verify.py)管理。

Apple Silicon 构建机可从仓库根目录运行以下首次准备命令。它只在忽略目录 `.build` 下载和校验固定工具链、上游源码与锁定依赖，随后进行离线构建，不安装全局 Rust：

```sh
python3 Tools/CodexRuntime/bootstrap.py
python3 Tools/Release/setup_sparkle.py
```

当前脚本仅支持 Apple Silicon 构建宿主，但 Release 同时构建 arm64／x86_64。已有缓存环境的构建验证不等于一台全新 Mac 已验收；Intel 构建宿主暂未提供同等自动准备入口。网络、Xcode 与首次依赖下载仍需可用。

## 已准备环境的构建

先通过 `Tools/CodexRuntime/package.py --configuration All` 准备并校验 Debug／Release 的运行组件。默认工具链位置为 `.build/QA/CodexTranslationPrototype/toolchain/bin/cargo`；该流程还会检查对应官方工具链归档，不能只指向任意系统 Cargo。

随后从仓库根目录运行：

```sh
python3 Tools/CodexRuntime/package.py --configuration All --verify-only
Scripts/verify.sh
```

完整检查包含工程与双语资源、API 类型检查、隔离宿主 XCTest、官网 Debug／Release 构建，以及主 App／运行组件签名、Hardened Runtime 和权限检查。也可打开 `TranslateX.xcodeproj`，选择 `TranslateX` scheme；内置签名团队仅代表维护者的发布身份，不提供证书或私钥。

验证产物位于 `.build/DerivedData/Build/Products/Debug/TSX.app` 和对应的 `Release` 目录。校验脚本使用 ad-hoc 签名，不能作为已公证的正式安装包。正式发行按 [RELEASING.md](RELEASING.md) 完成 Developer ID 签名、公证、打包与安装升级验证。

Debug 开发构建停用在线检查和安装更新，不改动已有自动更新偏好，避免发行包覆盖 Xcode 构建产物；关于页会显示停用说明。Release 构建保留正常更新能力，测试及视觉夹具仅使用隔离的模拟更新器。

## 参与开发

- 工程配置以 `project.yml` 为准，变更后运行 `xcodegen generate` 并提交共享工程。
- [AGENTS.md](../AGENTS.md) 记录开发约定；[架构](Architecture.md)、[分发规则](Distribution.md)、[验证摘要](Validation.md)和[公开仓库规范](PUBLIC_REPOSITORY.md)提供实现、已测边界与内容准入要求。
- 不提交 API Key、账号凭据、签名私钥、真实翻译内容、私人截图或 `.build` 产物。请使用构造样例。
- 自动测试不代表真实服务资格、Apple 翻译、系统权限、Intel 或最低系统版本已经验收。

## English

The source includes Swift/AppKit/SwiftUI application code and an optional Rust account runtime. Use a full Xcode installation with the required Swift 6/macOS SDK APIs, Python 3 and (when regenerating the project) XcodeGen 2.46 or newer. The deployment target is macOS 15.

On an Apple Silicon build host, run `python3 Tools/CodexRuntime/bootstrap.py` and `python3 Tools/Release/setup_sparkle.py` from the repository root. These prepare hash-verified, pinned compiler/source/dependency inputs inside ignored `.build` directories without installing global Rust. Network access and several GiB of disk space may be required. The bootstrap currently supports Apple Silicon build hosts; Release output includes both arm64 and x86_64. Validation with existing caches does not establish a clean-Mac setup.

Then run `Scripts/verify.sh`, or open the committed `TranslateX.xcodeproj` and choose the `TranslateX` scheme. The verification script builds Debug/Release, checks signing and permissions, and runs tests in an isolated host. Its ad-hoc signed outputs are not notarized releases. See [the release workflow](RELEASING.md) for distribution signing, notarization and installation checks.

Debug builds disable online update checks and installation without changing existing automatic-update preferences, preventing a release package from replacing an Xcode build product. About explains this restriction. Release builds retain online updates; tests and visual fixtures use isolated simulated updaters.

Follow the [public repository rules](PUBLIC_REPOSITORY.md). Keep credentials, signing keys, personal text/screenshots and build artifacts out of Git. Third-party dependencies retain their own licenses. Compilation and automated tests do not establish real Intel/macOS 15, account-service, translation or permission coverage.
