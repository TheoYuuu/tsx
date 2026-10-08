# Codex 无账号模型客户端探针

这是开发用重跑入口，不是 App 的登录入口；响应检查与待集成的运行组件共享源码。原创 Rust 原型直接使用固定官方 Codex 模型客户端，配套 Python 服务只提供构造的回环响应；它不启动真实模型、不读取现有账号，也不执行登录。

**通过本探针只能证明本次无账号模型客户端的受测协议和隔离行为。** `AuthManager`、账号登录／刷新／退出、真实工作区与模型可用性、翻译质量和计费边界均未验证，不能据此宣称 Codex／ChatGPT 接入完成。

单次请求引擎现在位于 `src/translation.rs`。无账号入口传入 NoAuth；相邻认证探针在冻结构建输入时复制同一文件，传入官方认证适配器，不维护第二套模型协议实现。原始 SSE 检查已共用 `Runtime/CodexHelper/src/sse_guard.rs`，新增 commentary/metadata 用例后共 61 项，仍只覆盖无账号请求；认证证据单独记录。

## 前提与运行

- macOS、可用的本机编译工具，以及事先准备好的 Rust/Cargo **1.95**。入口必须显式指定已有 `cargo`，同目录须有 `rustc`；不会安装或升级工具链。
- 本目录须包含最终冻结的 `src/main.rs`、`src/translation.rs`、`Cargo.toml`、`Cargo.lock` 和 `probe.py`。`verify.py` 冻结这些输入和共享的 `Runtime/CodexHelper/src/sse_guard.rs`，不使用正在修改的忽略目录 `app/`。
- 构建需要下载固定官方源码及 Cargo 锁定依赖，或复用已校验的缓存；这是开发依赖网络访问，不是真实模型调用。缓存与构建可能占用数 GiB 空间。
- 请先结束本原型的其他手动构建与探针运行。入口间有互斥锁，但不接管其他独立进程。

从仓库根目录运行，例如本次已准备的私有工具链：

```sh
python3 Tools/QA/CodexTranslationProbe/verify.py \
  --cargo .build/QA/CodexTranslationPrototype/toolchain/bin/cargo
```

也可传入另一份明确选定的 1.95 `cargo` 路径。缺少工具链、输入文件、系统工具、网络或验证失败时停止，不自动改用用户默认工具链、读取账号或跳过锁文件。编译使用 `cargo build --locked`；失败详情保留在本次 `build.log`。

## 固定来源与文件边界

官方来源为 [openai/codex 固定提交](https://github.com/openai/codex/tree/36650394c5b38c2990ccf2a3457165ca3e9d9726)，不跟随分支更新：

- 归档：`https://codeload.github.com/openai/codex/tar.gz/36650394c5b38c2990ccf2a3457165ca3e9d9726`
- SHA-256：`392ac15292437f4163fc6b05cdcc53e80cdc15f88459fd969673e6ac717d7af5`
- 本地源码：`.build/QA/CodexTranslationPrototype/source/codex-36650394c5b38c2990ccf2a3457165ca3e9d9726`

下载仅使用该 HTTPS 地址，不继承代理、认证或 cookie，不接受重定向；归档最多 64 MiB，下载受时间限制。哈希匹配后先审核全部 tar 条目：限制 20,000 项、展开合计 256 MiB、单文件 16 MiB，拒绝路径穿越、绝对路径、多义路径、硬链接、设备文件及特殊权限。符号链接只能指向归档内明确的普通文件，且不允许作为解包路径的祖先；解包不应用归档的属主、扩展元数据或可写权限。

已有源码与归档逐项比较路径集合、文件内容、类型、可执行位及链接目标，缺失、额外文件或内容变化都会停止，**不覆盖或修补上游源码**。新解包的文件／目录使用 644／755；复用此前按官方归档 664／775 模式提取的源码时，只允许归档原有的组写入位，拒绝新增组写入、其他用户写入或特殊权限，不修改已有权限。新解包只写新临时目录，成功后移入固定源码路径；构建后再次核对源码未变。

所有下载、源码、缓存、编译产物和证据均留在已忽略的 `.build/QA/CodexTranslationPrototype`：

| 位置 | 内容 |
| --- | --- |
| `downloads/`、`source/` | 固定归档与经核对的官方源码，保留上游许可文件 |
| `staged-app-*/` | 每次独立复制的原创 Rust 输入和锁文件；相对 `../source/…/codex-rs` 依赖保持有效 |
| `cargo-home/`、`rustup-home/`、`target/`、`tmp/` | 本任务私有缓存、构建和临时目录 |
| `builds/verify-*/` | 本次版本、逐文件完整性、输入摘要、构建及探针日志 |
| `probe.py` | 最终跟踪探针的生成副本，由入口复制后运行；以该目录为 ROOT |
| 探针创建的独立证据／身份目录 | 每次回环检查结果及隔离目录；准确位置以 `probe.log` 为准 |

二进制沿用 `target/debug/lumax-codex-translation-prototype`。此入口不触碰正式 App、用户配置、账号文件或系统安全设置，不删除旧证据。当前上游源码及依赖许可保留在源码／缓存中；该原型入口不构成分发许可审查或产品打包决定。

## 环境与停止条件

构建环境采用白名单：父进程 `HOME` 保持原含义，`PATH` 仅含所选工具链与系统命令；`CARGO_HOME`、`RUSTUP_HOME`、`CARGO_TARGET_DIR`、`TMPDIR` 明确指向任务目录。仅额外允许已有的 `DEVELOPER_DIR`、`SDKROOT` 和 `MACOSX_DEPLOYMENT_TARGET` 编译设置，不继承模型凭据、代理、Rust 注入或其他环境变量。Git 系统／全局配置、凭据助手、交互提示、SSH 和 hooks 被禁用；发现祖先 Cargo 配置或私有 Cargo 目录中的配置／凭据会停止，不读取其内容。

工具链版本检查各限 15 秒，Cargo 构建限 900 秒，探针进程限 300 秒。超时或中断会终止入口自己启动的新进程组，必要时强制结束并回收；不会发送信号给用户原有进程。每次日志独立保存，不因重跑覆盖此前失败。

`verify.py` 成功退出表示来源检查、构建和所调用本地探针均成功退出；具体通过项目以该次探针报告为准。它不证明真实模型调用、账号隔离、工具链分发、商店兼容或线上费用上限。固定客户端与协议行为仍需在任何后续升级时重新审查，不因这次本地通过而自动升级组件。
