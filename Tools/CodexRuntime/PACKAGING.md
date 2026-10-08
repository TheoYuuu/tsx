# Codex helper 本地打包

本流程用于当前官网渠道。只构建 Lumax 原创主管/worker 与固定官方 Rust 库组成的 `lumax-codex-runtime`，不包含 Codex CLI、app-server、QA binary 或 `qa-fixtures`。它不会创建登录、查询真实账号、访问账号 Keychain、读取管理策略或请求模型。构建、开发签名和本地嵌入不代表公开发布或公证。

## 构建入口

```sh
python3 Tools/CodexRuntime/package.py --configuration All
python3 Tools/CodexRuntime/package.py --verify-only --configuration All
python3 Tools/CodexRuntime/test_package.py
```

也可单独选择 `Debug` 或 `Release`。默认对产物使用 ad-hoc 签名；需要现有证书时，显式传 `--sign-identity <certificate-sha1>`。脚本不会创建或下载证书，也不会改变系统安全设置。

当前构建入口在 arm64 macOS 上使用已校验的私有 Rust 1.95.0 工具链和锁文件对应的公开 Cargo 缓存；Intel 是交叉编译产物，不承诺在 Intel 主机上运行此构建入口。默认沿用本轮已经验证的：

- `.build/QA/CodexTranslationPrototype/toolchain/bin/cargo`
- `.build/QA/CodexAuthPrototype/cargo-home`

可用 `--cargo` / `--cargo-home` 指定本仓库 `.build` 内的真实路径。不会使用默认 `~/.cargo`、现有 Codex 配置或环境中的认证、代理设置。父 `HOME` 保留其原义，Cargo/Rustup/target/tmp 均使用任务专用路径；拒绝祖先目录与指定 Cargo home 中的配置/凭据文件。

脚本复核已有官方工具链组件档案及实际安装文件。需要 Intel 标准库时，从固定 Rust 1.95.0 官方 manifest 验证 URL/摘要，下载校验后只复制库文件到私有工具链，不执行档案内安装脚本。Cargo 构建始终 `--locked --offline --no-default-features --bin lumax-codex-runtime`。首次许可收集可能只读下载发布时固定 Git commit 的上游许可文件；Xcode 嵌入阶段不会触发这些下载。

## 产物与嵌入契约

| 配置 | 架构 | 编译优化 | 固定产物目录 |
| --- | --- | --- | --- |
| Debug | 当前构建主机架构；本轮为 arm64 | release profile | `.build/CodexRuntime/package/Debug` |
| Release | arm64 + x86_64 universal | release profile | `.build/CodexRuntime/package/Release` |

两个目录均包含：

- `lumax-codex-runtime`
- `THIRD-PARTY-NOTICES.txt`
- `package-manifest.json`

每个 Mach-O slice 的最低系统固定为 macOS 15.0；最终可执行文件裁剪符号，使用标识 `com.theoyuuu.LumaxTranslate.CodexRuntime` 并保留 Hardened Runtime。仅接受系统动态库引用。编译期不裁剪 proc-macro 库：本机已复现系统 loader 对裁剪后插件库报 `mis-aligned LINKEDIT string pool`，因此 `[profile.release] strip = "none"`，只对最终 helper 执行裁剪。

Xcode 通过 `Scripts/embed-codex-runtime.sh` 执行只读校验后，把 helper 复制到 `Contents/Helpers/lumax-codex-runtime`，把 notice 复制到 `Contents/Resources/CodexThirdPartyNotices.txt`，再用当前 App 的签名身份签嵌入副本。App 通过自身 Bundle 定位该 helper。没有预生成产物或源码已经变化时，构建阶段明确失败并提示先运行打包命令，不静默下载或使用旧包。

`--verify-only` 只检查当前源码与工具哈希、二进制和 notice 哈希、固定官方来源、配置/架构、禁用 QA 特征与签名；不构建、下载、签名或执行账号功能。源文件、锁文件或任一打包工具修改后必须重新打包。

## 来源与完整性证据

每次运行建立独立 `.build/CodexRuntime/builds/package-*`，不覆盖历史证据。包含：

- `inputs.json`：本次冻结的 Runtime manifest、lock 和全部 Rust 源文件摘要。
- `source-integrity.json`：固定官方 commit `36650394c5b38c2990ccf2a3457165ca3e9d9726` 的完整源码档案审计；源码不打补丁。
- `dependency-integrity.json`：注册表 `.crate` 档案与 Cargo.lock 摘要一致，逐文件对比实际缓存；Git 依赖核对固定 commit 与未修改工作树。
- `private-toolchain-integrity.json` / `intel-standard-library.json`：官方编译器、Cargo、两种架构标准库的档案及安装文件核对。
- 分配置构建、载入命令、系统依赖和签名检查日志。
- `cargo-metadata.json`、`licenses.json`、`THIRD-PARTY-NOTICES.txt` 和 `result.json`。

构建完成后再次核对冻结输入、上游源码与公开依赖；变化则保留本轮证据并失败，不更新供 Xcode 使用的产物。`package-manifest.json` 的 `runtimeInputs` 和 `toolInputs` 同时绑定产品源文件与 `package.py`、`licenses.py`、`build.py`、固定源码审计工具。构建产物、第三方源码、依赖缓存与本地证据均不入库。

重签名会改变 Mach-O `__LINKEDIT` 的虚拟大小。实际 universal 样本证明：仅对两个副本 `codesign --remove-signature` 后比较完整 SHA 不稳定。`verify_bundle.py` 先在两个私有副本上应用同一 ad-hoc 签名，再移除签名后比较；不修改原 App 或打包产物。嵌入副本的实际签名、团队、Hardened Runtime、权限和架构仍单独严格校验。

## 许可清单边界

清单覆盖 Cargo metadata 的保守依赖集合，包含构建期依赖，不宣称每个包的代码都会进入最终机器码。保留实际包内 LICENSE/NOTICE、固定 Git 来源中的共享许可和完整源码许可头；另外收录静态链接的 Rust 标准库版权与许可说明。MPL 等依赖同时列出对应版本的公开未修改源码档案位置。

少数发布 crate 仅在 Cargo metadata 声明许可，发布内容和固定源码树没有单独许可文件。`licenses.py` 对明确的 Apache/MIT 声明附标准许可正文，并保留其发布作者及源码版权行；不会补造版权年份或持有人，也不冒称这些补全文本是上游原件。`standardTextSupplements` 单独列出它们，供公开分发准备时核对。没有可确定许可文本的依赖会使打包失败。此清单不为 Lumax 本身新设许可证，也不代替分发前的许可审阅。

## 本轮实际验证

本轮完整证据为 `.build/CodexRuntime/builds/package-v8rj_dg0`：

- Debug arm64：24,189,072 bytes；Release universal：49,141,904 bytes。
- 两配置均优化、固定最低系统、系统动态库限制、全架构签名与 Hardened Runtime 检查通过。
- 每个签名产物在当前 arm64 主机仅运行非法 IPC，确认在账号路径建立之前拒绝；无账号操作。
- 788 项依赖、441 份去重许可正文及 Rust 标准库；11 项标准文本补全明确列入 manifest。
- `--verify-only --configuration All` 和 6 项纯打包校验测试通过。

Intel 架构已交叉编译和静态/签名校验，未在 Intel 真机运行；Mach-O 的 macOS 15 最低系统声明不等于 macOS 15 真机验收。本流程也不证明真实登录、额度、模型可用性或翻译质量。
