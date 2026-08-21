# ForgePlay Game Mode GPL-3.0-only 적용 범위

이 문서는 파일 이동이나 구조 변경을 전제로 하지 않는다. 현재 파일
구조와 현재 작동 경로에서 Game Mode 구현으로 식별되는 코드에 적용할
확정 `GPL-3.0-only` 정책을 기록한다.

Copyright (C) 2026 Facta-Leopard

## 1. 기본 원칙

이 문서가 정한 공개 라이선스는 GNU General Public License version 3
only(`GPL-3.0-only`)다.

- GPLv3 조건을 지키는 이용에는 별도 사전허락이 필요하지 않다.
- 상업적 사용·판매도 GPLv3 조건 안에서 허용된다.
- GPL 코드를 복제·수정하거나 하나의 파생 프로그램으로 결합해
  배포하면 GPLv3의 소스 제공·고지·카피레프트 조건을 따라야 한다.
- 비공개 내부 사용만으로는 일반적인 GPL 소스 제공 의무가 발생하지
  않는다.
- 게임 모드의 아이디어나 일반적 작동 원리를 독립적으로 재구현한
  코드에는 이 저작권 라이선스가 자동으로 적용되지 않는다.

## 2. GPL 대상: Game Mode 전용 Swift 파일

현재 다음 파일은 ForgePlay가 작성한 Game Mode 전용 코드로 식별한다.

- `Sources/ForgePlay/Models/GameModeEvidence.swift`
- `Sources/ForgePlay/Services/GameModeHostCapability.swift`
- `Sources/ForgePlay/Services/GameModeLaunchRequestStore.swift`
- `Tests/ForgePlayTests/GameModeHostCapabilityTests.swift`
- `Tests/ForgePlayTests/GameModeLaunchRequestStoreTests.swift`

`GameModeEvidence.swift`와 `GameModeLaunchRequestStore.swift`는 현재
프로덕션 실행 경로에서 직접 참조되지 않고 주로 전용 테스트가
검증하지만, `Sources/ForgePlay` 전체가 앱 타깃에 포함되므로 빌드
입력에는 들어간다.

대상 전용 파일에는 다음 표시를 사용한다.

```text
SPDX-FileCopyrightText: 2026 Facta-Leopard
SPDX-License-Identifier: GPL-3.0-only
```

경로별 라이선스 지정은 기계 판독 가능한
`GAME_MODE_FILE_LICENSES.json`에도 기록한다. 두 Wine 패치는 현재
Runtime의 버전 일치 해시 입력이므로 패치 바이트를 바꾸지 않는다.
대신 그 패치 사본 전체의 `GPL-3.0-only` 전환 고지를 위 외부
매니페스트에 기록한다.

## 3. GPL 대상: 혼합 Swift 파일의 Game Mode 고유 코드

다음 파일은 일반 앱 책임과 Game Mode 책임이 섞여 있다. 이 문서가
GPL 대상으로 지정하는 것은 파일의 모든 일반 코드가 아니라 아래에
식별한 Game Mode 고유 구현이다.

### `Sources/ForgePlay/Services/SafeProcessRunner.swift`

- `GameModeSteamChildSelectionResolver`
- `GameModeHostLaunchRecord`
- `GameModeHostEvidenceRecord`
- `GameModeHostEvidenceProcessIdentity`
- Game Mode Host 실행 기록 등록·조회
- Game Mode 증거 로그 해석과 PID 검증
- `SteamGameModeLaunchPolicy` 분기
- `GameModeHostEnvironment` 구성과 Game Mode 진단 환경 기록

### `Sources/ForgePlay/UI/SteamLaunchView.swift`

- Game Mode 토글 상태와 세션 상태
- `experimentalGameModeControl`
- `gameModeStateLabel`
- `gameModePolicy`를 Steam 실행 경로로 전달하는 분기
- Game Mode 활성·검증 안내 문구를 구성하는 코드

### 실행 정책 전달 및 진단

- `Sources/ForgePlay/Services/SteamManager.swift`의
  `gameModePolicy` 전달 경로
