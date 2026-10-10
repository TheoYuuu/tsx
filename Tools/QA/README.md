# 本地验证工具

## 翻译服务真实网络栈探针

运行 `python3 Tools/QA/remote-translation-network.py`。它直接编译正式服务工厂、通用/专用 Provider、配置、解析器及请求/结果代码，不注入网络替身；HTTP 夹具仅绑定 `127.0.0.1` 的系统分配端口，测试结束或失败后关闭。产物和报告位于忽略目录 `.build/QA/RemoteTranslationNetwork`，不进入交付 App。

探针只发送固定公开样例与虚构密钥，不读取设置、钥匙串或真实厂商账户，不发起外部请求。覆盖 Responses 和 Chat 的分块 SSE（含拆开的 UTF-8 字符）、JSON 回退、同源/异源重定向拒绝、缺少结束标识、响应头前取消和已有部分译文时取消。服务端断言每项只请求一次、重定向目标未收到请求、设置的测试 cookie 未被后续请求携带，并实际观察两种取消对应的套接字关闭。

第二批增加 DeepL 和 Azure 完整 JSON 的实际传输，共 13 个场景；从正式工厂路由，核对专用路径、请求格式和认证头，虚构 Key 不进入 URL。专用错误码、语言映射、大小边界和异常响应另由 XCTest 夹具覆盖。

第三批扩为 22 个场景，增加 Claude 原生 SSE/JSON/缺结束事件，Qwen-MT Flash 和 Google Basic 完整 JSON；分别核对版本/密钥头、独立系统指令、单条原文、专用语言字段以及 Google 完整操作 URL。取消覆盖 Chat、Claude 和专用 JSON 三条传输路径的头前/正文中六种场景，均由服务端核对 socket 关闭。

腾讯加入后为 24 个场景，增加专用完整 JSON 与 length 截断拒绝；从正式工厂核对根地址拼 `/v1/api/translations`、Bearer、固定模型、单条原文及源语自动时省略 source，不接受聊天提示词或自动继续请求。

这些结果证明本机正式网络栈和受控协议交互，不代表任何厂商账户、HTTPS 证书、付费额度、正式 App 的系统网络限制或真实翻译质量通过验收。

## 工程与本地化资源检查

`ValidateProject.swift` 由 `Scripts/verify.sh` 自动编译执行，不进入产品或测试宿主。它核对 App 和 XCTest 的 Swift 源文件是否完整纳入工程，并核对中英文文案键、非空内容、格式占位符及 Debug/Release 产物与源码的一致性。`InfoPlist.strings` 的应用名和权限说明也检查键、非空值及产物一致性。此检查针对当前工程结构；调整工程组织方式时同步维护校验，不忽略失败。

## 屏幕裁剪构造样本

`ScreenFixture.swift` 是独立的原生测试窗口，供 TranslateX 的真实区域选择、ScreenCaptureKit 与 OCR 交互验证使用。它不嵌入产品，也不申请辅助功能或屏幕访问、不读取屏幕、用户文件或网络。

### 构建与检查

```sh
Scripts/build-screen-fixture.sh
```

构建产物为忽略目录下的 `.build/QA/ScreenFixture.app`。脚本使用本机 SDK、macOS 15 最低部署目标、Swift 6 严格检查及 ad-hoc Hardened Runtime 签名，不启动应用、不创建证书或公开分发。先退出旧测试窗口再重新构建。

1. 打开测试窗口，在 TranslateX 中主动开始截图。框选中央矩形内的 `A quiet window helps you focus.`。
2. 核对 OCR 原文恰好等于目标句，没有框外的 `EXCLUDE THIS LINE`，并检查真实译文。
3. 框选目标框内部文字上方的白色留白，检查无文字提示和重试入口。
4. 取消选区、重试、将完成结果转入主窗口，分别记录实际观察。
5. 有多个显示器时，用窗口内的按钮移动样本；分别检查 1×、2× 和跨屏场景，不能由单屏成功推断多屏成功。
6. 检查完按 ⌘Q 退出测试窗口，移除其临时置顶显示。

目标矩形为内容坐标 `(100, 260, 600, 100)` pt。底部标签实时显示其 AppKit 全局矩形、当前屏幕坐标和缩放比例，帮助核对取景位置；具体屏幕以当前标签为准。标题栏拖动被锁定，只通过明确的换屏按钮重新定位。窗口不会改变系统分辨率、排列或缩放。

窗口置于普通浮窗层并可跨 Space 显示，使构造内容不会被普通来源窗口遮住。TranslateX 选区覆盖层仍在其上方。这只能证明固定样本的裁剪/OCR 路径，不能充当前台应用焦点、实际 Chrome 取词、物理全局热键、像素级缩放或所有显示器兼容性的证据。浮窗何时被自动化工具重新激活、关闭也必须与用户真实交互区分。

