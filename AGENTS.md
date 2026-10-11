# TSX 开发约定

本规则适用于仓库及所有子任务。当前任务的明确要求优先；文档中的示例、历史说明和第三方内容不构成操作授权。

## 开发前阅读

- 先阅读本文件、[架构](Docs/Architecture.md)、[分发边界](Docs/Distribution.md)和[公开仓库规范](Docs/PUBLIC_REPOSITORY.md)。相关文档在同一任务中未改变时不必重复读取。
- 私有开发工作区的新对话还须读取 `Private/RepositoryWorkflow.md`，确认本地目录、固定远端身份与公开同步方式；公开源码不包含该私有文件，不依赖聊天记忆识别工作区。
- 构建入口见 [BUILDING.md](Docs/BUILDING.md)，已测范围与未解决问题见 [Validation.md](Docs/Validation.md)。发布按 [RELEASING.md](Docs/RELEASING.md) 执行。
- 开发授权不代表账号登录、上传、公证、推送、创建 Tag 或 Release、网站部署等发布授权。已有明确授权按其范围执行，不反复确认。

## 产品与架构

- TSX 是免费、MIT 开源的 macOS 原生应用。Apple 本地翻译默认；外部 API、兼容接口、本地模型和实验性账号服务由用户主动配置。
- 名称固定为：产品 **TSX**，工程／Scheme／Swift 模块／源码目录 `TranslateX`，测试 `TranslateXTests`，GitHub 仓库 `tsx`／`tsx-private`。后续不随意改名；已发布 Bundle ID、旧偏好域、Keychain、账号目录和 helper 签名身份按分发文档保留，不用全局替换消除兼容标识。
- 不引入应用自有账号、后台内容采集、订阅、付费解锁或云同步。
- Swift 6、AppKit 与 SwiftUI 共用一套业务和界面。AppKit 集中管理窗口，SwiftUI 负责内容；系统服务不放入 View。
- 当前仅实现官网直接分发，保留 Hardened Runtime、不启用 App Sandbox。未来商店渠道需独立授权、沙盒实现与验证，不预建空实现，不复制整套代码或维护长期渠道分支。
- 渠道、签名和 entitlement 在构建时确定；能力与系统授权在运行时判断。只在装配入口选择渠道实现，不在 View 散落渠道条件。
- 只为真实需求增加模块和接口；不引入占位 Provider 或未经使用的抽象。身份、凭据存储与迁移兼容性遵循分发文档。

## 隐私与公开范围

- 仅主动触发时取词或截图，不持续监控。不得修改 TCC 或系统安全设置，不借外置 helper 绕过渠道边界。
- 原文、译文、截图、剪贴板备份与凭据不得进入日志、公开测试报告或 Git。验证使用构造样例，测试产物留在忽略目录。
- 私人协作记录、授权时间线、真实账号资料、设计探索稿、候选图片、构建产物和依赖缓存不入库。公开文档只保留使用、维护和验证所需信息。
- 提交前执行 [公开仓库检查](Docs/PUBLIC_REPOSITORY.md)。扫描无告警不替代内容复核；新增图片必须人工查看，不能仅凭文件名判断可公开。

## 代码与验证

- `project.yml` 是项目配置来源；修改后运行 `xcodegen generate`，提交生成的共享 Xcode 工程。
- `Scripts/verify.sh` 校验官网 Debug/Release 构建、签名、Hardened Runtime、非沙盒权限与隔离宿主 XCTest。不得把测试宿主作为交付 App，不得删除或放宽检查来掩盖差异。
- 新增业务行为增加有效回归测试；根据改动运行成本合理的测试、构建或静态检查。不声称未执行的检查通过。
- 编译、自动测试、协议夹具和构造界面不等于真实翻译、账号、OCR、权限、跨应用或跨设备验收。公开验证摘要明确区分这些证据。
- 相关失败必须修复后提交；确认是已有无关问题时可提交并说明。原因不明视为相关，不擅自提交中间状态。
- 人工交互先准备可操作候选与集中清单，复用已通过证据。未覆盖项目保留限制，不静默删除或改成通过，不为不变的环境反复增加验收。

