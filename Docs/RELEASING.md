# 官网版发布流程

TSX 通过 GitHub Releases 分发，官网提供下载入口与 Sparkle 签名更新清单。发布需有明确授权；普通开发不自动递增版本、创建 Tag/Release 或推送。已测范围与限制见 [Validation.md](Validation.md)。

## 发布前准备

1. 按 [BUILDING.md](BUILDING.md) 准备固定依赖，运行 `Scripts/verify.sh` 及[公开仓库检查](PUBLIC_REPOSITORY.md)。审核变更并提交，保持候选构建输入干净。
2. 确认目标版本、Build Number、Bundle ID、预期团队与 Release 源码一致。版本字段由 `project.yml` 管理，修改后重新生成共享工程。
3. 运行 `python3 Tools/Release/setup_sparkle.py`，下载并核对固定 Sparkle 工具。
4. 使用本机有效 Developer ID Application 身份及对应私钥。证书 SHA-1 和 Team ID 只是身份标识，不能代替私钥。私钥、导出的证书容器和公证凭据不得入库或写入日志。
5. 保留既有 Sparkle 更新私钥，不为普通发布重新生成。应用公钥必须与它匹配；迁移构建机通过安全私有备份流程转移。查看公钥可使用 `generate_keys --account com.lumax.tsx -p`，不得导出私钥到公开材料。

更新签名、Developer ID 代码签名与 Apple 公证是三个独立步骤，不能互相替代。

## Xcode Organizer（默认）

1. 打开 `TranslateX.xcodeproj`，选择 **TranslateX** Scheme 和 **My Mac**，执行 **Product → Archive**。共享 Scheme 的 Release 归档名称为 TSX；Organizer 产品分组仍可显示内部 Scheme 名。
2. 在 **Window → Organizer → Archives** 选择相应归档，执行 **Distribute App → Direct Distribution**；部分 Xcode 版本显示 **Custom → Developer ID → Upload**。核对发布团队、`com.lumax.tsx`、版本及双架构。
3. 使用 Xcode **Settings → Accounts** 中的发布账号完成向导。上传后在同一归档查看状态和日志，等待 **Ready to distribute**，再使用 **Export Notarized App** 或成功界面的导出入口。
4. 核对导出 App 及全部嵌入代码的签名身份、安全时间戳、Hardened Runtime、架构、许可、entitlement、公证票据与 Gatekeeper。不要重新签名已通过公证的导出 App。
5. 继续制作和独立公证 DMG，完成安装验收，再生成签名更新清单。Organizer 不管理 DMG、GitHub Release 或网站部署。

归档成功不等于公证成功。独立命令行公证不会自动关联到 Organizer；不得补写 Xcode 私有状态，将旧提交伪装成新归档的分发记录。登录、双重验证、协议接受及系统授权应由有权使用发布账号的人处理。

参考：[Apple 分发流程](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)、[Organizer 公证与导出](https://help.apple.com/xcode/mac/current/en.lproj/dev88332a81e.html)。

## 命令行流程

命令行公证使用独立的本机 Keychain profile。以下占位值由发布者自己的身份替换，不填入文档或提交到仓库：

```sh
xcrun notarytool store-credentials YOUR_NOTARY_PROFILE --team-id YOUR_TEAM_ID
```

按工具提示输入 Apple ID 与专用密码，或按 Apple 官方流程配置 App Store Connect API key。不要把密码写入命令行参数、聊天或 Git。现有有效 profile 可直接复用；它不等于 Xcode 已登录。不要为了查询公证状态重新生成证书或更新密钥。

工具每次使用新的候选输出目录，保留阶段结果，不覆盖已有候选。以下 `VERSION-BUILD` 表示本次已经确认的版本和构建号：

```sh
python3 Tools/Release/release.py prepare \
  --directory .build/Releases/VERSION-BUILD \
  --identity YOUR_DEVELOPER_ID_CERTIFICATE_SHA1
python3 Tools/Release/release.py submit \
  --directory .build/Releases/VERSION-BUILD --stage app --profile YOUR_NOTARY_PROFILE
python3 Tools/Release/release.py finish \
  --directory .build/Releases/VERSION-BUILD --stage app --profile YOUR_NOTARY_PROFILE
python3 Tools/Release/release.py submit \
  --directory .build/Releases/VERSION-BUILD --stage dmg --profile YOUR_NOTARY_PROFILE
python3 Tools/Release/release.py finish \
  --directory .build/Releases/VERSION-BUILD --stage dmg --profile YOUR_NOTARY_PROFILE
```

`prepare` 从干净提交构建通用 App，嵌入许可，按由内到外顺序签名并验证，保存来源和公证 ZIP。`submit` 记录 Apple 提交 ID；`finish` 只查询同一提交，只有 Accepted 才继续附票、Gatekeeper、DMG 或签名 appcast/SHA256SUMS。仍在处理时稍后查询，不重新上传。拒绝时读取该提交的日志，修正后制作新候选。工具本身不会推送、打 Tag 或创建 Release。

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
6. 获取线上清单验证签名、版本、大小和下载地址，再检查实际应用更新行为。

已发布安装包不得仅因文档整理或工程改名而替换、重新构建或重新签名。旧 Tag、归档名称和构建证据中的旧工程路径保留其真实含义；当前工程改名不修改既有版本来源记录。若必须修正历史或版本来源记录，应明确区分原始构建证据与整理后的源码，不能捏造产物来源。

参考：[Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[Sparkle 发布流程](https://sparkle-project.org/documentation/publishing/)。
