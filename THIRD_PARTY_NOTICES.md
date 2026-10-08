# 第三方组件与标识 / Third-party components and marks

TSX 的 [MIT 许可证](LICENSE)不替代第三方组件的许可证、版权与商标声明。

- **应用内更新**：使用 [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/tree/2.10.0)，采用其原有[许可及第三方声明](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE)。Swift Package Manager 校验框架归档摘要，正式安装包另包含 `Sparkle-LICENSE.txt`；更新签名私钥仅保存在维护者钥匙串，不随源码或安装包分发。

- **翻译服务标识**：使用 Lobe Icons `@lobehub/icons-static-svg@1.95.1` 的部分 SVG，来源、摘要和转换说明见 [ProviderLogos](Tools/Assets/ProviderLogos/README.md)。上游 MIT 许可全文位于 [ProviderLogoNotices.txt](LumaxTranslate/Resources/ProviderLogoNotices.txt)，随应用打包。服务名称和商标属于对应权利人，使用标识不代表官方合作或背书。
- **可选账号运行组件**：原创组件源码位于 [Runtime/CodexHelper](Runtime/CodexHelper)，依赖固定提交的官方 `openai/codex` 库及锁定的 Rust 依赖。上游源码下载至忽略目录，保留原许可，不将其重新授权为 TSX 自身许可证。
- **安装包中的依赖声明**：[许可收集工具](Tools/CodexRuntime/licenses.py)根据实际构建依赖生成 `CodexThirdPartyNotices.txt`，由[打包校验](Tools/CodexRuntime/verify_bundle.py)检查并随应用提供。重新分发构建产物时，应保留其中适用的许可与声明。
- **系统框架与外部服务**：Apple 系统框架及用户配置的服务遵循各自条款。TSX 官方软件免费，不代表外部 API、账号计划或模型服务免费。

The project's license does not replace third-party licenses, copyright notices, or trademark rights. Provider artwork includes MIT-licensed Lobe Icons assets; preserve the linked original notices. The optional account component depends on a fixed revision of official Codex libraries and locked Rust packages, whose licenses remain in force. Packaged apps include generated dependency notices checked against their build inputs. Brand names identify services and do not imply endorsement. Official TSX releases are free of charge; external services may charge independently.
