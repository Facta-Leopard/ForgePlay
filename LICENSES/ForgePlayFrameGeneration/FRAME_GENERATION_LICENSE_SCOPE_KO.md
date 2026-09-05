# ForgePlay Frame Generation GPL-3.0-only 적용 범위

Copyright (C) 2026 Facta-Leopard

## 1. 라이선스 지정과 정확한 소스 식별

`FRAME_GENERATION_FILE_LICENSES.json`과
`FRAME_GENERATION_SYMBOL_MANIFEST.md`가 식별하는 ForgePlay 자체 작성
Frame Generation 구현에는 GNU 일반 공중 사용 허가서 버전 3만
(`GPL-3.0-only`) 적용합니다. 수정하지 않은 전문은
`LICENSES/GPL-3.0-only.txt`에 있습니다.

기준은 `1.2_Release`의 커밋
`72a2598c99f0b649d1384ed0763a00037f5d1d2e`입니다. 파일 명세는 전용 파일의
정확한 경로와 SHA-256을, 심볼 명세는 이 커밋의 혼합 파일 중 적용되는 선언과
Frame Generation 전용 구문을 식별합니다. 같은 파일의 무관한 코드는 이
지정만으로 새 라이선스를 부여받지 않습니다.

외부 고지는 기준 네이티브·Swift·설정·테스트·Wine 패치 바이트를 보존합니다.
해당 ForgePlay 작성 코드에 다음 고지를 적용하되 원본 헤더는 수정하지 않습니다.

```text
SPDX-FileCopyrightText: 2026 Facta-Leopard
SPDX-License-Identifier: GPL-3.0-only
```

이는 오프라인 소스 전용 라이선스 준비이며, 새 바이너리의 빌드·서명·게시·출시를
주장하지 않습니다. 실제 배포 시에는 이 기준 커밋과 실제 전달되는 준비본 트리를
소스 목록으로 함께 식별해야 합니다.

## 2. 적용 구현

파일 명세에 나열된 `Native/D3DMetalFrameGenerationProxy/`의 다섯 파일,
`Sources/ForgePlay/FrameGeneration/FrameGenerationDomain.swift`, 프록시
xcconfig, 세 전용 테스트·계약 파일을 전체 파일 단위로 지정합니다.

네이티브 범위는 공개 진입점 `FPD3DMetalFrameGenerationProxyGetAPIV1`,
세션과 공개 Metal 관찰 연동, 상태기계, 원본 프레임 재출력, 50:50 midpoint
셰이더, 출력 스케줄링, 자원 소유권, 진단과 Frame Check 표시를 포함합니다.
Swift 범위는 심볼 명세로 한정한 설정·검증·실행·저장 연동, UI 컨트롤,
관찰 파싱·진단입니다. 같은 명세에 관련 빌드·검증 구간도 명시합니다.
혼합 파일 전체를 암묵적으로 지정하지 않습니다.

이는 Facta-Leopard가 보유하는 저작권의 지정입니다. 저장소 설계 계약은 공개
플랫폼 API와 ForgePlay 소유 코드의 사용을 설명하지만, 그 기록이 독립적인
저작권 감사나 완전한 클린룸 출처 증명은 아닙니다. 이 고지는 제3자 자료의
소유권이나 사용 권한을 새로 만들지 않습니다.

## 3. Wine 파생 연동 코드의 별도 경계

다음 두 패치 사본은 Frame Generation GPL 지정에서 제외하며 각각의
`LGPL-2.1-or-later` 소스 경계를 유지합니다.

- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-forgeplay-metal-window-surface-contract.patch`
- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-steam-session-compatibility-controls.patch`

첫 패치가 추가하는 Wine `winemac.drv/metal_surface_contract.c`에는 명시적인
LGPL-2.1-or-later 고지가 있습니다. `forgeplay_framegen_*` ABI 자료형,
`framegen_*` 로더·세션·뷰·오류 연동과 Metal-view 어댑터는 별도로 지정한
네이티브 프록시 구현이 아닙니다. 두 번째 패치의 프로세스 환경 매핑과 Unix
환경 전달도 Wine 파생 연동 코드입니다. 패치 바이트와 상위 저작권 고지를
그대로 보존해야 합니다.

Wine 버전은 11.12이며 원본 소스 압축 파일 SHA-256은
`d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc`,
최종 패치 소스 트리 SHA-256은
`5f5d93000e059d4ab388bc4ecfcd7dbdd19ada0a5da1400d28ea58f46ba95038`입니다.
권위 있는 재구성 기록은 기존
`Config/ForgePlayRuntimeSourceIdentity.lock.json`과
`Config/ForgePlayRuntimePatchProvenance.lock.json`입니다. 해시는 동일성을
증명할 뿐 독립적 저작 여부를 증명하지 않습니다. 이 고지는 그 기록을 변경하지
않습니다.

