# 分发与系统边界

TSX 是免费、MIT 开源的 macOS 应用。源码与安装包位于 [GitHub](https://github.com/TheoYuuu/tsx)，官网 `lumaxspace.com` 提供产品信息、下载入口与签名更新清单。当前仅实现官网直接分发；商店渠道尚未实现或验收。

## 构建渠道

- 一套主要源码，共用翻译、编辑、OCR、窗口、菜单和设置。渠道在构建时选择，不是运行时偏好。
- 官网版不启用 App Sandbox，保留 Hardened Runtime；辅助功能与屏幕录制按实际用途申请。
- Debug/Release 与渠道是不同维度，两种模式都需验证签名、权限、资源与嵌入组件。
- 未来商店版必须独立实现和验证沙盒边界、取词、凭据访问、安装更新及审核要求。不得用官网结果推断兼容，不通过外置 helper 绕过商店边界。
- 不预建空商店实现、第二套 UI、购买或订阅逻辑。第三方翻译服务费用由服务商独立决定。

系统实现由应用入口装配；View 依据能力与授权展示操作，不散落渠道判断。只有实际出现渠道差异时才增加必要接口和构建配置，不复制项目或维护长期渠道分支。

## 主动取词与权限

1. 用户主动触发后固定来源应用，优先读取 AX 选区，再决定是否显示浮窗。
2. AX 不可用时，仅在授权、来源、松键状态和超时保护符合要求时受控复制。不把所有失败都变成注入按键。
3. 复制取得的新文本与已有剪贴板分开处理。备份只存在内存；恢复前检查竞争写入，不覆盖期间的新复制。
4. 取消、权限失效、来源变化、空选区和重复触发必须有明确结果。不得持续监控选区，不记录正文、截图或剪贴板内容。
5. 不修改 TCC、系统安全设置或系统音量，不广播释放所有按键来隐藏状态问题。

浏览器脚本和外部取词库不是默认依赖。新增依赖时审核许可、日志、副作用和并发，并独立取得目标应用的实际交互证据。

## 应用身份与存储兼容

| 项目 | 当前标识 |
| --- | --- |
| 应用/产物名称 | TSX / `TSX.app` |
| 主应用 Bundle ID | `com.lumax.tsx` |
| 测试宿主 / 测试 Bundle | `com.lumax.tsx.TestHost` / `com.lumax.tsx.Tests` |
| Xcode 工程、Scheme、Swift 模块与源码目录 | `TranslateX` |
| 测试目标与源码目录 | `TranslateXTests` |
| API Keychain service | `com.theoyuuu.LumaxTranslate.translation-api` |
| 账号 helper 标识 | `com.theoyuuu.LumaxTranslate.CodexRuntime` |
| 账号数据目录 | 用户 Application Support 下的 `com.theoyuuu.LumaxTranslate/CodexAccount` |
| 窗口位置 autosave key | `LumaxMainWindow` |

产品名固定为 TSX，工程内部名称固定为 TranslateX；GitHub 仓库路径 `tsx`／`tsx-private` 不随工程名改变。以上 `com.lumax.tsx` 和 `com.theoyuuu.LumaxTranslate` 系列标识经兼容审查保留，覆盖已发布应用身份、旧偏好域、Keychain、账号目录和 helper 签名标识；`LumaxMainWindow` 保留既有窗口位置。这些不是待清除的命名残留，不因工程名改变而机械重命名。正式入口通过 `LegacyPreferencesMigration` 向尚未配置的新偏好域导入旧域的已知键；新域已有设置时优先保留，旧域不删除。测试宿主不访问真实迁移域，迁移不读取秘密数据。

辅助功能、屏幕录制和 Keychain 访问由 macOS 决定是否重新授权。开发签名、正式签名和不同应用身份不能保证共享权限，也不能通过修改系统数据库迁移授权。未来双渠道并装需先明确身份、快捷键、设置、Keychain 和沙盒容器迁移，不随意新增 Bundle ID。

## 签名与更新

工程中的开发团队 ID 是公开身份标识，不包含证书私钥。发布需要本机可用的 Developer ID 身份及对应私钥；贡献者编译时不能把维护者团队设置理解为签名授权。验证脚本使用 ad-hoc 签名，其产物不是正式安装包。

正式主 App、helper 和嵌入代码使用预期 Developer ID、安全时间戳和 Hardened Runtime；不放宽运行时安全权限。发布检查仅对固定 Sparkle Autoupdate 组件允许其上游既定身份 entitlement，其他路径不能借此获得例外。

应用使用 Sparkle，更新清单固定为 `https://lumaxspace.com/updates/tsx/appcast.xml`，安装包来自 GitHub Releases。清单和安装包都需 Ed25519 验签；仓库与 App 保留公钥，更新私钥只在安全的私有存储中。更新密钥、公证凭据与 Developer ID 私钥是独立材料，不得互相替代。

完整流程见 [RELEASING.md](RELEASING.md)。上传成功、归档成功或安装包签名有效，都不能单独证明已通过公证、安装或真实跨版本升级。

## 验证与维护

渠道相关改动需同步 `project.yml`、生成工程、entitlement 和校验逻辑，明确预期而不是删除检查。至少覆盖适用的 Debug/Release、签名与权限、取词失败/取消、来源焦点、剪贴板竞争及安装更新路径。

当前证据和已知问题统一记录在 [Validation.md](Validation.md)。未经验证的系统、架构、来源应用和账号组合保留限制；不得宣称所有应用或所有设备兼容。公开文档与产物遵守 [公开仓库规范](PUBLIC_REPOSITORY.md)，发布操作需有对应授权。