- `Sources/ForgePlay/Services/SteamPrefixService.swift`의
  `gameModePolicy` 전달 경로
- `Sources/ForgePlay/Services/SupportBundleService.swift`의
  Game Mode Host 증거 수집 코드
- `Sources/ForgePlay/App/AppServices.swift`의 Game Mode Host
  lease 검증 연결부
- `Sources/ForgePlay/Services/PrefixExecutionLease.swift`의
  Game Mode Host 참여 처리

### 빌드 연결부

- `project.yml`의 `GameModeProcessHost` 타깃, ForgePlay 앱의 Helper
  포함 설정 및 해당 타깃 전용 빌드 단계
- Game Mode Host 전용 Xcode 설정과 검증 스크립트

혼합 파일의 일부 코드만 다른 라이선스로 식별하면 복사·수정 과정에서
경계가 사라질 수 있다. 각 바이너리 릴리스는 확정 커밋의 심볼 목록과
파일별 고지로 이 범위를 고정해야 한다.

혼합 파일의 선언 경계는 `GAME_MODE_SYMBOL_MANIFEST.md`에 고정한다.
그 매니페스트를 포함하는 릴리스 태그와 커밋이 실제 배포 소스 트리와
매니페스트를 결합한다.

## 4. GPL 대상: GameModeProcessHost

현재 별도 애플리케이션 타깃으로 빌드되는 다음 범위를
`GPL-3.0-only` 대상으로 지정한다.

- `Native/GameModeProcessHost/`의 소스·헤더
- plist, entitlement 및 빌드 스크립트
- `README.md`와 `SOURCE-CONTRACT.md`
- `Config/ForgePlayGameModeProcessHost.xcconfig`
- `Config/ForgePlayGameModeProcessHostAppStore.xcconfig`
- `Config/ForgePlayGameModeProcessHostDistribution.xcconfig`
- `Config/ForgePlayGameModeProcessHostRelease.xcconfig`
- `Scripts/prepare-game-mode-host-build-identity.sh`
- `Scripts/verify-game-mode-source-licenses.py`
- `Scripts/tests/test-wine-game-mode-process-host-routing.sh`

### Wine 유래 부분

`Native/GameModeProcessHost/GameModeProcessHost.m`의 주소 예약,
`wine_main_preload_info`, `ntdll.so` 로드 및 같은 PID의
`__wine_main` 진입 부분은 Wine 11.12 `loader/main.c`에서 유래했다.

LGPL 2.1 제3조는 해당 사본에 일반 GNU GPL의 새 버전을 선택할 수 있게
한다. 따라서 이 Game Mode Host 사본을 `GPL-3.0-only`로 전환한다는
방향은 가능하다.

전환에 따라 다음을 지켜야 한다.

- Host 파일의 기존 LGPL 고지를 GPLv3 고지로 변경
- Wine 11.12 `loader/main.c` 출처 유지
- Copyright 2000 Alexandre Julliard 표시 유지
- `SOURCE-CONTRACT.md`의 파생 경계와 해시 기록 유지
- LGPL 2.1 제3조에 따라 해당 사본을 GPLv3로 전환했다는 기록 추가

해당 사본의 GPL 전환은 되돌릴 수 없다. Wine 원저작자 표시나 권리가
Facta-Leopard에게 이전되는 것도 아니다.

## 5. GPL 대상: 두 Wine Game Mode 패치

현재 Game Mode의 직접 대상 판별과 Host 진입을 구현하는 다음 패치
사본도 `GPL-3.0-only` 대상으로 지정한다.

- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch`
- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch`

이 패치는 Wine의 `kernelbase`와 `ntdll` 소스에 직접 합쳐진다. 따라서
패치 파일만 GPL이고 패치가 적용된 Wine 사본은 전부 LGPL이라고
표시할 수 없다.

실제 GPL 전환 릴리스에서는 다음을 함께 정리해야 한다.

- 패치가 적용된 Wine 결합 사본의 GPLv3 배포 조건
- 해당 Wine 소스 파일의 라이선스 고지
- 정확한 upstream Wine 11.12 소스와 전체 patch set
- 빌드·패키징 스크립트와 source fingerprint
- 기존 Wine 원저작자와 LGPL→GPL 전환 기록

