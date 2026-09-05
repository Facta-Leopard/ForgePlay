# ForgePlay 许可证与法律声明

本文档是 ForgePlay 随附法律资料的本地化阅读指南。它不会取代 App 中附带的正式许可证原文、版权声明或各组件的专用条款。

## 发行版本标识

ForgePlay 官方构建通过显示名称 `ForgePlay`、`Info.plist` 中的 Bundle 标识符、版本号和构建号、Developer ID 签名，以及随 DMG 分发的校验和与发行清单进行识别。修改版必须明确标注修改，不得声称自己是官方 ForgePlay 发行版，也不得暗示获得维护者认可。

## ForgePlay Game Mode

适用范围文档所标识的 ForgePlay Game Mode 代码仅按 GNU General Public License version 3（`GPL-3.0-only`）分发。确切范围和附加条款记录在 `LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md` 中。

ForgePlay Game Mode  
Copyright (C) 2026 Facta-Leopard  
Original source: https://github.com/Facta-Leopard/ForgePlay

未修改的许可证原文包含在 `LICENSES/GPL-3.0-only.txt` 和 `LICENSES/LGPL-2.1-or-later.txt` 中。整个仓库的许可证边界记录在 `LICENSE.md` 中。

## ForgePlay Frame Generation

适用范围文档所标识、由 ForgePlay 编写的 Frame Generation 代码仅适用 GNU General Public License 第 3 版（`GPL-3.0-only`）。确切范围、源代码标识和附加条款记录在随附的 `LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_LICENSE_SCOPE.md` 中；相关声明以及文件和符号清单位于同一目录。

```text
ForgePlay Frame Generation
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay
```

派生自 Wine 的 Frame Generation 加载和环境变量衔接代码仍单独标识为 `LGPL-2.1-or-later`；此次 Frame Generation GPL 指定不会改变这些衔接代码的许可证。这些源代码边界不会免除分发组合著作时应履行的 GPL 义务。包括 D3DMetal 和 MetalFX 在内的 Apple 组件及其他第三方组件仍适用各自条款；本声明不授予链接例外。

## 第三方组件

Wine、字体、渲染器、Apple 技术以及其他第三方组件继续受各自许可证和条款约束。ForgePlay 不主张拥有这些组件。直接分发的 DMG 可能包含作为独立 Apple 组件标识的 D3DMetal；其 Apple 许可证、致谢和原始签名会与该载荷一同保留。

## Noto 字体回退

ForgePlay 按照 SIL Open Font License 1.1，随应用提供未经修改的 Noto Sans 与 Noto Sans CJK 文件，作为原生界面的字体回退。完整许可证文本以 `NotoSans-OFL.txt` 和 `NotoSansCJK-OFL.txt` 提供。字体权利仍归各自版权方所有；ForgePlay 不主张所有权，也不会把界面语言隐式用作 Windows 前缀的字体策略。

Noto Sans: Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic).

Noto Sans CJK: © 2014-2021 Adobe (http://www.adobe.com/).

可通过 App 法律信息区域中的 `Noto Sans OFL 1.1` 和 `Noto Sans CJK OFL 1.1` 按钮打开未经修改的完整许可证文本。

## Nanum Gothic 运行时字体回退

ForgePlay Runtime 包含未经修改的 Nanum Gothic Regular 和 Bold 字体，用于 Windows 应用程序的韩文字形回退。Nanum Gothic: Copyright (c) 2010, NHN Corporation (http://www.nhncorp.com). 这些字体适用 SIL Open Font License 1.1，不适用 ForgePlay Frame Generation 的 GPL 指定。可通过同一法律信息区域中的 `Nanum Gothic OFL 1.1` 按钮查看未经修改的完整许可证和保留字体名称（位于 App 资源中的 `Runners/ForgePlayRuntime/Legal/NanumGothic/OFL.txt`）。

## 隐私与支持

ForgePlay 不会索取或保存 Steam 密码和 Steam Guard 代码。支持包仅在用户请求时于本地创建，分享前应由用户检查。详细的隐私声明、支持指南和第三方组件声明可从同一法律信息区域打开。
