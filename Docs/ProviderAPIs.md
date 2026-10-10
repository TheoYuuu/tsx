# 模型服务连接约定

品牌预设只提供名称、图标、官网和 API 地址，不内置可配置模型目录。可配置模型必须由用户主动获取后选择；目录不支持、拒绝请求或返回空列表时显示相应状态，不生成模型名、不切换主机，也不使用静态列表兜底。专用翻译接口 Qwen-MT Flash、Tencent HY-MT2 Plus 保持既有固定模型。

下表记录新增预设采用的公开 API 协议与默认地址。资料核对日期为 2026-10-10。这里的协议与请求夹具验证不代表真实账号、计费权限、地区或任一模型的翻译能力已经验收。

| 预设 | 默认 API base URL | 官方资料 |
| --- | --- | --- |
| Kimi | `https://api.moonshot.cn/v1` | [Moonshot 官方 API 调试工具及请求示例](https://github.com/MoonshotAI/moonpalace) |
| GLM | `https://open.bigmodel.cn/api/paas/v4` | [OpenAI API 兼容](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction) |
| Qwen | `https://dashscope.aliyuncs.com/compatible-mode/v1` | [Base URL 总览](https://help.aliyun.com/zh/model-studio/base-url)、[OpenAI 兼容调用](https://help.aliyun.com/en/model-studio/compatibility-of-openai-with-dashscope) |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | [OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai) |
| SiliconFlow | `https://api.siliconflow.cn/v1` | [快速开始](https://docs.siliconflow.cn/docs/userguide/quickstart) |
| OpenRouter | `https://openrouter.ai/api/v1` | [开发接口](https://openrouter.ai/developers)、[模型目录](https://openrouter.ai/docs/api/api-reference/models/get-models) |
| Xiaomi MiMo | `https://api.xiaomimimo.com/v1` | [OpenAI 兼容请求与思考字段](https://platform.xiaomimimo.com/docs/en-US/usage-guide/passing-back-reasoning_content) |
| MiniMax | `https://api.minimax.io/v1` | [OpenAI 兼容 API](https://platform.minimax.io/docs/api-reference/text-openai-api) |
| Doubao | `https://ark.cn-beijing.volces.com/api/v3` | [Base URL 与认证](https://docs.volcengine.com/docs/ark/base-url-and-authentication?lang=en)、[Chat API](https://docs.volcengine.com/docs/ark/chat-api?lang=en) |
| StepFun | `https://api.stepfun.com/v1` | [官方平台调用示例](https://platform.stepfun.com/) |
| xAI | `https://api.x.ai/v1` | [快速开始](https://docs.x.ai/developers/quickstart)、[Chat Completions](https://docs.x.ai/developers/rest-api-reference/inference/chat-completions) |
| Mistral | `https://api.mistral.ai/v1` | [API reference](https://docs.mistral.ai/api) |
| New API | 用户填写部署地址 | [官方项目及支持的协议](https://github.com/QuantumNous/new-api) |
| 自定义服务 | 用户填写服务地址 | 由服务提供方公布的 Chat Completions、Responses 或 Claude Messages 兼容接口 |

这些新增品牌默认通过 `POST <base>/chat/completions` 发起单轮流式翻译，采用 `Authorization: Bearer <API key>`。MiniMax 额外请求 `reasoning_split: true`，将思考内容与译文分离。xAI 当前保留 Chat Completions 兼容接口，尽管官方推荐新项目采用 Responses。Qwen 默认使用仍受支持的北京共享域名；其他地区、工作空间和计费计划应填写其对应地址与密钥。

模型发现向同一 base 下的 `GET <base>/models` 请求兼容目录。这是应用的发现约定，不意味着每家厂商或每种账号都承诺提供此接口；缺少目录的服务不能通过手填或预置模型绕过选择。目录只表示可选候选，仍需样例翻译确认模型兼容性。目录请求保持现有数量、分页、响应大小与超时上限。

## 自定义接口格式和完整请求地址

自定义服务和 New API 可以选择三个接口格式。base URL 模式保留路径前缀并追加对应操作路径，模型列表追加 `models`。

| 接口格式 | 翻译操作路径 | 认证与目录格式 |
| --- | --- | --- |
| Chat Completions | `chat/completions` | Bearer API key；OpenAI 兼容 `data` 列表 |
| Responses | `responses` | Bearer API key；OpenAI 兼容 `data` 列表 |
| Claude Messages | `messages` | `x-api-key`、`anthropic-version: 2023-06-01`；Claude 原生 `data` 列表和分页 |

完整请求 URL 模式将翻译请求发送到用户填写的确切路径，不追加操作名，并要求另填模型列表完整 URL。两个 URL 必须同源：协议、主机及有效端口一致。不推测目录位置，不接受认证信息、查询字符串或片段，不跟随重定向。远端只接受 HTTPS，HTTP 仅限回环地址。

API key 仍保存在既有 Keychain 命名空间，配置只保存非秘密字段。品牌与图标元数据不改变既有 `TranslationServiceKind` 编码。旧版无预设的匿名 OpenAI 兼容配置保持可读取；显式新增的自定义服务和 API 品牌要求 API key。未知品牌或图标标识回退显示，不丢弃已有服务 UUID 和模型。