변경되지 않은 upstream Wine 자료는 독립적으로 기존 LGPL 권리를
유지하지만, Game Mode GPL 변경이 결합된 배포물은 GPLv3 조건을
충족해야 한다.

## 6. 현재 구조에서 발생하는 결합 효과

### ForgePlay 앱 실행 파일

`project.yml`은 `Sources/ForgePlay` 전체를 ForgePlay 앱 타깃에
포함한다. 따라서 제2절과 제3절의 Game Mode Swift 코드는 현재
ForgePlay 본체와 같은 실행 파일로 컴파일된다.

이 상태에서 Game Mode 코드를 `GPL-3.0-only`로 배포하면 GPL
카피레프트 효과를 파일 이름만으로 본체 실행 파일에서 차단할 수 없다.
해당 코드를 포함한 현재 ForgePlay 실행 파일을 배포하려면 결합
프로그램 전체가 GPLv3가 요구하는 권리를 수령자에게 제공할 수 있어야
한다.

이것은 이 문서가 게임 모드와 무관한 파일의 저작권자를 바꾸기 때문이
아니라, GPL 코드와 하나의 실행 파일로 결합해 배포하는 행위의
결과다.

### GameModeProcessHost와 Wine

`GameModeProcessHost`는 ForgePlay 본체와 다른 Mach-O지만, 실행되면
Wine `ntdll.so`를 `dlopen`하고 같은 프로세스에서 `__wine_main`을
호출한다. GPL Host와 LGPL Wine은 라이선스상 결합할 수 있으나,
배포물은 GPL 결합 프로그램의 대응 소스와 Wine의 원저작자 고지를
모두 제공해야 한다.

### 별도 라이선스의 D3DMetal 구성요소

직접 DMG 릴리스 계약은 D3DMetal을 Apple의 자체 조건이 적용되는
별도 식별 제3자 런타임 구성요소로 포함한다. D3DMetal은 ForgePlay
Game Mode 소스 라이선스 범위 밖에 있으며 `GPL-3.0-only`로
재라이선스되지 않는다.

이 정책은 Apple의 조건을 대체·확장하거나 그 조건에 따른 권한을
별도로 부여하지 않는다. 직접 DMG 릴리스에는 구성된 payload와 함께
Apple 소프트웨어 라이선스, acknowledgements, framework 라이선스,
원본 Apple 코드 서명을 보존해야 한다. ForgePlay Game Mode의 GPLv3
라이선스·고지·버전 일치 대응 소스 제공은 별도의 릴리스 요건으로
유지된다.

## 7. GPLv3 제7조 추가 조건

ForgePlay가 단독으로 저작권을 보유한 Game Mode 코드에는 GPLv3
제7조가 허용하는 다음 조건을 적용한다.

### 저작자 및 원본 출처

소스와 바이너리에 동봉되는 법무 고지는 다음 표시를 보존한다.

```text
ForgePlay Game Mode
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay
```

대화형 배포물이 About, Legal, Credits 또는 이에 상응하는 법무 고지
화면을 제공하면 위 표시도 그 화면에 보존한다.

### 수정본 표시와 출처 오인 방지

수정본은 합리적인 방식으로 수정 사실을 표시해야 한다. 공식 ForgePlay
릴리스이거나 Facta-Leopard가 보증한 제품인 것처럼 표시해서는 안 된다.

### 상표권 유보

GPL 저작권 라이선스는 ForgePlay 이름·로고를 수정 제품의 상표로
사용하거나 공식 관계를 암시할 권리를 부여하지 않는다. 실제 코드
출처를 밝히는 정직한 명칭 사용은 제한하지 않는다.

## 8. 허락과 별도 상업 라이선스

GPLv3를 완전히 준수하는 사람은 Facta-Leopard에게 별도 허락을 받을
필요가 없다. CodeWeavers를 포함한 상업 사업자도 동일하다.