기존 Game Mode 범위의 GameModeProcessHost와 두 Game Mode Wine 패치에 대한
GPL 전환 지정은 그대로 유지합니다. 그 지정을 위 두 Frame Generation 연동
패치 사본으로 확대하지 않습니다.

## 4. Apple 및 기타 제3자 제외

D3DMetal·MetalFX·기타 Apple 바이너리, Apple SDK와 프레임워크 구현,
제3자 렌더러, Wine 상위 소스, 그림·폰트·상표는 이 범위가 새로 라이선스를
부여하는 대상이 아닙니다. 공개 Apple API를 사용한다고 그 API 구현이
ForgePlay 소스가 되지 않습니다. Apple 바이너리는 소스 전용 내보내기에서
제외되며 별도 Apple 약관을 따릅니다.

직접 DMG 배포의 Apple 라이선스·Acknowledgements·프레임워크 라이선스·원본
Apple 코드 서명 보존 요구는 별도입니다. 이 고지는 Apple 약관을 대체하거나
확대하지 않으며 D3DMetal 등 제3자 구성요소에 GPL 호환·링크 예외를 부여하지
않습니다.

## 5. 결합 저작물과 대응 소스

대상 Swift 코드는 ForgePlay 주 실행 파일에 컴파일됩니다. 프록시는 앱에
포함된 별도 dylib이며 Wine의 macOS 드라이버가 게임 프로세스에서 로드합니다.
파일·타깃·외부 고지·동적 로드 경계만으로 결합 저작물의 의무가 사라지지
않습니다.

대상 코드를 포함한 결합 저작물을 배포하면 GPLv3가 요구하는 권리와 버전이
일치하는 대응 소스를 제공해야 합니다. 관련 소스, 빌드·패키징·설치 제어·검증
자료와 상위 고지를 포함하고 해당 GPL·LGPL 소스 의무를 유지해야 합니다.
별도 LGPL 패치 사본의 독립적 허용은 기존 Game Mode 범위에서 설명한 결합
Wine 의무를 축소하지 않습니다. 이 범위는 필요한 권리를 보류하거나 Apple 등
제3자 약관상 권한 없이 바이너리를 배포할 권한을 주지 않습니다.

## 6. GPL이 부여하는 권한

GPLv3의 모든 조건을 지키면 사용·복사·수정·상업적 사용·배포에
Facta-Leopard의 별도 허가가 필요하지 않습니다. GPL 의무를 생략한 독점 배포를
허용하는 고지는 아닙니다. 별도 라이선스는 실제로 보유한 권리에 한해 제공할
수 있습니다.

## 7. GPLv3 제7조 추가 조건

Game Mode와 동일한 종류의 추가 조건을 Frame Generation 출처 표시로
적용합니다. Facta-Leopard가 해당 저작권을 보유한 자료에만 적용합니다.

### 저자 표시

소스 배포 및 비소스 배포에 수반되는 법적 고지는 다음을 보존해야 합니다.

```text
ForgePlay Frame Generation
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay
```

대화형 배포가 About·Legal·Credits 또는 이에 준하는 적절한 법적 고지
인터페이스를 제공한다면 그곳에서도 이 표시를 보존해야 합니다.

### 수정본과 출처

수정본은 합리적인 방식으로 수정되었음을 표시해야 합니다. 공식 ForgePlay
릴리스로 사칭하거나 Facta-Leopard의 보증·승인을 암시해서는 안 됩니다.

### 상표 사용권 없음

ForgePlay 이름과 로고의 상표 사용권을 부여하지 않습니다. 대상 코드의 출처를
식별하는 데 필요한 진실한 언급은 금지하지 않습니다.

## 8. 고지 전달

대상 소스와 해당 바이너리 법적 자료에 이 범위, `FRAME_GENERATION_NOTICE`,
두 명세와 수정하지 않은 GPLv3 전문을 함께 전달해야 합니다. 이후 변경한
소스를 기준 릴리스와 구별하고, 대상 파일을 실질적으로 변경하면 식별 기록을
갱신해야 합니다. 다른 바이트에 기준 해시를 조용히 재사용해서는 안 됩니다.

공식 저장소의 외부 코드 기여를 받지 않는 유지관리 정책은 GPL에 따른
포크·수정·재배포 권리를 제한하지 않습니다. 이 라이선스 준비는 UI나 웹사이트를
수정하지 않습니다. 정확한 식별은 영어 파일·심볼 명세와 함께 확인하십시오.
