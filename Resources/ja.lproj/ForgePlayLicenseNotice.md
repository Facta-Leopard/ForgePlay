# ForgePlay ライセンスおよび法的通知

この文書は、ForgePlay に同梱される法的資料を各言語で理解するための案内です。アプリに含まれる正式なライセンス本文、著作権表示、各コンポーネント固有の条件を置き換えるものではありません。

## リリースの識別

ForgePlay の公式ビルドは、表示名 `ForgePlay`、`Info.plist` のバンドル識別子・バージョン・ビルド番号、Developer ID 署名、および DMG とともに配布されるチェックサムとリリースマニフェストによって識別されます。変更版は変更内容を明示し、公式リリースを名乗ったり、メンテナーの承認を示唆したりしてはなりません。

## ForgePlay Game Mode

適用範囲文書で指定された ForgePlay Game Mode のコードは、GNU General Public License version 3 only（`GPL-3.0-only`）で配布されます。正確な範囲と追加条件は `LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md` に記録されています。

ForgePlay Game Mode  
Copyright (C) 2026 Facta-Leopard  
Original source: https://github.com/Facta-Leopard/ForgePlay

変更されていないライセンス本文は `LICENSES/GPL-3.0-only.txt` と `LICENSES/LGPL-2.1-or-later.txt` に含まれます。リポジトリ全体のライセンス境界は `LICENSE.md` に記載されています。

## ForgePlay Frame Generation

適用範囲文書で指定された、ForgePlay が作成した Frame Generation のコードには、GNU General Public License バージョン 3 のみ（`GPL-3.0-only`）が適用されます。正確な範囲、ソースの識別情報、追加条件は同梱の `LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_LICENSE_SCOPE.md` に記録されており、付随する通知とファイル・シンボルのマニフェストも同じディレクトリにあります。

```text
ForgePlay Frame Generation
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay
```

Wine から派生した Frame Generation の読み込み・環境変数の連携コードは、引き続き `LGPL-2.1-or-later` として別途識別されます。今回の Frame Generation への GPL 指定によって、その連携コードのライセンスは変更されません。これらのソースの境界は、配布される結合著作物に適用される GPL の義務を免除するものではありません。D3DMetal や MetalFX を含む Apple コンポーネントとその他のサードパーティ製コンポーネントには、それぞれの条件が適用され、この通知はリンクの例外を認めるものではありません。

## サードパーティ製コンポーネント

Wine、フォント、レンダラー、Apple の技術、その他のサードパーティ製コンポーネントには、それぞれのライセンスと条件が適用されます。ForgePlay はそれらの所有権を主張しません。直接配布 DMG には、個別に識別された Apple コンポーネントとして D3DMetal が含まれる場合があり、Apple のライセンス、謝辞、元の署名はそのペイロードに保持されます。

## Noto フォントフォールバック

ForgePlay は、ネイティブ UI のフォールバックとして未改変の Noto Sans と Noto Sans CJK を SIL Open Font License 1.1 に基づき同梱します。ライセンス全文は `NotoSans-OFL.txt` と `NotoSansCJK-OFL.txt` に収録されています。各フォントの権利はそれぞれの著作権者に帰属し、ForgePlay は所有権を主張しません。また、UI 言語を Windows プレフィックスの暗黙のフォントポリシーとして使用しません。

Noto Sans: Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic).

Noto Sans CJK: © 2014-2021 Adobe (http://www.adobe.com/).

アプリの法務セクションにある `Noto Sans OFL 1.1` と `Noto Sans CJK OFL 1.1` ボタンから、変更されていないライセンス全文を開けます。

## ランタイムの Nanum Gothic フォントフォールバック

ForgePlay Runtime は、Windows アプリケーションの韓国語文字のフォールバックとして、未改変の Nanum Gothic Regular と Bold を含みます。Nanum Gothic: Copyright (c) 2010, NHN Corporation (http://www.nhncorp.com). これらのフォントには、ForgePlay Frame Generation の GPL 指定ではなく SIL Open Font License 1.1 が適用されます。同じ法務セクションの `Nanum Gothic OFL 1.1` ボタンから、変更されていないライセンス全文と予約フォント名を確認できます（アプリのリソース内の `Runners/ForgePlayRuntime/Legal/NanumGothic/OFL.txt`）。

## プライバシーとサポート

ForgePlay は Steam のパスワードや Steam Guard コードを要求・保存しません。サポートバンドルはユーザーの依頼時にのみローカルで作成され、共有前に確認する必要があります。詳細なプライバシー通知、サポート案内、外部コンポーネント通知は同じ法務セクションから開けます。