다만 GPL을 따르지 않고 Game Mode 코드를 독점 제품에 포함해 배포할
권리는 이 문서가 부여하지 않는다. 별도 비GPL 라이선스를 요청할 수는
있지만, Facta-Leopard가 이를 제공할 의무는 없다.

Facta-Leopard가 별도 허락을 줄 수 있는 범위는 자신이 단독으로
저작권을 보유한 코드뿐이다. Wine 유래 코드와 제3자 구성요소는 해당
원저작자의 라이선스 범위를 따라야 한다.

## 9. GitHub Release 의무

Game Mode GPL 바이너리를 배포하는 GitHub Release에는 같은 시점에
버전이 정확히 일치하는 대응 소스를 제공한다.

- GPL 대상 Swift 코드와 혼합 파일의 정확한 Game Mode 범위
- `GameModeProcessHost` 전체 소스와 빌드 자료
- 두 GPL Game Mode Wine 패치
- 패치가 적용된 정확한 Wine 대응 소스 또는 GPL이 허용하는 제공 방식
- 모든 빌드·패키징·설치 제어 스크립트
- GPLv3 전문, `GAME_MODE_NOTICE`, Wine 및 제3자 고지
- 소스·패치·빌드 fingerprint와 재현 절차

바이너리를 먼저 공개하고 대응 소스를 하루나 이틀 뒤 공개하는 방식은
사용하지 않는다.

## 10. 외부 기여 및 출처 기록

공식 ForgePlay 저장소는 외부 코드 기여를 받지 않는다. 이는 운영
정책이며 GPL이 허용하는 독립 포크·수정·재배포를 제한하지 않는다.

현재 Git 이력의 커밋 작성자는 Facta-Leopard 한 명으로 확인된다.
`Native/GameModeProcessHost/SOURCE-CONTRACT.md`는 Wine 유래 구현과
ForgePlay 독자 구현의 경계를 기록하고 있다. 이 기록과 upstream
해시·patch provenance를 릴리스에서 유지한다.

## 11. GPL 제외 범위

이 문서가 소스 저작권 라이선스로 직접 지정하지 않는 범위는 다음과
같다.

- Game Mode와 무관한 ForgePlay 고유 코드
- `Native/ExternalStorageAccessBridge/`
- ForgePlay 이름·로고·아트워크
- Game Mode 이외의 Wine 패치가 가진 기존 권리
- Apple Game Porting Toolkit, D3DMetal, DXMT, DXVK, D9VK,
  MoltenVK, GStreamer, FFmpeg, GnuTLS, 글꼴 및 기타 제3자 구성요소

단, GPL Game Mode 코드와 하나의 결합 프로그램으로 배포되는 경우에는
제6절의 결합 효과를 별도로 검토해야 한다.

## 12. 공개 바이너리 릴리스 조건

이 적용 범위는 ForgePlay Game Mode의 확정 라이선스 정책이다. 공개
바이너리 릴리스는 다음 조건을 모두 충족해야 한다.

1. 확정 커밋에 Game Mode 파일 지정과 혼합 파일 심볼 매니페스트를
   포함하고, 공개 빌드를 그 깨끗한 커밋에서 수행한다.
2. GPL 대상 파일의 저작권·SPDX 표시와 Host·두 Wine 패치의 LGPL→GPL
   전환 고지를 일치시킨다.
3. Wine 결합 사본의 라이선스·대응 소스 문서를 갱신한다.
4. 별도 라이선스의 제3자 구성요소를 자체 조건에 따라 구분하고 필요한
   라이선스·acknowledgements·서명을 모두 보존한다.
5. GPLv3 전문, `GAME_MODE_NOTICE`, 버전이 일치하는 대응 소스를
   바이너리와 같은 GitHub Release에 동시에 공개한다.

현재 `bundled-direct-dmg` 구성은 제4조건에 따라 D3DMetal을
의도적으로 포함한다. 릴리스 검증기는 구성된 payload, Apple 법적
문서와 보존된 원본 Apple 코드 서명을 필수로 확인한다. 이 기록은
D3DMetal을 재라이선스하거나 Apple의 조건을 대체하지 않는다.
