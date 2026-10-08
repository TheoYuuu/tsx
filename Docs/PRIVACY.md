# 隐私与数据说明

[返回首页](../README.md) · [English](#english)

本说明描述 TSX 1.0.0 的数据行为。后续版本的数据行为变化会同步更新到相应说明。

## 本机处理

- 默认通过 Apple 系统翻译能力处理文字；支持的语言及所需资源由系统提供，首次准备语言包可能需要联网。
- 截图文字识别在本机完成。截图保存在运行内存中，不作为翻译请求上传，也不由 TSX 保存到磁盘。
- TSX 不把翻译正文和译文保存为磁盘历史，也不将它们写入应用诊断日志。退出应用后不会恢复这些内容。
- 偏好设置、服务地址、模型选择及服务测试的时间与结果状态会保存在本机。测试状态记录不包含翻译正文或完整响应。
- API 密钥使用 macOS 钥匙串保存。可选账号登录使用独立的本机凭据存储；退出应用与退出账号是不同操作。
- 应用仅在本机记录最近 30 天、最多 10,000 条翻译及样例请求的时间、模型、结果状态、耗时和服务返回的用量数字，可在设置中关闭或清空；不记录正文、截图、请求地址、完整错误或凭据，不上报给开发者。TSX 没有开发者运营的翻译中转服务。取词诊断可能在本机记录操作阶段、方式及错误码，不记录选区正文、剪贴板正文或截图。

## 外部服务与联网

选择外部翻译服务后，TSX 会向你配置或选择的服务发送待翻译文字、语言及必要的请求参数；账号功能还会与相应服务进行登录、账号状态和模型查询。截图翻译向翻译服务发送识别出的文字，而非原始截图。

第三方服务对请求的保留、处理及计费遵循其自身政策。启用自动互译后，编辑停顿也可能触发请求。请在提交敏感文字前确认所选服务；本地地址或本地模型名称不保证服务不会进一步连接外部网络。

## 应用更新

通过 Sparkle 检查更新，更新信息来自 `https://lumaxspace.com/updates/tsx/appcast.xml`，安装包通过 GitHub 下载。自动检查及自动下载默认关闭，可在设置中开启；自动检查通常每天一次。请求会向网站及下载托管服务提供 IP 地址、应用版本等常规连接信息，不包含翻译正文、截图、服务凭据或本机用量记录。未开启 Sparkle 系统信息采集。更新信息和安装包分别验证更新签名，正式安装包还需通过 Apple 签名及公证验证。

## 权限与剪贴板

辅助功能用于主动触发的取词，屏幕录制用于主动触发的区域截图。应用不会因拥有这些权限而持续采集屏幕或监控选区。

部分来源应用需要通过复制取得选中文字，可能短暂使用剪贴板；TSX 会在条件允许时恢复此前内容，并避免覆盖期间新复制的内容。主动点击复制会将结果放入系统剪贴板。

## 公开反馈与下载页面

本仓库的 Issues 是公开的。请勿提交 API Key、登录令牌、私人原文或未经遮挡的私人截图。使用 GitHub 浏览、下载或反馈时，还适用 GitHub 自身的数据处理政策。

# English

[Back to overview](../README.en.md)

This notice describes data behavior in TSX 1.0.0. Changes to data behavior will be reflected in the relevant release documentation.

## Processing on your Mac

- Apple system translation is the default. Supported languages and resources depend on the system; preparing language resources may require an internet connection.
- Screenshot text recognition runs on your Mac. Images stay in runtime memory, are not uploaded as translation requests, and are not saved to disk by TSX.
- TSX does not save translation text or results as disk history or include them in application diagnostic logs. They are not restored after quitting.
- Preferences, service endpoints, model selections, and service-test timestamps and status are stored locally. Test status records do not include translation text or full responses.
- API keys are stored in macOS Keychain. Optional account sign-in uses separate local credential storage. Quitting the app does not sign you out of an account.
- TSX keeps local numeric usage records for up to 30 days and 10,000 translation or sample requests: time, model, result status, duration, and counts returned by the service. You can disable or clear these records in Settings. They exclude text, screenshots, request addresses, full errors, and credentials, and are not sent to the developer. TSX has no developer-operated translation relay. Local selection diagnostics may record operation stages, methods, and error codes, without selected text, clipboard text, or screenshots.

## External services and network requests

When you choose an external service, TSX sends the text to translate, languages, and necessary request parameters to that service. Account features also perform sign-in, account-status, and model queries. Screenshot translation sends recognized text to the translation service, not the original image.

Third-party retention, processing, and billing follow each service's own policies. Automatic translation may send requests after you pause editing. Check the selected service before entering sensitive text. A local address or model name does not guarantee that the service will not contact external systems.

## Software updates

Sparkle retrieves update information from `https://lumaxspace.com/updates/tsx/appcast.xml`; installers are downloaded from GitHub. Automatic checks and downloads are off by default and can be enabled in Settings. Automatic checks normally run daily. Hosting providers receive ordinary connection information, such as IP address and app version, but no translation text, screenshots, service credentials or local usage records. Sparkle system profiling is disabled. Update metadata and archives have update signatures; official installers also require Apple code signing and notarization.

## Permissions and clipboard

Accessibility is used for selected-text translation you initiate; Screen Recording is used for region captures you initiate. Having these permissions does not cause TSX to continuously collect screen content or monitor selections.

Some source apps require copying to retrieve selected text, which may temporarily use the clipboard. TSX attempts to restore previous content when appropriate and avoids overwriting content newly copied in the meantime. Choosing Copy places the result on the system clipboard.

## Public feedback and downloads

Issues in this repository are public. Do not submit API keys, login tokens, private text, or unredacted private screenshots. Browsing, downloading, and posting through GitHub are also subject to GitHub's own data policies.
