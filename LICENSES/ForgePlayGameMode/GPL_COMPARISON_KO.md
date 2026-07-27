# GPL 선택 근거

최종 선택은 `GPL-3.0-only`다.

## GPLv2와 GPLv3

| 항목 | GPLv2 | GPLv3 |
|---|---|---|
| 상업 이용·판매 | 허용 | 허용 |
| 배포 시 대응 소스 | 요구 | 요구 |
| 강한 카피레프트 | 적용 | 적용 |
| 특허 대응 | GPLv3보다 제한적 | 제11조의 명시적 특허 허여와 특허 계약 대응 |
| 수정본 설치 잠금 | 별도 설치 정보 규정 없음 | User Product에 필요한 설치 정보 요구 |
| DRM·우회금지법 | 별도 규정 없음 | GPL 권리 행사를 막는 우회금지법 주장 제한 |
| 추가 조건 | GPLv3 제7조와 같은 체계 없음 | 합리적 저작자 표시·출처 오인 방지·상표권 유보 허용 |
| Apache 2.0 호환 | 아니오 | 예 |
| 위반 후 권리 회복 | 상대적으로 엄격 | 제8조의 시정·회복 절차 |

게임 모드는 특허 대응, 설치 잠금 방지 및 제작자 표시를 명확히 하기
위해 GPLv3를 선택한다.

## `GPL-3.0-only`와 `GPL-3.0-or-later`

| 표기 | 의미 |
|---|---|
| `GPL-3.0-only` | 수령자는 GPLv3 조건만 선택할 수 있다. |
| `GPL-3.0-or-later` | 수령자는 GPLv3 또는 FSF가 나중에 발표한 버전을 선택할 수 있다. |

ForgePlay Game Mode는 검토한 조건을 고정하기 위해
`GPL-3.0-only`를 선택한다.

## GPL, LGPL, PolyForm Noncommercial

| 항목 | GPLv3 | LGPL 2.1+ | PolyForm Noncommercial |
|---|---|---|---|
| OSI 오픈소스 | 예 | 예 | 아니오 |
| 상업 이용 | 허용 | 허용 | 공개 조건만으로는 불가 |
| 독점 앱과 결합 | 결합 프로그램에 GPL 카피레프트 적용 | 조건을 지키면 독점 앱에서 사용 가능 | 상업 사용에는 별도 허락 필요 |
| 수정 소스 의무 | 배포된 결합 파생물에 강함 | LGPL 구성요소와 수정에 집중 | GPL과 같은 소스 제공 의무가 아님 |

GPL에 비상업 조건이나 특정 회사 사용 금지를 추가할 수 없다. 그런
조건은 GPL의 추가 제한이 되며 OSI 의미의 오픈소스도 아니게 된다.

## CodeWeavers가 사용할 경우

- GPLv3 조건을 전부 지키고 결합 파생물의 대응 소스와 고지를
  제공한다면 별도 허락 없이 상업적으로 사용할 수 있다.
- GPL 의무를 지키지 않고 독점 제품에 포함해 배포할 권리는 없다.
- 별도 비GPL 허락을 요청할 수는 있으나 Facta-Leopard가 허락할
  의무는 없다.
- 기능만 보고 독립적으로 재구현한 코드에는 GPL이 자동 적용되지
  않는다.

## 저작자 표시

GPLv3 제7조 추가 조건과 파일 고지를 함께 사용한다.

```text
ForgePlay Game Mode
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay
SPDX-License-Identifier: GPL-3.0-only
```

## 공식 참고 자료

- [GNU GPLv3 전문](https://www.gnu.org/licenses/gpl-3.0.en.html)
- [GNU GPL FAQ](https://www.gnu.org/licenses/gpl-faq.en.html)
- [GPLv3 간단 안내](https://www.gnu.org/licenses/quick-guide-gplv3.html)
- [GPLv3를 선택하는 이유](https://www.gnu.org/licenses/rms-why-gplv3.html)
- [OSI Open Source Definition](https://opensource.org/osd)
