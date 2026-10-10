# 翻译服务厂商标识

应用使用 21 枚本地 SVG，来自 [Lobe Icons](https://github.com/lobehub/lobe-icons) 的 `@lobehub/icons-static-svg@1.95.1`，上游提交 `49a2130df7bfa5eb1b088261bff20a37e2967789`。没有安装 JavaScript 依赖，也不在运行时请求图片。源地址、原文件 SHA-256、服务映射及取回日期见 [sources.json](sources.json)；`Source/` 保留与固定版本上游逐字节一致的原文件。后续补充资源在各条目记录独立取回日期。

从仓库根目录运行 `python3 Tools/Assets/ProviderLogos/PrepareAssets.py` 可重建 Asset Catalog 中的 SVG。导出仅移除浏览器排版属性、明确 24 × 24 视口与默认黑色，并为压缩的弧线标志增加分隔空格，避免 CoreSVG 解析错误；Logo 形状、颜色与宽高比例保持原样。源文件校验及转换无需联网或第三方库。

| 服务 | Asset Catalog 标识 | 展示 |
| --- | --- | --- |
| OpenAI、Codex / ChatGPT | ProviderOpenAI | 花结 Logo，随界面明暗显示单色 |
| DeepSeek | ProviderDeepSeek | 蓝色鲸鱼 Logo |
| Ollama | ProviderOllama | 羊驼 Logo，随界面明暗显示单色 |
| DeepL | ProviderDeepL | 翻译对话 Logo，浅色藏蓝／深色浅灰 |
| Azure Translator | ProviderAzure | Azure 渐变蓝 Logo |
| Claude | ProviderClaude | 赤陶色星芒 Logo |
| Qwen-MT | ProviderQwen | 通义千问紫色 Logo |
| Google Cloud | ProviderGoogleCloud | Google Cloud 彩色云 Logo |
| 腾讯翻译 | ProviderTencentCloud | 腾讯云蓝色云 Logo |
| Kimi | ProviderKimi | 单色 K 标志，随界面明暗显示 |
| GLM | ProviderGLM | 智谱蓝紫色圆点 Logo |
| Gemini | ProviderGemini | 彩色星芒 Logo |
| SiliconFlow | ProviderSiliconFlow | SiliconCloud 紫色 Logo |
| OpenRouter | ProviderOpenRouter | 单色 Logo，随界面明暗显示 |
| Xiaomi MiMo | ProviderXiaomiMiMo | 单色字标，随界面明暗显示 |
| New API | ProviderNewAPI | 彩色环形星芒 Logo |
| MiniMax | ProviderMiniMax | 红粉渐变波形 Logo |
| Doubao | ProviderDoubao | 蓝紫绿色环形 Logo |
| Stepfun | ProviderStepfun | 蓝色阶跃 Logo |
| xAI | ProviderXAI | 单色字标，随界面明暗显示 |
| Mistral | ProviderMistral | 黄红像素 Logo |

自定义兼容接口默认采用系统 `network` 符号，服务预设使用相应品牌标识。用户可另选内置品牌或网络、云、服务器、芯片符号；图标仅是显示设置，不改变请求协议、地址或凭据。Apple 内置翻译复用 `MenuBarIcon` 模板。服务名称与“在本机完成翻译”说明继续表达其本地属性。

图片保留矢量及原始宽高比例；共用组件在服务列表和编辑页显示 32 pt 底座，服务商选择器使用 22 pt 底座，图标选择器使用 30 pt 底座，主窗口菜单使用 16 pt 图标。颜色 Logo 采用原色，单色 Logo 采用模板以适配深浅界面。Kimi 使用单色版本，避免上游彩色版本的白色主体在浅色背景消失。不要将品牌标识改为服务名称首字母，也不要根据用户重命名的配置推断品牌。

上游 MIT 版权与许可全文随应用资源打包到 `ProviderLogoNotices.txt`。各品牌名称与标识属于对应权利人，仅用于识别用户配置的服务。