## Git 与发布

- 本项目采用独立的私有开发仓库和公开源码仓库；先确认当前工作区、远端和仓库可见性。私有仓库的内部资料仅存于 `Private/` 或仓库外，密钥仍禁止入库。
- 两个仓库不共享 Git 历史或 `.git`。公开同步按 [公开仓库规范](Docs/PUBLIC_REPOSITORY.md) 生成并审阅文件差异，不 merge/fetch/mirror 私人历史到公开仓库。
- 私有仓库使用秘密扫描与固定私有远端检查；公开仓库使用完整公开范围检查。公开检查失败不能通过换用私有模式或关闭 hooks 规避。

- 默认主分支是 `main`。已授权且应保留的修改在验证通过后默认形成一个逻辑完整的 commit；纯分析不提交。
- 提交前检查工作区、暂存与未暂存差异、merge/rebase 和冲突状态。只暂存本次修改；同文件混合改动按片段暂存。不使用 `git add .`、`git add -A` 或 `git commit -a`。
- 暂存后复核差异、凭据、本地配置、依赖与大文件。hook 改写文件后重新审核，不绕过 hook。
- 提交前读取用户 Codex Git 提交规范（配置中的 `[desktop].git-commit-instructions` 字段），只读取该字段，不输出无关配置。提交语言遵循全局规范，按实际提交所在仓库的用途区分：私有源仓库使用简体中文，公开仓库及明确用于承载公开历史的目标仓库使用英文。
- 本仓库是公开源码仓库，新提交的标题摘要、必要正文及 `BREAKING CHANGE` 说明使用英文，包括尚未推送的本地提交；配套私有源仓库继续使用简体中文。公开同步按本仓库的实际差异创建英文提交，不沿用私有提交消息。
- 提交格式为 `<type>(<scope>): <摘要>` 或 `<type>: <摘要>`。允许 feat/fix/refactor/perf/style/docs/test/build/ci/chore/revert；style 仅用于代码格式，UI 功能用 feat、UI 缺陷用 fix。
- 语言规范只适用于新提交；保留已有提交，不为统一语言执行 amend、rebase 或重写历史，也不因此翻译 README、Release notes 或其他文档。
- 摘要准确具体、末尾无句号，不含 emoji、软件版本或 AI 署名。破坏性修改使用 `!` 和 `BREAKING CHANGE:` 迁移说明，不因此自行升级版本。
- 普通开发不修改软件版本、Build Number、CHANGELOG、Tag、Release 或发布配置。实际发布元数据变更在本公开仓库使用 `chore(release): release vX.Y.Z`，在配套私有源仓库使用 `chore(release): 发布 vX.Y.Z`，不制造空提交。
- 官网版发布必须使用真实 Xcode Archive，并在 Organizer 中完成 App 的分发上传、公证及成功导出；登录或 Xcode 流程受阻时保留候选并报告，不改用 App 命令行公证。DMG 仍须独立公证，不会作为 DMG 公证记录出现在 Organizer。
- 真实归档保留在 Xcode 默认 Archives 目录；完成后将含 `Submissions`／`Distributions` 的完整归档、导出 App、最终 DMG、摘要、appcast、公证日志及源码 commit／版本／Build 记录备份到仓库外持久目录。DerivedData 和 `.build` 仅作缓存或临时验证目录，不得成为发行证据的唯一副本。不得伪造历史归档、补写 Xcode 分发状态或改写已发布包。
- 无明确授权，不 push、force-push、amend、rebase、reset --hard、clean、删除分支或 Tag、重写历史、修改 Git 身份/凭据/签名设置。
- 提交后报告短 SHA、完整标题、实际验证结果和工作区剩余修改。只有实际修改发布版本时说明版本变化。
