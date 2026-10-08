# Codex 认证、独立 Keychain 与单次翻译探针

这是开发验收工具，不是 Lumax 产品中的登录入口。它编译官方公开认证、策略和模型客户端，向本机假认证服务发请求，并只读写本轮新建随机身份对应的精确 Keychain 项。不使用真实账号、默认 Codex home、现有用户登录或线上模型。

官方源固定到 `36650394c5b38c2990ccf2a3457165ca3e9d9726`；归档摘要和完整文件校验复用相邻 [单次模型探针](../CodexTranslationProbe/README.md) 的构建入口。没有修改官方源码，也没有通过浏览器登录、复制 token 或反向代理替代官方认证库。

## 运行

在仓库根目录提供已经存在的 Rust/Cargo 1.95 工具链，以及本机可用签名证书的 SHA-1：

```sh
python3 -I Tools/QA/CodexAuthProbe/verify.py \
  --cargo .build/QA/CodexTranslationPrototype/toolchain/bin/cargo \
  --signing-identity YOUR_EXISTING_CERTIFICATE_SHA1
```

可选 `--without-native` 只运行认证/模型套，省略 Swift 构建与四个原生会话场景，证据会记录该范围；默认完整入口包含原生宿主。它不能代替原生交互验收。

入口不会安装工具链、创建证书、运行真实登录或修改系统 Keychain 设置。QA helper 仅对自身禁用 Keychain 授权弹窗；这不代表产品应静默忽略正常授权流程。签名标识固定为 `com.theoyuuu.LumaxTranslate.QA.CodexAuth`，与交付 App 分离。

宿主强制超时的独立检查可运行 `python3 -I -B Tools/QA/CodexAuthProbe/test_watchdog.py`。它只启动本次的休眠进程，验证另起会话的 helper 与其 worker 都被停止，不访问认证或 Keychain。

清单故障检查可运行 `python3 -I -B Tools/QA/CodexAuthProbe/fixtures/test_harness.py`，验证原子写入失败及损坏 journal 不阻断其他已知身份的清理枚举；它禁止真实进程、网络和 Keychain 调用。

每次执行先固定输入、检查官方源码、锁定依赖编译，再复制并签名独立 helper。入口同时用 Swift 6 严格并发编译 `native/` 宿主，运行原生协议负例、假服务自身测试和真实 helper 检查。构建与摘要在 `.build/QA/CodexAuthPrototype/builds/verify-*/`；构造身份和测试结果在 `.build/QA/CodexAuthPrototype/runtime/` 下的随机运行目录。凭据内容、一次性代码和原始认证错误不写入报告。

## 隔离和清理

- 仅允许明确给出的 `127.0.0.1` 假 issuer，子进程环境采用白名单；不接受用户环境中的 API Key、access token、认证地址或代理覆盖。认证翻译 worker 的刷新地址只能由 supervisor 根据已验证 issuer 构造，缺失或不相等都会拒绝。
- CoreFoundation 在程序入口前加入的编码变量仅在数值格式、长度和当前 UID 校验后被允许。系统会重写外部传入的该变量，因此没有把伪造编码的进程注入当成解析防护已验收。
- 存储固定为严格 `Keyring` + `Direct`。使用官方库由专属规范路径计算 account，不枚举凭据，不回退到 `auth.json`。
- 登录先写本轮独立临时身份；提升成功后删除临时项。截止时先终止并回收登录 worker，再用独立 worker 清理本次精确条目。未确认清理时保留非敏感恢复清单并报告 `cleanup_required`。
- 测试宿主遇到失败或中断时也必须停止自有进程、逐项退出并确认 `signed_out`。无法确认的身份目录不能删除或被报告为已清理。
- 可重复入口超时先给宿主清理时间；仍超时则停止其新建进程，终止它的私有 helper 会话及宿主。硬终止仍可能留下待清理项，应检查该轮原子写入的清单。这不是机器掉电或宿主突然崩溃的恢复保证。

## 认证翻译与管理策略

`authenticated_translate` 将已保存的构造身份接到共用的单次翻译引擎。固定官方管理策略加载器处理内存中的系统/MDM/cloud 输入；登录方式、工作区和网络限制先于模型请求。实际机器策略来源与生产动态重载尚未接入。

