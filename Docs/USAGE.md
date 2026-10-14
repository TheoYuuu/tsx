# 使用说明

[返回首页](../README.md) · [English](#english)

本说明对应当前源码，正式安装包见 Releases。需要 macOS 15 或更新版本；从 [GitHub Releases](https://github.com/TheoYuuu/tsx/releases/latest) 下载 DMG，打开后将 TSX 拖入 Applications。

下载时选择 Release 附件中的 `TSX-版本-macOS-universal.dmg`，同时包含 Apple silicon 与 Intel 架构；自动生成的 Source code 归档不是安装包。如需核对完整性，将同一版本的 DMG 和 `SHA256SUMS.txt` 放在同一目录，在该目录运行 `shasum -a 256 -c SHA256SUMS.txt`。摘要匹配不替代系统的开发者签名与公证检查。

## 三种翻译入口

| 操作 | 默认快捷键 | 使用方式 |
| --- | --- | --- |
| 翻译选中文字 | Option + T | 在其他应用中选中文字，再按快捷键 |
| 打开翻译窗口 | Option + I | 输入或粘贴文字，也可继续当前运行期间最近的翻译 |
| 截图翻译 | Option + O | 拖动选择屏幕区域；按 Esc 取消 |

也可以从菜单栏访问这些入口。在设置中可以修改或停用快捷键；如果与其他应用冲突，请换用其他组合。已有用户的快捷键设置会保留，请以应用菜单或设置中显示的组合为准。

## 一个窗口继续翻译

输入和选中文字共用主窗口；截图结果可通过「在主窗口打开」进入同一工作区。横向和纵向布局分别保留尺寸。左上角红黄绿按钮右侧显示来源，例如应用名称、「截图」或「手动输入」。窗口失去焦点时仍然保留；快捷调用后按 Esc 可收起窗口，并返回仍在运行的来源应用。

成功取得选中文字，或主动把截图结果送入主窗口后，新内容会替换当前工作区。点击标题栏的「恢复上一条」，可以找回最近一次替换前的原文、译文、图片和语言选择；恢复不会自动重新发送翻译请求，未完成的翻译也不会自动继续。仅保留一条恢复内容，使用后即消耗，退出应用后不保留。取消框选或未获得所需权限时，当前内容不会被替换。

## 首次使用与权限

- 输入或粘贴翻译不需要辅助功能或屏幕录制权限。
- 取词会按需说明辅助功能权限的用途，并由你决定是否授权。部分应用不提供可读取的文字选区，可改用输入或截图翻译。
- 截图翻译需要屏幕录制权限，用于识别你框选区域内的文字。授权后重新触发截图即可尝试。
- Apple 翻译首次使用某些语言时，可能需要按系统提示下载语言包。
- 自动识别对孤立短词、名称和少量截图标签可能判断不准。出现不相关语言的下载提示时，取消提示并在源语言菜单手动选择实际语言，再翻译即可。

## 编辑与截图对照

普通翻译的两侧文字都可以编辑。开启自动互译后，输入停顿会更新另一侧；关闭后可手动触发翻译。使用收费或有额度限制的服务时，自动请求也可能消耗额度。

截图完成后，结果显示在所选区域附近，保持完整原图，并在对应文字位置生成译文；主窗口当前内容不受影响。开启所选服务的自动互译时，松开鼠标后自动翻译；关闭时点击「翻译」。工具栏可切换源语言与目标语言、交换语言、停止或重试、对照原图和查看全文。按 Esc 收起结果并返回来源应用；菜单、全文浮层或保存对话框打开时，Esc 优先关闭它们。

可复制原文、译文、原图或译图，也可分别保存原图和译图为 PNG。图片按原始像素尺寸导出，不包含工具栏。需要编辑识别文字或译文时，选择「更多 → 在主窗口打开」，再使用文字模式或原图模式。复杂表格、竖排文字和复杂背景可能影响识别或排版；过长或重叠区域保留原图并提供完整译文，原图排版不等于无痕修图或原字体重建。

## 翻译服务与内容保留

默认使用 Apple 本地翻译。可在设置中自行添加其他服务，再选择要使用的配置；账号资格、网络、额度和服务质量由相应服务决定。

API 服务使用自己的 API Key。选择预设厂商，或使用 New API／自定义服务填写兼容接口地址，再获取模型列表并选择模型；不提供手填模型入口，已有服务保留已保存模型。完整请求地址模式还需配置同源的模型列表地址；接口未提供可用目录时无法选择新模型。具体协议与厂商默认地址见[模型服务连接约定](ProviderAPIs.md)。添加或编辑时可更换厂商与图标；切换到新连接后需重新配置其凭据。

翻译正文和截图仅在当前运行期间保留，退出应用后不会恢复。需要保留的内容请先复制到自己的文档。具体数据行为见[隐私与数据说明](PRIVACY.md)。

## 用量统计

在「设置 → 用量统计」查看总成本、总请求数和消耗 Tokens，使用日期及服务筛选，并切换柱状图或热力图。下方「请求记录」按页展示近期请求，「定价」可刷新受支持官方模型的美元参考费率。成本属于估算，不能替代服务商账单；费用保留两位小数，不足一美分的非零成本显示为 `<$0.01`，悬停可查看完整值。Apple 本地翻译免费，不报告 Token 或 HTTP 状态码。

「翻译服务」中每个服务的「配置用量查询」可设置余额查询、自动查询间隔、超时与本机用量记录。这里只统计通过 TSX 发出的请求，不保存翻译内容；暂停不影响翻译和账户查询。近期明细最多保留 30 个自然日、10,000 条，更早或超额明细按天汇总，历史总量持续保留。清空统计需确认；删除服务也会删除其统计。

## 问题反馈

遇到问题时，请在 [Issues](https://github.com/TheoYuuu/tsx/issues/new/choose) 中提供软件版本、macOS 版本、芯片类型、操作步骤、预期结果与实际结果。用自行构造的短文本复现即可，不需要提供真实私人内容、API Key 或完整账号信息。

## 软件更新

可从 TSX 菜单或「设置 → 关于」手动检查更新和查看近期更新。关于页发现新版本后，点击「更新到 v…」即开始下载、安装和重启，进度在设置窗口展示，无需再次确认；主窗口的「发现新版本」入口可先查看更新说明，再点击「立即更新」。每次启动会检查新版本；自动更新默认关闭，仅提示可用版本。开启后将下载、安装并重启，升级后在主窗口展示一次更新内容。检查连接官网，下载与更新说明来自 GitHub。正文和截图不保存为历史，安装并重启前请复制需要保留的文字。

# English

[Back to overview](../README.en.md)

This guide covers the current source. Published installers require macOS 15 or later. Download the DMG from [GitHub Releases](https://github.com/TheoYuuu/tsx/releases/latest), open it, and drag TSX into Applications.

Choose the `TSX-version-macOS-universal.dmg` release asset for Apple silicon or Intel. Automatically generated source-code archives are not installers. To check integrity, place the DMG and `SHA256SUMS.txt` from the same release in one directory and run `shasum -a 256 -c SHA256SUMS.txt` there. Matching checksums do not replace system checks of developer signatures and notarization.

## Translation entry points

| Action | Default shortcut | How to use |
| --- | --- | --- |
| Translate selected text | Option + T | Select text in another app, then press the shortcut |
| Open translation window | Option + I | Type or paste text, or resume the most recent translation during the current session |
| Screenshot translation | Option + O | Drag to select a screen region; press Esc to cancel |

These actions are also available from the menu bar. Customize or disable shortcuts in Settings. Choose another combination if a shortcut conflicts with another app. Existing shortcut preferences are preserved; use the bindings shown in the app's menus or Settings.

## Continue in one window

Typed input and selected text share the main window. Choose Open in main window to bring a screenshot result into the same workspace. Side-by-side and stacked layouts remember their sizes separately. The source appears beside the traffic-light buttons at the upper left, such as an app name, Screenshot, or Typed input. The window stays open when it loses focus. After a shortcut opens it, press Esc to hide it and return to the source app if that app is still running.

Once selected text is captured, or you choose to open a screenshot result in the main window, the new content replaces the current workspace. Choose Restore previous translation in the title bar to recover the text, translation, image, and language choices from before the most recent replacement. Restoring does not resend a translation request or resume an unfinished translation. Only one previous workspace is kept, it is consumed when restored, and it is discarded when the app quits. Cancelling region selection or lacking permission leaves the current content unchanged.

## Getting started and permissions

- Typing or pasting text does not require Accessibility or Screen Recording permission.
- Selected-text translation explains and requests Accessibility permission when needed. Some apps do not expose readable selections; use input or screenshot translation instead.
- Screenshot translation requires Screen Recording permission to recognize text in the region you select. After granting access, start screenshot translation again.
- Apple translation may ask you to download language resources before first use.
- Automatic language detection can misidentify isolated words, names, and short screenshot labels. If an unrelated language download appears, cancel it, choose the correct source language, and translate again.

## Editing and screenshot comparison

Both sides of a regular translation are editable. With automatic translation enabled, pausing after an edit updates the other side. Turn it off to translate manually. Automatic requests may use a service's allowance or incur charges.

After capture, the result appears near the selected region, preserving the full original image and placing translations over the corresponding text. The current main-window content stays intact. With automatic translation enabled for the selected service, translation starts after you release the mouse; otherwise, click Translate. The toolbar lets you select or swap languages, stop or retry, compare the original, and read the full text. Esc dismisses the result and returns to the source app; open menus, the full-text popover, and save dialogs handle Esc first.

Copy the source text, translation, original image, or translated image, or save either image as PNG. Exports preserve the original pixel dimensions and exclude the toolbar. To edit recognized text or translations, choose More → Open in main window and use its text or image view. Complex tables, vertical text, and intricate backgrounds may affect recognition and layout. Regions with text that cannot fit or overlaps another region retain the original pixels and offer the full translation. Image layout does not provide seamless retouching or font reconstruction.

## Services and session content

Apple local translation is the default. Add other services in Settings and select the configuration you want to use. Account eligibility, connectivity, allowances, and translation quality depend on that service.

API services use your own API key. Choose a provider preset or configure a compatible endpoint through New API or Custom service, then fetch and select a model. Manual model entry is unavailable; existing services keep their saved models. Full request URL mode also requires a model-list URL on the same origin. An endpoint without a usable model directory cannot supply new model selections. See [provider connection details](ProviderAPIs.md). Providers and icons can be changed while adding or editing a service; a new connection requires its own credentials.

Translation text and screenshots remain available only during the current app session and are not restored after quitting. Copy anything you need to keep into your own document. See [Privacy and data](PRIVACY.md#english) for details.

## Usage statistics

Settings → Usage shows total cost, total requests, and consumed tokens. Filter by date or service, switch between bar charts and heatmaps, and page through recent request records. The Pricing tab refreshes USD reference rates for supported official models. Costs are estimates, not provider invoices. Costs use two decimal places; nonzero amounts below one cent appear as `<$0.01`; hover for the precise amount. Apple local translation is free and does not report tokens or HTTP status codes.

Use Configure usage query on a service row to manage balance querying, intervals, timeouts, and local usage recording. Only requests made through TSX are counted; translation text is not stored. Pausing keeps history and does not affect translation or balance queries. Recent details are kept for up to 30 calendar days and 10,000 requests, with older or excess metrics aggregated by day. Clearing statistics requires confirmation; deleting a service also removes its statistics.

## Reporting a problem

Open an [issue](https://github.com/TheoYuuu/tsx/issues/new/choose) with your TSX version, macOS version, chip type, steps, expected result, and actual result. Use a short synthetic example without private text, API keys, or complete account details.

## Software updates

Use Check for Updates in the TSX menu or Settings → About, where recent release notes are also available. Once a new version is found, clicking Update to v… on the About page starts downloading, installation, and restart without another confirmation; progress stays in Settings. The main window's New Version Available entry lets you read the release notes before clicking Update Now. Launch checks run without automatic downloads by default. Enabling automatic updates allows downloading, installation, and restart. After upgrading, release notes appear once in the main window. Checks use the website; downloads and release history use GitHub. Copy text you want to keep before installing and restarting; translation text and screenshots are not saved as history.
