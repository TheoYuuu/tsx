# 官方设备码假认证夹具

仅用于本次固定官方库原型；服务器绑定新分配的 `127.0.0.1` 端口，不调用 OpenAI，不打开浏览器。不得将通过结果外推为真实账号登录完成。

`fake_issuer.py` 独立按官方 `login/src/device_code_auth.rs`、`server.rs`、`auth/revoke.rs` 校验请求：

- 申请：JSON `POST /api/accounts/deviceauth/usercode`，client ID 为构造值 `lumax-fixture-client`。
- 轮询：JSON `POST /api/accounts/deviceauth/token`，必须匹配本次内存中的 device ID 和 user code。403/404 表示继续等待；拒绝和过期测试返回 400，不能把 403 误称已拒绝。
- 兑换：form `POST /oauth/token`，精确核对 grant type、client ID、授权码、PKCE verifier 和设备码 callback URL。
- 返回 JWT 使用官方测试中的未签名构造方式，具有专门的假账号/user/邮箱和未来过期时间。不是有效的 OpenAI 凭据。
- 取消测试在设备码申请、轮询或交换请求已到达后保持 socket，观察客户端 EOF；服务器自己的关闭不计作取消。

`probe.py --binary SIGNED_HELPER --output-root CANONICAL_PROTOTYPE_RUNTIME` 创建新的 UUID run。运行时只给 helper PATH/LANG/TMPDIR，环境隔离反例故意附加构造环境值并要求拒绝。实际 Rust/Keychain 运行须由根验证流程在签名与源码检查后统一安排。

保留原 24 项操作场景：独立申请、三个正常/等待登录、十二个申请/轮询/兑换错误、两阶段取消、环境变量拒绝、两种重定向阻断、保存后提升前取消、损坏精确 Keychain 项加载失败、两个 home 的读取/删除隔离。所有负例有明确预期状态，不以任意非成功代替分类检查。

新增持续 `login_session` 的 14 项直接 helper 场景：同码成功；显式取消和 stdin EOF 各覆盖设备码返回前、轮询、兑换、提升前和提升后；另在轮询期间发送损坏 JSON、错误 request ID、超过 4096 bytes 的控制行。正常请求使用一行 JSON 加 LF，后续取消也以 LF 分隔。runner 保持 stdin 打开直到结束，持续读取有界 stdout/stderr，要求 terminal 恰好一次且是最后事件，并等待 helper 自行退出。超时后强制回收不能计作正常完成。

同码成功必须同时满足：唯一 ready 的码和 URL 与假 issuer 的本次内存值完全一致，申请接口恰好一次，每次轮询严格使用该 device ID/user code，兑换恰好一次。码和 token 都不写入证据。保存阶段场景使用专用最多 1000 ms 的确定性暂停钩子，在收到 phase 后发送取消/EOF；取消必须产生 `cancelled`，清除 stage 和可能已提升的 target，不能晚到 `signed_in`。错误控制消息必须产生 `invalid_control`，而非任意非成功状态。

每个持续场景还在全局清扫发出任何 logout 前，以新 helper 进程对返回的精确 stage home 执行 status，确认已经 signed_out；不能仅凭 terminal 的 `stage_cleanup_ok`，也不能用最终安全清扫掩盖流程自身未删除 stage 的回归。已经发出设备码请求却未返回可登记 stage 也算失败。

另有 1 项真实输出管道故障：收到 `after_promotion` 后先通过 journal 精确登记 stage，再关闭 stdout 读端，并保持 stdin 打开。helper 必须自然以固定退出码 4 退出、stderr 为空；随后在任何全局 logout 前，以新进程确认 target 和 stage 都已 signed_out。这检查目标已经保存后的 BrokenPipe 回滚，不声称拦截了系统 Keychain 写入过程；管道关闭后也不声称观察到了不可读取的输出。

可选 `--native-binary COMPILED_SWIFT_HOST` 再增加 4 项经原生 Swift `Process` 宿主的场景：成功、ready 后显式取消、ready 后关闭输入、ready 后取消外层 Swift Task。runner 向宿主传入 helper 路径和同一持续协议首行；宿主事件仍只在内存比对，且必须确认 `host_status=completed`、helper 已回收、stderr 为空。这验证可供界面调用的宿主边界，不等于产品 UI 关闭/退出已接通。这组历史基线无原生宿主为 39 项，有宿主为 43 项；下面认证翻译场景另行加入，最终数量由报告中的实际 cases 动态统计，准备完成不等于真实运行通过。