令牌需要刷新时，只调用一次官方返回明确 Result 的刷新接口；失败、刷新后仍过期或账号字段矛盾均停止。最后的认证适配器只走官方同步缓存路径并检查认证头，避免异步路径在刷新失败后沿用旧令牌。过期判断按本次固定上游的五分钟/八天规则核对；本原型额外要求存在匹配的持久刷新时间，缺失时拒绝，未宣称兼容任意旧账号记录。这里的 ID-token 字段一致性检查不等于 JWT 验签。

模型成功/401/工具输出、主动过期刷新及异常、同 home 身份替换、管理限制均由独立假服务核对实际请求。单次引擎只保留完整译文，不续轮、不重试；假服务严格核对原文、认证头和刷新后的 token，报告仅保存计数与布尔。请求前后的账号变化可能先被官方网络许可阻止，不将一个阻止结果写成每层守卫都已实际触发。

## 证据边界

`request_device_code` 和 `complete_device_code_login` 仍是两个独立测试操作，不能串联充当界面登录。新增 `login_session` 在一个 worker 内保留同一官方 DeviceCode，先发 ready，再等待授权和存储。版本号、请求 UUID、终态与取消 JSONL 格式见 [协议](PROTOCOL.md)。显式取消、stdin EOF、无效控制消息都先停止并回收 worker，再清理精确身份；取消与成功交付由同一提交点确定先后。终态、管道 EOF 和成功退出必须共同成立，单独收到 signed_in 不足以判成功。

`native/CodexAuthSession.swift` 是供后续原生界面集成的 QA 宿主，尚未装入 App。它在 MainActor 更新状态，所有 pipe 端禁止 exec 继承，用非阻塞有界队列写输入；stdout/stderr 各自通过 DispatchSourceRead 非阻塞、保序、有界读取，避免静默错误管道期间 ready 事件迟到，Swift Task 取消也传播为协议取消。设备码仅在当前会话内存中；固定错误不回显原始 stderr。正常显式取消和关闭 stdin 会等待 helper 的收尾。18 秒看门狗之后另给 6 秒 EOF 清理宽限，再尝试停止仍存活且确切自有的进程组，最多另等 2 秒回收；这不是硬实时保证。

helper 已退出但后代持有管道时，宿主会关闭读端并返回 cleanup_required，不无限等待，也不向已回收、可能复用的 PID 发信号。此异常结果不证明后代或凭据已清理。原生协议负例只用自建假进程；实际官方组件和 Keychain 的原生流程另外通过同一假 issuer 验证。正式设置关窗、应用退出和强制死亡恢复仍须产品集成后验证。

此工具验证的是构造认证协议和本机存储行为。它不证明真实 ChatGPT 授权、工作区许可、线上令牌刷新、线上模型请求兼容、翻译质量或费用，也不证明主进程崩溃后的自动恢复、所有取消与存储竞态、升级或 Intel 机器兼容。产品集成还需接入可信的实际认证/网络策略来源、官方工作区路由，完成原生生命周期和构建分发检查；当前假服务测试不读取本机实际管理策略。

每次运行的实际场景、结果与跳过项以生成的报告为准；不能沿用其他运行或其他设备的结果。

## 与正式运行组件共享的边界

账号请求准备已移到 `Runtime/CodexHelper/src/account_request.rs`，原始 SSE 检查位于同目录 `sse_guard.rs`。本入口把它们纳入冻结输入和摘要，不维护副本。`qa-fixtures` 只在此探针默认启用，允许构造身份替换；正式运行库默认不包含该分支。loopback translation wrapper 仍来自相邻探针，不能把 QA 的短截止或固定 fixture-model 用作产品请求。

正式组件采用 generation home + active 指针的持久提交点，与本探针历史“终态发送失败则回滚目标”协议不同。该新语义的文件恢复测试不等于真实 Keychain 崩溃恢复已验收。正式策略、路由和存储组件的独立验证入口见 `Tools/CodexRuntime/build.py`，主管进程、原生界面及真实账号仍需继续集成。
