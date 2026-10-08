# 应用图标与品牌资源

本目录保存正式应用资源的源文件和离线导出工具。生成后的资源位于 `LumaxTranslate/Resources/Assets.xcassets`，已纳入源码；普通构建无需重新生成。

## 应用图标

- `AppIcon.png`：1254 × 1254 RGBA 母稿。蓝色圆角底座、两片玻璃语言面板与交叠区域构成 TSX 应用图标；原始图像通过图像生成和透明背景编辑制作。
- `GenerateAppIcon.swift`：从母稿直接导出各尺寸，使用 sRGB 并保留内部透明度。固定轮廓清理底座外的残影，不重绘图案或叠加阴影；轮廓在 1254 px 画布的 148…1106 范围内。
- `AppIcon.appiconset`：macOS 的 10 个槽位，实际像素范围为 16…1024，供 Finder、Dock 和系统应用标识使用。
- `AppBrand.imageset`：同源 128 / 256 / 384 px 图像，供应用内品牌展示使用。

从仓库根目录重建：

```sh
swift -swift-version 6 Tools/Assets/GenerateAppIcon.swift
```

可选导出明暗背景下的原生尺寸检查图：

```sh
mkdir -p .build/AssetReview
swift -swift-version 6 Tools/Assets/GenerateAppIcon.swift --preview .build/AssetReview/app-icon.png
```

## 菜单栏图标

`MenuBarIcon.svg` 是可编辑的正式黑色模板源稿，使用取词边界与双语符号表达翻译入口。几何路径直接绘制，语言字形由 CoreText 转为轮廓，渲染不依赖额外字体。构图参考通用翻译符号的视觉关系，没有复制第三方图标库路径。

`GenerateMenuIcon.swift` 使用 AppKit 从同一 SVG 导出 18 / 36 px 透明 PNG。`MenuBarIcon.imageset` 与 AppKit 使用 template 模式，由系统控制浅色、深色和选中状态的前景色。

```sh
swift -swift-version 6 Tools/Assets/GenerateMenuIcon.swift
```

若只需检查导出结果，可指定独立目录：

```sh
swift -swift-version 6 Tools/Assets/GenerateMenuIcon.swift --output-directory .build/AssetReview/MenuBarIcon
```

菜单模板遵循 [Apple NSImage.isTemplate](https://developer.apple.com/documentation/appkit/nsimage/istemplate) 的着色方式。上述导出工具仅更新图像，不改变工程配置、版本、应用身份或签名权限。

## 第三方厂商标识

厂商 SVG 的原始文件、固定来源、摘要、许可及重建方式见 [ProviderLogos](ProviderLogos/README.md)。各厂商品牌名称与标识属于对应权利人，保留其许可声明，仅用于识别配置的服务。