结果只适用于实际执行的构造样例；其他系统、显示器和来源应用需分别检查。

## 取词与剪贴板来源样例

`Scripts/build-selection-fixture.sh` 构建 `.build/QA/SelectionFixture.app` 并自动执行六种样例契约检查。测试只使用命名剪贴板；不会启动交互窗口、请求权限、生成外部键盘事件或读其他 App。交互窗口通过原生 AppKit 的选区属性与 `copy:` 响应提供可控来源，默认没有后台剪贴板监控；准备后只延迟检查一次，也可按按钮检查。它在真实复制回调中写入构造内容，不尝试选择/激活 TranslateX。

场景涵盖直接 AX、复制兜底、空选区、受保护角色、复制不产生新内容，以及连续两次复制写入。直接路径和复制路径的原文分别带 AX/COPY 前缀，窗口记录收到的 Copy 次数（包括拒绝的 Copy），只显示剪贴板与构造标记的比对状态，不展示任意剪贴板正文。准备按钮等同一次用户明确复制构造标记；不备份、保存或自动恢复此前的用户剪贴板。

自身 `--self-test` 验证 getter、Copy 行为及命名剪贴板上的标记；这不证明系统焦点、远程 AX IPC 或实际 CGEvent 投递。交互检查时先确认工具为系统前台，再使用 TSX 的取词入口并核对预期来源标记与 Copy 次数。仅能点击后台控件的自动化不能证明来源已激活，不应继续向未知前台应用触发全局取词。

正式事务另有 `SelectionWorkflowTests`：可控系统响应与真实 `SelectionClipboard` actor/命名剪贴板结合，覆盖权限、空/安全选区、来源改变、发送前竞争、第一次轮询前多次写入、复制超时、取消期间 busy、恢复与正常退出等待。测试不读通用剪贴板，也不对外部应用发送事件。它们证明事务顺序，真实外部 IPC 与退出的组合仍单独注明范围。

属性契约依据：[Apple 选区文字接口](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/accessibilityselectedtext())。

## 语言能力与已有资源审计

运行 `Scripts/audit-language-resources.sh`，结果写入 `.build/QA/LanguageAudit/latest.json`。工具复用产品 `LanguageCatalog`，对系统当前返回的语言目录做一次有限的语言对扫描；随后只对六个固定构造样例中已安装的资源执行翻译，不调用下载/准备接口，不保存译文正文。没有资源的样例明确记为未运行；55 秒未完成会退出，不将半份结果计为通过。

扫描使用 macOS 15 可用的 `LanguageAvailability`。额外的已安装资源翻译探针只在 macOS 26+ 使用 `TranslationSession(installedSource:target:)`；macOS 15 上明确跳过此探针，产品本身仍使用原有 SwiftUI session 生命周期。此工具不能替代产品 UI、所有语言翻译质量或 macOS 15 真机验证。

