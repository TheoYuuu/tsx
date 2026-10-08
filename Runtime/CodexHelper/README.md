# Codex 账号翻译组件

本目录是 TSX 的账号运行组件，使用固定版本的官方 Codex 公开底层库，不启动 Agent、工具循环或 app-server。主管/worker 已嵌入应用，由 Swift 会话和设置中的实验性登录入口调用。产品集成和构造测试不代表真实 ChatGPT 账号、模型资格或翻译质量通过；覆盖范围见[验证摘要](../../Docs/Validation.md)。

固定上游为 `openai/codex@36650394c5b38c2990ccf2a3457165ca3e9d9726`（rust-v0.157.1），不修改上游源码。下载、摘要、冻结构建和许可流程见[打包契约](../../Tools/CodexRuntime/PACKAGING.md)；运行产物和私有复核材料不入 Git。

## 职责

| 文件 | 能力 |
| --- | --- |
| `main.rs`、`host.rs`、`protocol.rs` | OS 账号根目录、环境白名单、有界单操作 JSONL |
| `supervisor.rs`、`worker.rs` | 设备码、账号状态/清理、提交恢复及进程生命周期 |
| `connection.rs` | 策略、认证、模型目录、工作区路由和一次翻译 |
| `account_storage.rs` | 账号代际、排他 lease、持久提交点与恢复；不自行访问 Keychain |
| `account_request.rs` | 严格官方 Keyring 加载、身份锚点、受控刷新及固定错误 |
| `policy.rs` | 官方系统/强制 MDM 来源与云策略合并，不采用用户/项目配置 |
| `network.rs` | 网络许可、代理/CA、单次请求、撤销、超时与大小限制 |
| `routing.rs` | 工作区唯一匹配、官方 Responses 路由及账号模型目录 |
| `translation.rs`、`sse_guard.rs` | 纯文本翻译、禁止工具/重发/继续轮次、完整 SSE 结果校验 |

## 运行契约

1. 账号根目录由 OS 用户数据库派生，位于用户 Application Support 下的 `com.theoyuuu.LumaxTranslate/CodexAccount`。不接受任意 IPC 路径、HOME/CODEX_HOME、issuer、endpoint 或配置覆盖，不访问其他 Codex 登录。目录逐层检查 owner、权限和符号链接，私有目录为 0700。
2. 所有操作先取得 `AccountStorage` 排他 lease 并处理恢复；worker 继承同一打开文件描述并保持至退出。不能只检查 inode 或提前解锁，清理不得与旧 worker 并行。
3. 官方凭据按 `identities/<UUID>` 的独立 Keychain 项保存。`active.json` 是持久提交点：提交后 IPC 回复丢失不撤销已登录状态；提交前取消清理候选。未确认清理的 journal 保留，不包含 token。
4. Models/Translate 必须校验 `expected_generation`，与保存配置和原生控制器一致。账号变化使旧请求失效，不把旧正文转交新账号。控制器共享单操作槽，正常退出等待回收；普通退出不注销已提交账号。
5. 管理策略按 bootstrap 和最终网络限制装配，云资格或策略获取失败不能退回空策略。模型、推理量、服务等级、附加指令和驻留要求必须落实，无法落实则失败。涉及进程全局驻留状态的官方接口只在单请求 worker 内使用。
6. 严格加载本次身份并明确准备认证；刷新失败不能使用旧 token，也不重复隐式刷新。工作区路由复用官方解析，不直接硬编码地址；路由前后核对身份快照，模型目录不使用 Responses 发现地址或静态回退冒充资格。
7. 一次请求只返回完整最终译文。失败、401、取消和工具输出不自动重发；不传原始服务错误、凭据或推理内容。正式进程不得安装可能打印正文/SSE 的日志订阅器，父 future 的临时日志抑制不能约束另行 spawn 的任务。
8. Swift 会话使用独立非阻塞管道和严格结果协议；终态、两条 EOF 与正常退出同时成立才接受结果。取消给予主管有限清理时间，未确认回收前禁止启动下一操作。硬杀不能证明系统 Keychain IPC 已停止。
9. 退出账号先回收请求、写退出 journal、尝试官方 revoke，再严格确认精确本地 Keychain 项已不存在。官方成功返回不能单独证明远端会话撤销。

## 构建与独立验证

先按[源码构建说明](../../Docs/BUILDING.md)准备隔离的固定工具链与依赖。组件独立检查入口：

```sh
python3 -I Tools/CodexRuntime/build.py \
  --cargo .build/QA/CodexTranslationPrototype/toolchain/bin/cargo \
  --cargo-home .build/QA/CodexAuthPrototype/cargo-home
```

默认 feature 为空；`qa-fixtures` 仅供构造身份与回环 HTTP 测试，不得用于产品构建。正式传输仅接受 HTTPS。构建使用锁定的离线依赖，运行组件测试和原生拒绝边界；这些拒绝用例在访问真实账号或管理环境前结束，不能计为线上验收。

Debug 使用宿主架构，Release helper 包含 arm64/x86_64。Xcode 嵌入阶段只接受与源码/工具指纹匹配的包，不隐式下载或构建 Rust；签名与许可必须与主应用一起核对。

`Tools/CodexRuntime/worker_smoke.rs` 和对应 Python 驱动提供独立的真实 Keychain 构造检查，只操作测试专用随机身份及签名副本，并核对清理。它们不执行真实登录、模型请求或远端 revoke。测试可执行文件、临时凭据及 QA feature 均不进入产品包；不得把已签名测试宿主当作交付组件。