边界和清理：

- 单次旧操作 helper 上限 15 秒，直接持续 session 上限 20 秒；经 Swift 宿主时上限 35 秒，留出宿主自身超时、EOF 清理和回收宽限。官方业务 deadline 最长 6 秒，worker 回收和精确存储清理另有时间，不能称总耗时最多 6 秒。
- stdout/stderr 均有 64 KiB 限制；超时、输出超限、异常和信号均回收自己的进程组。
- SIGTERM/KeyboardInterrupt 进入 finally；清理最多 25 秒，为外层 30 秒宽限留余量。
- 精确登记每个本次随机 target，以及从它的非敏感清理 journal / helper 结果获得的随机 stage。不得扫描全部 runtime、默认 Codex home 或用户 Keychain。
- 清理逐项执行官方 logout 后再独立 status 确认 signed_out。未确认的目录保留；`identity-manifest.json` 提供精确路径和 cleanup_required。
- 中途报告 `finished=false`、`cleanup_complete=false`；最终所有已登记身份均确认后，才将 cleanup_complete 改为 true。空 cleanup 数组不表示完成。
- auth.json 检查仅访问所有已登记 target/stage 的精确路径 metadata。允许非敏感 lock/journal 文件，不宣称完全零文件。
- 报告仅状态、固定路由、计数和布尔。设备码仅保留在 IPC 内存，JWT、token、账号、user、邮箱及错误回显 marker 都不能进入报告。

“保存后取消”是阶段钩子，证明真实保存完成后、提升前的清理；不模拟拦截正在进行的系统 Keychain 写入。“损坏存储”是真实精确测试项的反序列化读取失败，不是模拟 Keychain 写入故障。此处历史登录基线未覆盖身份更换和刷新；新增覆盖见下节。服务器撤销、硬杀主管恢复、真实保存中取消、浏览器回调和真实账号仍未由完整 helper 用例验证。

Python 自身测试：`python3 -I -B fixtures/test_fake_issuer.py` 验证假认证服务器与内存请求；`python3 -I -B fixtures/test_harness.py` 验证原子证据写入和坏 journal 不阻断其他身份的清理枚举；`python3 -I -B fixtures/test_session_protocol.py` 验证事件次序、同码检查和脱敏判断。后两者不打开 socket；三者均不执行 Rust 或访问 Keychain。清理枚举中的构造 signed_out 不代表系统凭据清理成功。

## 认证后的单次模型请求

新增场景先完成官方设备码登录并写入精确 Keychain 项，再由新进程加载该身份，调用共用的单次 Responses 引擎。`POST /v1/responses` 必须精确匹配当前内存 access token 与账号 header、固定翻译指令、唯一 user 原文、空 tools、tool_choice=none、store=false、stream=true。原文与预期译文包含随机标记，保留在内存；报告只保存匹配布尔。

刷新使用 `POST /oauth/token` 的 JSON refresh_token grant 与固定官方 client ID，与设备码兑换的 form 请求和 QA client ID 分开核对。每次成功旋转 access/refresh token，旧新 token 全部加入内存泄漏检测。覆盖强制与实际过期触发的刷新、401 invalid_grant、格式错误、刷新后仍过期、账号与 user 同变，以及仅 ID-token account 变化但 user 不变。后者检验官方持久 account_id 不随刷新更新时，调用方仍能阻止矛盾身份进入模型请求。

模型 401 不重新刷新或重发，工具输出不能引发续轮。更换同一 home 中的构造身份后，原请求不得发送模型内容。组织策略场景覆盖允许/禁止 ChatGPT、工作区不匹配、MDM 优先级、云端不得替换本地认证限制、网络禁止、坏策略及不支持的凭据存储要求。所有政策来自内存，不读取本机管理设置。

每个场景校验完整 OAuth grant 数量和模型 POST 数量，不以客户端自报 attempts 代替服务端观察。旧场景继续要求无 Authorization；模型场景改为精确授权策略，其他端点仍不得携带 Bearer 或 cookie。实际执行结果与清理数量以对应 report.json 为准；纯假服务自测并不代表官方客户端已通过。
