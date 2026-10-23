# 官网版发布流程

当前源码采用 `updates.uuthings.com` 的 R2 更新清单与安装包，官网提供下载入口，GitHub Releases 可提供镜像。旧发行版的官网清单仍按原地址运行；完成源码接入不代表正式更新服务已经切换。发布需有明确授权；普通开发不自动递增版本、创建 Tag/Release 或推送。已测范围与限制见 [Validation.md](Validation.md)。

## 手动发布的完整顺序

手动发布是由维护者逐步执行下面的操作；可以使用仓库工具完成重复检查，无需手工重写签名和打包逻辑。只有 App 公证及导出必须在 Xcode Organizer 中操作。首次准备见 [BUILDING.md](BUILDING.md)，各阶段的命令和核对项目见本文后续章节。

1. **核对三个工作区。** 私有开发仓库、独立公开源码仓库和官网仓库分别检查 `git status`、`git remote -v`，再 `git fetch origin` 检查远端进展。确认没有未处理改动或冲突，两套应用仓库不能共用 Git 历史。只有本次发版涉及的文件进入提交；不得覆盖其他工作。
2. **在私有源码确定版本。** 在 `project.yml` 同时更新 `MARKETING_VERSION` 和递增的 `CURRENT_PROJECT_VERSION`，运行 `xcodegen generate`。在 `TranslateX/Resources/PublishedReleaseNotes.json` 开头加入本版中英文说明，当前尚未发布的版本不填写虚构发布时间；上一版时间可按正式更新清单的真实发布时间补齐。准备本版公开说明，描述用户可见的变化和必要升级提醒。
3. **验证并提交私有源码。** 运行 `Scripts/verify.sh`；发布工具变化时再运行本文的工具测试。完成本次界面及行为检查，记录真实覆盖范围。查看 `git diff`，按文件暂存，再检查 `git diff --cached` 和剩余差异，创建发布提交。通过私有历史和固定远端检查后执行 `git push origin main`。
4. **同步独立公开源码。** 按 [双仓文件同步](PUBLIC_REPOSITORY.md#双仓库文件同步) 在公开工作区对上一步的准确 commit 生成导出预览，审阅后带 `--expect-plan` 应用。README、Docs、AGENTS 和策略属于公开仓库独立维护内容，逐项检查跳过项并同步适用的说明。检查真实暂存区，必要时执行策略差异审核；运行公开 `staged` 检查、相关构建验证并提交，再运行 `history main` 和 `git push origin main`。记录两边 commit 对应关系，记录只保存在私有归档中。
5. **从干净的公开提交归档。** 在公开源码根目录运行 `python3 Tools/Release/release.py archive`。保存工具输出的候选目录和 `.xcarchive` 路径；后续所有命令使用同一个候选目录。真实归档保留在 Xcode 默认 Archives 目录，候选长期保存在仓库外。不能拿 Debug/TestHost 或普通 Release 构建目录冒充发行归档。
6. **在 Xcode 公证并导出 App。** 打开 **Window → Organizer → Archives**，选择本版、对应 Build 的归档，执行 **Distribute App → Direct Distribution**；旧界面可能为 **Custom → Developer ID → Upload**。沿用有效的签名身份，核对后上传；等待 **Ready to distribute**，再点击 **Export Notarized App**，导出到本次候选的 `XcodeExport/`。只查询同一上传，不因等待而重复提交；登录或协议问题由账号持有人处理。
7. **制作并公证 DMG。** 使用本文的 `prepare → submit --stage dmg → status → finish` 命令。`prepare` 核验导出 App、备份完整归档并制作签名 DMG；`submit` 上传容器；`status` 查询同一提交；状态为 Accepted 后 `finish` 附票并生成 `artifacts/`。只发布 `artifacts/` 内的最终 DMG 和 SHA256SUMS，不使用候选根目录中提交公证的原始 DMG，也不重新签名导出的 App。
8. **验证最终产物。** 核对 `release.json`、`verification.json`、App／DMG 公证记录、归档备份与最终摘要。挂载最终 DMG 检查 App，执行适用的安装和升级测试；需要保留旧版时不覆盖日常应用，并明确记录未执行真实替换。使用 `shasum -a 256 -c SHA256SUMS.txt` 时先进入 `artifacts/`。保留失败与未测项，不将模拟更新当成真实升级通过。
9. **在 QA 通道验证同一最终包。** 按下方 R2 工具流程准备并上传 `qa/appcast.xml` 和独立批次目录中的 DMG。使用独立 macOS 测试账号或 VM，旧版安装在该账号自己的 `~/Applications`，不使用共享的 `/Applications`。先保存原来的 `SUFeedURL` 偏好，再临时指向 QA；完整验证下载、验签、替换、重启，测试后恢复原值（原本没有才删除）。第一轮可用旧版到候选版测试，不必等下一次发行。系统朗读等未发布功能也要覆盖。
10. **正式授权后发布 R2。** 从同一最终 DMG 本地副本重新准备 stable；安装包不重建、不重签，路径改为 `releases/<版本>-<Build>/`，清单因地址和发布时间改变而重新生成并签名。先上传并核对安装包，再使用准备时读取的 ETag 条件更新 stable 清单。上传包必须 `PutObject + If-None-Match: *`，不以服务端 CopyObject 晋升候选，沿用已验证的本地副本条件上传。冲突必须停止重新审阅，不强行覆盖。
11. **同步下载入口并留档。** 首次切换时，按单独发布授权将 GitHub 的主要下载版本更新为内置新地址的版本，并同步官网的最小版本、下载与隐私说明。后续 GitHub 镜像是否同步可按项目需要决定。旧官网 appcast 是否桥接另行决定，不自动修改两个网站。公开 Tag 必须指向实际构建的公开源码。正式发布后清除 QA 覆盖，再用新版“检查更新”验证内置 stable 地址、验签和“已是最新”；把实际线上清单、回读摘要、上传回执、源码映射及安装证据归档。清理 QA 对象前保留证据；不删除长期发行档案。

下一次发版从第 1 步重新开始，使用新版本、新 Build 和新候选目录。有效的 Developer ID、Bundle ID、团队、Sparkle 密钥及 DMG 公证 profile 均沿用。Release、官网部署、App 公证和 DMG 公证是独立状态，不能用其中一个成功代替其余步骤。

## 发布说明

- 首次公开发行介绍产品能力、系统要求、安装包选择及简明安装步骤，链接完整使用说明和许可证。后续发行以新增、改进和修复为主，末尾保留简短的「下载与验证」：本版本安装包、系统与架构要求、实际验证的签名／公证状态、校验文件及[安装指南](USAGE.md)。不重复整套安装教程。
- 系统要求、数据兼容或升级方式变化时，单独突出「升级前须知」和必要操作；中英文事实保持一致。已知限制见验证与使用文档，影响本次升级的重要限制仍需明确说明。
- 应用内弹窗仅展示版本、发布时间、更新内容和必要升级提醒，不展示常规安装附录。随包说明在构建时尚无真实发布时间，可留空；线上说明使用正式清单的真实发布时间，不填入构建或安装时间。已发布版本的离线记录应与公开元数据一致。
- `SHA256SUMS.txt` 可以公开，仅包含最终安装包的文件名和摘要，在签名、打包和附票全部完成后生成。校验值用于核对文件完整性，不替代签名、公证或来源验证。不得将凭据、私人路径或原始公证日志放入公开说明。

## 发布前准备

1. 按 [BUILDING.md](BUILDING.md) 准备固定依赖，运行 `Scripts/verify.sh` 及[公开仓库检查](PUBLIC_REPOSITORY.md)。审核变更并提交，保持候选构建输入干净。
2. 确认目标版本、Build Number、Bundle ID、预期团队与 Release 源码一致。版本字段由 `project.yml` 管理，修改后重新生成共享工程。
3. 运行 `python3 Tools/Release/setup_sparkle.py`，下载并核对固定 Sparkle 工具。
4. 使用本机有效 Developer ID Application 身份及对应私钥。证书 SHA-1 和 Team ID 只是身份标识，不能代替私钥。私钥、导出的证书容器和公证凭据不得入库或写入日志。
5. 保留既有 Sparkle 更新私钥，不为普通发布重新生成。应用公钥必须与它匹配；迁移构建机通过安全私有备份流程转移。查看公钥可使用 `generate_keys --account com.lumax.tsx -p`，不得导出私钥到公开材料。

更新签名、Developer ID 代码签名与 Apple 公证是三个独立步骤，不能互相替代。

R2 发布工具要求 Python 3.10+，先在独立虚拟环境安装 `Tools/Release/requirements-r2.txt`；使用该环境运行 `python -m unittest discover -s Tools/Release -p 'test_*.py'`。这些测试使用构造归档并替代外部命令，不执行真实签名或上传，也不能替代实际 Organizer 分发和安装验收。

## Xcode Archive 与 Organizer 分发（强制）

官网版 App 必须由真实 Xcode Archive 进入 Organizer，使用 Xcode 上传公证并从成功记录导出。命令行可以创建真实归档、验证导出物及处理 DMG，不能替代 App 的 Xcode 分发公证。账号登录、双重验证、协议或 Xcode 错误阻碍流程时，保留当前候选、归档和日志，报告具体阻碍；不得自行改用 `notarytool` 提交 App、使用普通 Release build 代替归档，或以尚未公证的导出物继续发布。

使用发布工具创建归档：

```sh
python3 Tools/Release/release.py archive
```

工具默认创建仓库外的新持久候选目录，并将真实归档写入 Xcode 默认 Archives 的日期目录；也可用 `--directory` 指定一个新的仓库外持久目录。保存命令输出的两个路径，后续始终使用同一候选目录。`source.json`、`release.json` 和 `archive.log` 保留源码与构建证据；归档阶段结束于 `awaiting-xcode-distribution`，表示仍须完成下面的 Xcode 分发步骤，不代表已通过公证。

1. 核对工具从已确认的干净源码提交创建的真实 `.xcarchive`，它应位于 Xcode 默认 `~/Library/Developer/Xcode/Archives/` 的日期目录下。共享 Scheme 为 **TranslateX**，Release 归档名称为 TSX；Organizer 产品分组仍可显示内部 Scheme 名。核对归档的版本、Build、源码 commit 和双架构，不从缓存 App 拼装归档，也不另建归档替换本次候选的来源记录。
2. 在 **Window → Organizer → Archives** 选择相应归档，执行 **Distribute App → Direct Distribution**；部分 Xcode 版本显示 **Custom → Developer ID → Upload**。核对发布团队、`com.lumax.tsx`、版本及双架构。
3. 使用 Xcode **Settings → Accounts** 中的发布账号完成向导。上传后在同一归档查看状态和日志，等待 **Ready to distribute**，再使用 **Export Notarized App** 或成功界面的导出入口，将 App 导出到本次持久候选目录下单独的 `XcodeExport/` 子目录。候选根目录中的 `TSX.app` 和 `TSX.xcarchive` 留给工具创建已核验副本。仍在处理时查询同一归档；被拒绝时先保存并检查日志，修复后创建新候选，不覆盖原记录。
4. 核对导出 App 及全部嵌入代码的签名身份、安全时间戳、Hardened Runtime、架构、许可、entitlement、公证票据与 Gatekeeper。不要重新签名已通过公证的导出 App。
5. 备份完整归档，保留 Xcode 生成的 `Submissions`／`Distributions`、状态和分发日志，以及对应的成功导出 App。继续制作和独立公证 DMG，生成并验证签名更新清单，完成安装验收后再发布。Organizer 管理的是 App 归档与其分发记录；DMG 公证、GitHub Release 和网站部署须另外留档。

归档成功不等于公证成功，单独通过 App 票据验证也不能代替同一归档的 Xcode 成功分发记录。不得补写 Xcode 私有状态或伪造 `Submissions`／`Distributions`，将独立命令行公证伪装成 Organizer 分发。登录、双重验证、协议接受及系统授权应由有权使用发布账号的人处理。

参考：[Apple 分发流程](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)、[Organizer 公证与导出](https://help.apple.com/xcode/mac/current/en.lproj/dev88332a81e.html)。

## DMG 独立公证

DMG 公证使用独立的本机 Keychain profile。以下占位值由发布者自己的身份替换，不填入文档或提交到仓库：

```sh
xcrun notarytool store-credentials YOUR_NOTARY_PROFILE --team-id YOUR_TEAM_ID
```

按工具提示输入 Apple ID 与专用密码，或按 Apple 官方流程配置 App Store Connect API key。不要把密码写入命令行参数、聊天或 Git。现有有效 profile 可直接复用；它不等于 Xcode 已登录。不要为了查询公证状态重新生成证书或更新密钥。

工具每次使用新的仓库外持久候选目录，保留阶段结果，不覆盖已有候选。下面的路径占位符须替换成 `archive` 输出的同一候选目录及 Xcode 成功公证后导出的 App，保留引号以支持含空格的路径。App 必须是与成功分发记录一致的导出物，不能使用普通构建产物：

```sh
python3 Tools/Release/release.py prepare \
  --directory "/absolute/path/to/candidate" \
  --app "/absolute/path/to/candidate/XcodeExport/TSX.app" \
  --identity YOUR_DEVELOPER_ID_CERTIFICATE_SHA1
python3 Tools/Release/release.py submit \
  --directory "/absolute/path/to/candidate" --stage dmg --profile YOUR_NOTARY_PROFILE
python3 Tools/Release/release.py status \
  --directory "/absolute/path/to/candidate" --stage dmg --profile YOUR_NOTARY_PROFILE
python3 Tools/Release/release.py finish \
  --directory "/absolute/path/to/candidate" --stage dmg --profile YOUR_NOTARY_PROFILE
```

`prepare` 接收与本次归档成功分发记录相符的 Xcode 导出 App，验证并完整备份后保留其签名制作 DMG，不再构建或重新签名 App。`submit` 记录 DMG 的 Apple 提交 ID；`status` 查询同一提交并保存状态与可用日志；`finish` 在确认 Accepted 后继续附票、Gatekeeper 和签名 appcast／SHA256SUMS。仍在处理时稍后用 `status` 查询，不重新上传。拒绝时保存该提交日志，修正后制作新候选。App 的命令行提交和完成阶段不属于支持的发布路径。工具本身不会推送、打 Tag 或创建 Release。

提交给 Apple 的原始 DMG 保留在候选根目录。`finish` 在独立副本上附票，成功后把最终 DMG、appcast 和 SHA256SUMS 放入 `artifacts/`；发布时使用这里的文件。每次处理的日志保存在独立 `finish-*` 子目录，后续步骤失败可保留记录并重试 `finish`，不重新上传。

## 持久留档与查询

- Xcode 默认 Archives 目录中的真实归档必须保留，便于后续在 **Window → Organizer → Archives** 查询全部发行归档。按日期、版本和 Build 选择记录，核对 Developer ID 状态，并通过状态日志或 **Show in Finder** 检查对应归档。只保存 `.app`、DMG 或脚本日志，不能代替 Organizer 归档。
- 每次候选另建仓库外持久目录，保存源码 commit、仓库来源、版本、Build、构建工具版本、原始归档路径及各产物摘要。成功分发后备份完整 `.xcarchive`，包含 Xcode 实际产生的 `Submissions`／`Distributions` 及分发日志，同时保留成功导出的 App、最终 DMG、SHA256SUMS、签名 appcast、App 与 DMG 的公证状态和日志、安装与线上验证结果。
- 候选目录中的 `INDEX.md` 随阶段更新，汇总版本、Build、源码提交、Organizer 归档与持久副本位置、公证提交 ID、实际状态和查询方式。查看 App 分发记录使用 Organizer；查询 DMG 使用同一候选的 `status` 命令，不重新提交。
- 失败和未完成候选也保留真实状态，不能标记为成功或覆盖后重用。持久备份须验证可读取且产物摘要与发行文件一致；不得在副本完整性尚未确认时清理原始证据。默认持久根为 `~/Library/Application Support/TSX/ReleaseArchives/`，也可用 `--directory` 指定仓库外持久目录。`DerivedData`、`.build` 和临时下载目录仅用作缓存或临时验证，发行证据不得仅存于这些位置。构建产物、私人路径和账号资料不入 Git。
- 历史版本仅迁移已有真实材料。已有真实归档可原样恢复到 Xcode 默认 Archives 的对应日期目录，并验证 Organizer 可查询；保留其原始元数据和实际分发状态。没有真实归档的历史命令行发行记录为 `legacy-CLI`，保留原 App／DMG、摘要、公证日志和源码对应关系，不反向拼装归档、不伪造 Organizer 成功记录，也不替换或重新签名已发布安装包。

## 安装与更新验收

- 从最终 DMG 安装并首次启动，核对签名、公证、来源和文件完整性。仅在获得授权且所需正文已保存后替换正在使用的应用。
- 检查已有设置、服务配置、Keychain 访问及两项权限行为；系统是否要求重新授权由 macOS 决定，不修改 TCC。
- 检查手动更新、自动选项持久化、无新版本和错误反馈。真实跨版本升级另验退出收尾、替换及重启，不能由空清单或单次安装推断通过。
- 翻译正文和截图只在内存；更新前复制需要保留的内容，不为升级增加正文磁盘历史。
- 记录实际环境、失败和未覆盖范围。发布说明准确描述系统要求及影响使用的已知问题，不作未经验证的兼容承诺。

## R2 服务配置与发布工具

更新服务本身不需要 Worker 或单独 Git 仓库。域名和桶必须在同一个 Cloudflare 账号；仅连接 `updates.uuthings.com`，不改两个官网。不开启 r2.dev 公共地址。Cloudflare 的 R2 开通可能要求接受按用量计费条款，不能将免费额度当作永远免费。

```text
tsx/macos/stable/appcast.xml
tsx/macos/qa/appcast.xml
tsx/macos/qa/artifacts/<批次>/TSX-<版本>-macOS-universal.dmg
tsx/macos/qa/artifacts/<批次>/SHA256SUMS.txt
tsx/macos/releases/<版本>-<Build>/TSX-<版本>-macOS-universal.dmg
tsx/macos/releases/<版本>-<Build>/SHA256SUMS.txt
```

- 不可变锁仅覆盖 `tsx/macos/releases/`，使用 Indefinite；日常发布凭据不能管理锁，管理员可解除。不能锁住 `stable/` 或 `qa/`。
- stable XML 为 `no-cache`，整个 `qa/` 为 `no-store`，二者均通过 Cache Rule 绕过 CDN 缓存；正式包为 `public, max-age=31536000, immutable`。XML、DMG、摘要的类型分别为 `application/xml; charset=utf-8`、`application/x-apple-diskimage`、`text/plain; charset=utf-8`。
- 更新域名不能出现验证页、登录或验证码。Bot Fight Mode 保持关闭；若以后官网使用 Under Attack，须单独设计仅覆盖官网的规则，不能影响更新请求。发布工具核对当前约定，发现漂移停止。
- 第一个应用可用只限专用桶的 Object Read & Write 凭据；上线第二个应用或 CI 前增加前缀临时凭据隔离。日常发布不使用 Wrangler 的整个账号登录。配置核验使用独立只读令牌，所需权限为指定账号 R2 Read、指定 zone 的 Zone Read / Zone Settings Read / Cache Settings Read / Bot Management Read。创建时以 Cloudflare 控制台实际权限名称和只读 API 验证为准，不用管理员令牌兜底。
- 发布凭据、审计令牌存 Keychain；配置文件只记录账号、桶、zone 和 Keychain 引用，不包含秘密。通用路径/缓存/锁约定及真实云端配置另存私有运维档案，默认 `~/Library/Application Support/UUThings/UpdateService/`。

Cache Rule 使用下列表达式、动作 Bypass cache，放在可能覆盖它的缓存规则之后。工具会验证该规则是最后一条启用的缓存规则；有更多应用时先明确拓展规范与检查再调整。

```text
(http.host eq "updates.uuthings.com" and (starts_with(http.request.uri.path, "/tsx/macos/qa/") or http.request.uri.path eq "/tsx/macos/stable/appcast.xml"))
```

私有配置字段为 `account_id`、`zone_id`、`bucket`、`public_origin`（固定 `https://updates.uuthings.com`）、`publisher_keychain_service`、`audit_keychain_service`、`keychain_account`。发布 Keychain 项内容为包含 `access_key_id`、`secret_access_key` 和可选 `session_token` 的 JSON；审计项为只读 Cloudflare API token。工具仅在内存读取，不把秘密放进命令行、仓库或回执。

```sh
python3 -m venv .build/r2-venv
.build/r2-venv/bin/python -m pip install -r Tools/Release/requirements-r2.txt
.build/r2-venv/bin/python -m unittest discover -s Tools/Release -p 'test_*.py'

.build/r2-venv/bin/python Tools/Release/r2_updates.py --config /private/path/config.json prepare \
  --candidate /private/path/notarized-candidate --output /private/path/new-qa-plan \
  --channel qa --published-at 'YYYY-MM-DDTHH:MM:SSZ'
.build/r2-venv/bin/python Tools/Release/r2_updates.py --config /private/path/config.json upload \
  --directory /private/path/new-qa-plan
```

`prepare` 读取远端当前清单并验签，使用归档保存的随包说明生成双语 plain-text 描述，保留 Sparkle 生成的包签名与系统要求，写入新的签名清单和可审阅 `plan.json`，不上传。`upload` 核验当前配置、来源摘要和 ETag，按“包 → 摘要 → 清单”顺序上传，每步回读原始字节并检查公开响应头，保存回执。仅出现一次 MISS 不算失败；测试/可变文件出现 HIT 或陈旧缓存则停止。

正式发布必须另行获得授权；重新运行 `prepare --channel stable` 使用新的正式发布时间和同一包，再对已审阅的计划使用 `upload --confirm-production`。工具不创建 Tag、Release、不推送源码、不部署官网。任何已上传正式文件不得覆盖；修复候选使用新的 Build。

已发布安装包不得仅因文档整理或工程改名而替换、重新构建或重新签名。旧 Tag、归档名称和构建证据中的旧工程路径保留其真实含义；当前工程改名不修改既有版本来源记录。若必须修正历史或版本来源记录，应明确区分原始构建证据与整理后的源码，不能捏造产物来源。

参考：[Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[Sparkle 发布流程](https://sparkle-project.org/documentation/publishing/)。