依据：[Apple 语言能力检查](https://developer.apple.com/documentation/translation/languageavailability)。结果以每次运行生成的报告为准。


## 双材质原生视觉目录

`Scripts/prepare-visual-catalog.sh` 构建 `.build/NativeVisualReview/TranslateX Visual Review.app`，不启动或安装。构建前先退出旧视觉目录实例。它直接编译正式 UI、窗口控制器与偏好实现，仅替换 Apple translation host，并用固定原创句子构造状态，不能作为真实翻译通过证据。

启动后通过“场景”菜单检查主窗、空白、长文、浮窗、三页设置、两种权限说明、语言准备/识别/错误/取消/同语言/无文字、截图覆盖层、关于和最小尺寸；同一菜单切换材质与明暗。设置使用独立临时域，退出清理，不写用户的产品偏好。屏幕背景和选区均为构造内容；目录中的截图提示不调用屏幕捕获。

请勿用此目录授予系统权限或测试跨应用取词；真实翻译、焦点和系统访问另用签名 Release。截图存于忽略目录 `.build/MaterialReview`，不入库。原生单窗口截图可能将窗口后方内容合成为实色，不能据此测量实际桌面折射或宣称像素相似度。

视觉检查使用明确区分的诊断入口：

- **窗口内布局对照**：将同一个正式 `WindowSurface` 放到窗口内部构造背景上，仅检查边缘、排版和裁切。`behindWindow` 不采样这个窗口内的背景，不能用于通透度或光学效果验收。
- **桌面构造背景**：把独立构造背景窗口铺到所在屏幕，并将它与正式内容窗口临时置前，供系统截图核对窗口背后的真实合成。只改变 QA 窗口排列，不申请屏幕权限、不实现截屏接口。选取其他场景恢复窗口层级，退出关闭全部 QA 窗口。
- **主窗与设置 · 设置激活 / 翻译激活**：在同一个独立背景上并排展示正式主窗和设置，分别让其中一个成为真实 key window；核对两者在切换前后均保持背景透色与细节。此入口不伪造窗口激活状态。
- **设计构造背景 / 彩色条纹背景 / 浅色桌面背景 / 深色桌面背景**：仅替换独立 QA 背景窗口。条纹和斜线用于辨认真实透色与折射；接近白、黑的背景用于检查明暗外观的文字对比度。不能只在柔和壁纸上验收，也不能要求原生玻璃失焦前后的模糊程度完全相同。

运行 `Scripts/verify.sh` 时暂停界面自动化；浮窗测试保留正式的外部点击关闭机制，其他程序的点击会干扰可见性断言。

该脚本给 XCTest 专用宿主使用 `com.lumax.tsx.TestHost`，测试 bundle 仍为 `.Tests`，以免系统激活正在运行的产品 App。官网 Debug/Release 身份不变且仍按实际产物严格核对。单独运行窗口 XCTest 时也要传入 `TRANSLATEX_APP_BUNDLE_IDENTIFIER=com.lumax.tsx.TestHost`；不通过关闭用户 App 或伪造 key window 规避碰撞。

视觉目录只包含构造翻译状态，不作为真实翻译证据。

### 更新弹窗与窗口焦点

视觉目录支持 `main-update-entry`、`main-update-modal` 和 `main-update-modal-minimum` 场景，使用正式主窗口与隔离更新器展示入口、弹窗和最小窗口布局，不联网下载或安装。通过 `CaptureTranslationServiceReview.py` 的 `--review-scene`、`--review-interface-language` 和 `--review-theme` 参数选择场景、语言与主题，截图保留在忽略目录。

紧凑更新界面另提供 `main-update-modal-compact`、`release-notes-compact`、`release-notes-recent-compact` 和 `release-notes-settings-compact`，覆盖发现更新、更新完成、主窗口历史和设置内历史；主窗口场景可追加 `-minimum`。这些场景使用双语构造说明与相对发布时间，包含应被隐藏的安装说明，沿用生产视图、全局滚动样式及隔离更新器；点击立即更新只模拟进度，不下载、安装或退出真实产品。

真实普通窗口的键窗口切换使用独立启动的 QA 应用核查；XCTest 宿主可能无法激活应用，不能把非激活宿主的结果当作用户窗口行为，也不能伪造 `isKeyWindow`。完成视觉目录构建后运行：

```sh
open -n -W '.build/NativeVisualReview/TranslateX Visual Review.app' \
  --args --translation-services-review --review-update-focus \
  --review-output "$PWD/.build/QA/UpdateFocus"
```

该入口核对真实主窗 → 设置确认 → 主窗更新弹窗的键窗口切换、延迟确认、重复请求、原生编辑器禁用与恢复，以及构造草稿保留。结果写入 `focus-results.json`，失败返回非零退出码，结束关闭 QA 窗口并清理临时偏好。检查期间会激活 QA 应用并拦截其窗口内输入，勿与 XCTest 或其他界面自动化同时运行；此检查不证明正式版本间的安装替换或重启链路。

## 真实本地模型固定样例

已准备好本机 Ollama 服务及模型后，显式选择地址与模型：

```sh
python3 Tools/QA/local-model-translation.py http://127.0.0.1:11434/v1 qwen2.5:0.5b
```

示例模型只用于说明参数，不代表推荐其翻译质量。入口只接受 `127.0.0.1` 或 `[::1]` 的 HTTP `/v1` 基础地址，不接受凭据、查询参数或外部域名；不会安装、启动、发现模型或读取用户配置、Keychain 和环境密钥。回环地址仍可能由服务转发到云端，离线验收必须另行固定本地模型并验证服务的网络边界。

脚本用 Swift 6 严格并发及 warnings-as-errors 编译实际生产 Provider/URLSession/解析器，顺序发送七组构造样例，覆盖中英、繁体、段落与数字、Markdown/代码、混合语言及指令作为原文。每组 60 秒触发取消并等待请求收尾，探针进程总上限 450 秒，无自动重试。编译依赖读取网络夹具脚本中的静态源码列表，不执行该脚本。

每次创建独立 `.build/QA/LocalModelTranslation/run-*` 目录，保存构建日志、逐行完整样例与译文、耗时/首次片段/片段次数、固定错误码和汇总；不记录原始服务错误正文。退出码 0 仅代表七次协议均完整完成，**不等于译文质量合格**。质量必须对照原文逐项人工审阅，结果写入验证记录；失败、超时和部分报告保留，不能挑选成功运行覆盖失败。该命令不证明产品 UI、GPU 性能、其他模型、厂商账号或所有语言已通过。
