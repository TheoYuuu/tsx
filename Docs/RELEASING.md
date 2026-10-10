# 官网版发布流程

TSX 通过 GitHub Releases 分发，官网提供下载入口与 Sparkle 签名更新清单。发布需有明确授权；普通开发不自动递增版本、创建 Tag/Release 或推送。已测范围与限制见 [Validation.md](Validation.md)。

## 发布说明

- 首次公开发行介绍产品能力、系统要求、安装包选择及简明安装步骤，链接完整使用说明和许可证。后续发行以新增、改进和修复为主，末尾保留简短的「下载与验证」：本版本安装包、系统与架构要求、实际验证的签名／公证状态、校验文件及[安装指南](USAGE.md)。不重复整套安装教程。
- 系统要求、数据兼容或升级方式变化时，单独突出「升级前须知」和必要操作；中英文事实保持一致。已知限制见验证与使用文档，影响本次升级的重要限制仍需明确说明。
- 应用内弹窗仅展示版本、发布时间、更新内容和必要升级提醒，不展示常规安装附录。随包说明在构建时尚无真实发布时间，可留空；线上说明使用 Release 的真实发布时间，不填入构建或安装时间。已发布版本的离线记录应与公开元数据一致。
- `SHA256SUMS.txt` 可以公开，仅包含最终安装包的文件名和摘要，在签名、打包和附票全部完成后生成。校验值用于核对文件完整性，不替代签名、公证或来源验证。不得将凭据、私人路径或原始公证日志放入公开说明。

## 发布前准备

1. 按 [BUILDING.md](BUILDING.md) 准备固定依赖，运行 `Scripts/verify.sh` 及[公开仓库检查](PUBLIC_REPOSITORY.md)。审核变更并提交，保持候选构建输入干净。
2. 确认目标版本、Build Number、Bundle ID、预期团队与 Release 源码一致。版本字段由 `project.yml` 管理，修改后重新生成共享工程。
3. 运行 `python3 Tools/Release/setup_sparkle.py`，下载并核对固定 Sparkle 工具。
4. 使用本机有效 Developer ID Application 身份及对应私钥。证书 SHA-1 和 Team ID 只是身份标识，不能代替私钥。私钥、导出的证书容器和公证凭据不得入库或写入日志。
5. 保留既有 Sparkle 更新私钥，不为普通发布重新生成。应用公钥必须与它匹配；迁移构建机通过安全私有备份流程转移。查看公钥可使用 `generate_keys --account com.lumax.tsx -p`，不得导出私钥到公开材料。

更新签名、Developer ID 代码签名与 Apple 公证是三个独立步骤，不能互相替代。

维护发布工具后运行 `python3 -m unittest discover -s Tools/Release -p 'test_*.py'`。这些测试使用构造归档并替代外部命令，不执行真实签名或上传，也不能替代实际 Organizer 分发和安装验收。

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

## 公开顺序

1. 核对候选来源、版本与最终源码，将已授权源码同步到 `main`，为实际候选来源创建版本 Tag。
2. 创建 GitHub Release，上传最终 DMG 与 SHA256SUMS，说明功能、系统要求、许可和重要使用限制。自动生成的源码归档不是安装包。
3. 重新下载附件并复核摘要、签名和公证票据。
4. 更新网站 `public/updates/tsx/appcast.xml`，保留必要旧版本条目；任何修改后重新签名。附件已可下载后才能公布更新条目。
5. 在获得网站推送授权后同步页面和下载链接，通过网站既有部署流程上线。
6. 获取线上清单的原始文件，验证签名、版本、大小和下载地址，再检查实际应用更新行为。将网站最终签名清单、重新下载的附件校验结果、公开源码／网站 commit 与实际验证记录补存到同一持久候选目录，保留候选清单和线上清单的区别。

已发布安装包不得仅因文档整理或工程改名而替换、重新构建或重新签名。旧 Tag、归档名称和构建证据中的旧工程路径保留其真实含义；当前工程改名不修改既有版本来源记录。若必须修正历史或版本来源记录，应明确区分原始构建证据与整理后的源码，不能捏造产物来源。

参考：[Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[Sparkle 发布流程](https://sparkle-project.org/documentation/publishing/)。
