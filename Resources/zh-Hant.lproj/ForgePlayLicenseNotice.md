# ForgePlay 授權與法律聲明

本文件是 ForgePlay 隨附法律資料的本地化閱讀指南，不會取代 App 內附的正式授權條款原文、著作權聲明或各元件的個別條款。

## 發行版本識別

ForgePlay 官方建置透過顯示名稱 `ForgePlay`、`Info.plist` 中的 Bundle 識別碼、版本與建置編號、Developer ID 簽章，以及隨 DMG 發布的校驗和與發行資訊清單來識別。修改版必須清楚標示修改內容，不得宣稱為官方 ForgePlay 發行版，也不得暗示獲得維護者認可。

## ForgePlay Game Mode

適用範圍文件所識別的 ForgePlay Game Mode 程式碼僅依 GNU General Public License version 3（`GPL-3.0-only`）發布。確切範圍與附加條款記錄於 `LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md`。

ForgePlay Game Mode  
Copyright (C) 2026 Facta-Leopard  
Original source: https://github.com/Facta-Leopard/ForgePlay

未修改的授權條款原文包含在 `LICENSES/GPL-3.0-only.txt` 與 `LICENSES/LGPL-2.1-or-later.txt`。整個儲存庫的授權界線記錄於 `LICENSE.md`。

## ForgePlay Frame Generation

適用範圍文件所識別、由 ForgePlay 撰寫的 Frame Generation 程式碼僅適用 GNU General Public License 第 3 版（`GPL-3.0-only`）。確切範圍、原始碼識別資訊與附加條款記錄於隨附的 `LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_LICENSE_SCOPE.md`；相關聲明以及檔案與符號清單位於同一目錄。

```text
ForgePlay Frame Generation
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay
```

衍生自 Wine 的 Frame Generation 載入與環境變數銜接程式碼仍單獨標示為 `LGPL-2.1-or-later`；此次 Frame Generation GPL 指定不會變更這些銜接程式碼的授權。這些原始碼界線不會免除發布結合作品時應履行的 GPL 義務。包括 D3DMetal 與 MetalFX 在內的 Apple 元件及其他第三方元件仍適用各自條款；本聲明不授予連結例外。

## 第三方元件

Wine、字型、算繪器、Apple 技術及其他第三方元件仍受各自授權與條款約束。ForgePlay 不主張擁有這些元件。直接發布的 DMG 可能包含以獨立 Apple 元件標示的 D3DMetal；其 Apple 授權、致謝及原始簽章會與該承載內容一同保留。

## Noto 字型後援

ForgePlay 依 SIL Open Font License 1.1 隨附未修改的 Noto Sans 與 Noto Sans CJK 檔案，作為原生介面的字型後援。完整授權文字以 `NotoSans-OFL.txt` 與 `NotoSansCJK-OFL.txt` 提供。字型權利仍歸各自著作權人所有；ForgePlay 不主張所有權，也不會把介面語言暗中用作 Windows 前綴的字型政策。

Noto Sans: Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic).

Noto Sans CJK: © 2014-2021 Adobe (http://www.adobe.com/).

可透過 App 法律資訊區域中的 `Noto Sans OFL 1.1` 與 `Noto Sans CJK OFL 1.1` 按鈕開啟未修改的完整授權文字。

## Nanum Gothic 執行階段字型後援

ForgePlay Runtime 包含未修改的 Nanum Gothic Regular 與 Bold 字型，用於 Windows 應用程式的韓文字形後援。Nanum Gothic: Copyright (c) 2010, NHN Corporation (http://www.nhncorp.com). 這些字型適用 SIL Open Font License 1.1，不適用 ForgePlay Frame Generation 的 GPL 指定。可透過同一法律資訊區域中的 `Nanum Gothic OFL 1.1` 按鈕查看未修改的完整授權文字與保留字型名稱（位於 App 資源中的 `Runners/ForgePlayRuntime/Legal/NanumGothic/OFL.txt`）。

## 隱私權與支援

ForgePlay 不會要求或儲存 Steam 密碼與 Steam Guard 代碼。支援套件只在使用者要求時於本機建立，分享前應由使用者檢查。詳細的隱私權聲明、支援指南及第三方元件聲明可從同一法律資訊區域開啟。
