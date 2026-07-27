# ForgePlay Game Mode 라이선스 결정

## 결정

ForgePlay 전체가 아니라 **현재 코드에서 식별되는 Game Mode 구현
코드**를 GNU General Public License version 3 only
(`GPL-3.0-only`)로 공개한다.

`only`는 GPL 버전 3만 허용한다는 뜻이다. 상업 이용 금지나 저작권자의
건별 사전허락을 뜻하지 않는다.

## 허락의 의미

GPLv3 조건을 전부 지키는 이용자에게는 GPL 자체가 사용·복제·수정·배포
허락을 미리 부여하므로 Facta-Leopard의 별도 허락이 필요하지 않다.

GPL을 따르지 않고 Game Mode 코드를 독점 제품에 포함해 배포할 권리는
이 공개 라이선스로 부여하지 않는다. 그러한 별도 허락을 제공할지는
Facta-Leopard가 자신이 단독으로 권리를 보유한 코드에 대해서만 별도로
결정할 수 있다. Wine 원저작자 코드에 대한 독점 허락은 Facta-Leopard
혼자 부여할 수 없다.

## 저작자 표시

모든 GPL 대상 소스와 배포물의 법무 고지는 다음 표시를 보존한다.

```text
ForgePlay Game Mode
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay
SPDX-License-Identifier: GPL-3.0-only
```

GPLv3 제7조가 허용하는 범위에서 저작자·원본 출처 표시, 수정본 표시,
출처 오인 방지 및 ForgePlay 상표권 유보 조건을 적용한다.

## 현재 구조에 따른 효과

- Game Mode Swift 코드는 ForgePlay 본체와 같은 실행 파일에 컴파일된다.
  따라서 해당 코드를 포함한 현재 앱 바이너리를 배포할 때 GPL 의무를
  Game Mode 파일에만 가두기 어렵고, 결합 실행 파일 전체에 GPL 조건이
  적용될 수 있다.
- 두 Game Mode 패치는 Wine 소스에 직접 합쳐진다. 해당 패치 사본을
  GPLv3로 전환하면 패치가 적용된 Wine 결합 사본도 GPLv3에 맞게
  배포해야 한다.
- `GameModeProcessHost`는 별도 Mach-O지만 같은 PID에서 Wine
  `ntdll.so`의 `__wine_main`을 실행한다. GPL Host와 LGPL Wine은
  결합 가능하지만, 양쪽의 대응 소스와 고지를 모두 제공해야 한다.

위 효과는 ForgePlay 전체 소스의 저작권 귀속을 바꾸는 것이 아니라,
현재 결합물을 배포할 때 발생하는 GPL 카피레프트의 결과다.

## 효력과 공개 릴리스 조건

이 문서는 ForgePlay Game Mode의 확정 라이선스 정책이다. 정확한
대상은 `GAME_MODE_LICENSE_SCOPE.md`와 그 한국어판에 식별된 코드다.

Game Mode 바이너리를 공개 배포하려면 다음 조건을 모두 충족한다.

1. 릴리스 커밋 기준의 파일·심볼 범위를 대응 소스에 고정한다.
2. 대상 소스의 저작권·SPDX 표시와 Wine 유래 사본의 LGPL→GPL 전환
   고지를 일치시킨다.
3. GPLv3 전문, 적용 범위, `GAME_MODE_NOTICE`, Wine 원저작자 고지와
   버전이 정확히 일치하는 대응 소스를 바이너리와 동시에 공개한다.
4. D3DMetal 등 별도 라이선스의 제3자 구성요소를 자체 조건에 따라
   구분하고 필요한 라이선스·acknowledgements·원본 서명을 보존한다.

확정된 `bundled-direct-dmg` 구성은 D3DMetal을 Apple의 자체 조건이
적용되는 별도 제3자 런타임 구성요소로 포함한다. D3DMetal은
`GPL-3.0-only`로 재라이선스되지 않으며, 공개 DMG 검증기는 Apple
법적 문서와 보존된 원본 Apple 코드 서명을 필수로 확인한다.
