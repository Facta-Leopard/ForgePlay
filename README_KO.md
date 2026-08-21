# ForgePlay Source — 한국어

[English](README_EN.md) | [언어 선택](README.md)

## 먼저 밝히는 입장

CodeWeavers가 Wine 생태계에 기여한 사실과 그 공로는 존중받아야 한다.
그러나 그 기여가 Wine의 공개 소스, macOS의 공개 동작, 또는 Windows
게임 호환 계층을 설계할 권리에 대한 독점권을 뜻하지는 않는다.

ForgePlay가 출발한 문제의식은 단순하다. macOS에서 Windows 게임을
실행하는 상용 제품군에는 오랫동안 CrossOver와 실질적으로 견줄 만한
경쟁자가 거의 없었다. 경쟁이 부족하면 다른 구조가 가능한지 검증할
압력도 약해진다. ForgePlay는 “CrossOver와 다른 구현 경로도 실제로
동작할 수 있다”는 주장을 말이 아니라 공개된 소스와 재현 가능한
구조로 입증하기 위해 만들었다.

같은 문제를 해결한다는 사실만으로 한 제품이 다른 제품의 복제품이
되지는 않는다. 판단할 것은 이름이나 인상이 아니라 실제 출처,
코드의 경계, 빌드 구조, 포함된 구성요소와 각 라이선스다. 그래서
ForgePlay는 핵심 구현을 비공개로 감추지 않고 이 소스 트리로 공개한다.
누구든 코드를 읽고, 비교하고, 포크하고, 주장에 반박할 수 있다.

## ForgePlay가 아닌 것

- 설치된 CrossOver를 실행하거나 감싸는 프런트엔드가 아니다.
- CrossOver의 bottle 디렉터리, 제품 번들, 실행 파일 또는 비공개
  패치에 의존하는 구조가 아니다.
- CodeWeavers의 비공개 구현을 ForgePlay의 독자 코드라고 주장하지
  않는다.
- Wine, D3DMetal 또는 제3자 구성요소의 권리까지 ForgePlay가
  소유한다고 주장하지 않는다.

ForgePlay는 Wine을 기반으로 한다. 사용한 Wine 소스와 패치는
버전·해시·출처와 함께 공개한다. D3DMetal은 별도 제3자 구성요소이며
이 소스 배포본에 바이너리로 포함되지 않는다. 공개 소스와 별도
라이선스 구성요소를 함께 배포하는 것, 그리고 그 결과물을 유료로
판매하는 것은 서로 모순되지 않는다. CrossOver의 판매 방식 자체가
다른 구현에 대한 독점 권원을 증명하지도 않는다. 각 프로젝트는
자신이 실제로 배포하는 구성요소와 그 조건으로 평가되어야 한다.

## Steam 연동은 실제로 어떻게 동작하는가

정확히 말하면 ForgePlay는 Steamworks SDK를 링크하거나
`steam_api.dll`/`steam_api64.dll`을 후킹하는 방식이 아니다. 또한
비공개 Steam API를 가장하지 않는다. ForgePlay가 사용하는 것은
Steam의 로컬 설치 메타데이터, 실제 Steam 클라이언트, 그리고 Steam이
만드는 정상적인 프로세스 계보다.

1. `SteamLibraryScanner.swift`가 Steam의 `libraryfolders.vdf`와
   `appmanifest_*.acf`를 읽어 설치된 라이브러리와 게임 메타데이터를
   찾는다.
2. ForgePlay가 관리하는 Wine prefix에서 실제 `steam.exe`를 실행한다.
   ForgePlay가 게임 실행 파일을 Steam인 것처럼 대신 실행하지 않는다.
3. Steam이 Windows 쪽의 정식 부모 프로세스로 남아 게임 또는
   런처 자식을 생성한다.
4. ForgePlay의 Wine 패치는 프로세스 생성 경계에서 선택된 렌더러,
   네트워크 어댑터 표현과 오디오 입력 정책 및 Steam 게임 계보를
   자식에게 전달한다.
5. Game Mode 대상 여부는 명령행, 게임 제목, 계정명, 볼륨명 또는
   Steam App ID를 신뢰해서 정하지 않는다. Wine이 해석한
   `RTL_USER_PROCESS_PARAMETERS.ImagePathName`을 Unix 쪽에서 검사한다.
6. 경로 구성요소가 `steamapps/common` 아래에 있는 실제 실행 파일만
   대상으로 인정한다. `_CommonRedist`와 그 밖의 인프라 프로세스는
   제외한다. 런처가 나중에 장시간 실행될 진짜 게임 자식을 만들면
   그 자식도 독립적으로 다시 판정한다.

이 방식에서 Steam은 로그인, 업데이트, 소유권 확인, 게임 선택과
자식 프로세스 생성을 계속 담당한다. ForgePlay는 그 정상 실행
계보를 보존하면서 Wine 내부의 프로세스 경계에서 호환성 정책만
적용한다.

## 렌더러 선택과 Game Mode는 분리되어 있다

Steam 세션을 시작하기 전에 사용자는 D3DMetal 표준,
D3DMetal NVIDIA/DLSS 호환성, DXMT, D9VK, DXVK 중 정확히 하나를
선택한다. 두 D3DMetal 선택은 같은 렌더러를 사용하며, 실험적인
NVIDIA 선택만 게임 자식에 `D3DM_VENDOR_ID=0x10de`를 추가한다.
이 선택은 DirectX 11/12를 강제하거나 게임의 DLSS 동작을 보장하지
않는다. Steam 클라이언트와 Steam WebHelper는 기본 Wine 렌더러
경로에 남고, 선택된 렌더러는 `steamapps/common`에 속한 게임 자식에만
적용된다. 선택이 없거나 잘못되면 다른 렌더러로 조용히 대체하지 않고
실행을 거부한다.

렌더러 선택과 Game Mode 대상 판정은 독립적이다. D3DMetal을
선택했다고 Game Mode가 자동으로 켜지는 것도 아니고, Game Mode를
선택했다고 렌더러가 바뀌는 것도 아니다.

같은 화면에서 네트워크 어댑터 표현은 표준, Wi‑Fi, Ethernet 중 하나를,
오디오 입력은 끔 또는 켬을 매 세션 직접 선택한다. 네트워크 선택은
게임에 보이는 어댑터 종류만 바꾸며 TCP와 UDP를 서로 변환하지 않는다.
오디오 입력 끔은 CoreAudio 입력 접근 전에 Windows capture endpoint를
0개로 반환하며 오디오 출력은 유지한다. 이 값들은 게임별로 저장되거나
자동 복원되지 않는다.

## Game Mode 구현

일반 Steam 세션은 표준 Wine loader를 사용한다. Game Mode 경로는
사용자가 명시적으로 선택하는 beta 기능이다.

```mermaid
flowchart LR
    A["ForgePlay (arm64)"] --> B["Wine에서 steam.exe 실행"]
    B --> C["Steam이 Windows 자식 생성"]
    C --> D{"Wine이 해석한 ImagePathName이<br/>steamapps/common 아래인가?"}
    D -- "아니오 또는 Game Mode 미선택" --> E["표준 Wine loader"]
    D -- "예 + Game Mode 선택" --> F["고정 서명된 GameModeProcessHost.app (x86_64)"]
    F --> G["Runtime·서명·sandbox·prefix lease 검증"]
    G --> H["같은 PID에서 정확한 ntdll.so와 __wine_main 진입"]
    H --> I["macOS가 Game Mode 활성화 여부 판단"]
```

구현 흐름은 다음과 같다.

1. ForgePlay 본체가 고정된 host bundle과 정확한 runtime identity를
   먼저 검사한다.
2. Steam이 만든 대상 자식이 PE mapping을 시작하기 전에, Wine loader가
   그 프로세스를 앱 내부의 고정 경로
   `Contents/Helpers/GameModeProcessHost.app`으로 `exec`한다.
3. 이 전환은 새 게임별 앱을 생성하지 않는다. 기존 Darwin PID,
   `argv`, 현재 디렉터리, 상속 handle과 Wine server 문맥을 유지한다.
4. `GameModeProcessHost`는 ForgePlay 본체와 별도로 빌드되는 고정
   `x86_64` Mach-O application target이다. Apple Silicon에서는
   Rosetta를 통해 실행된다.
5. host는 자신의 bundle identity, 코드·runtime identity, app-group
   sandbox 경계, 고정 IPC/evidence 경로, Wine loader 경로와 해시,
   prefix execution lease를 다시 검증한다.
6. 검증이 끝나면 정확히 번들된 `x86_64-unix/ntdll.so`를 열고 같은
   PID에서 `__wine_main`으로 진입한다.
7. host 또는 필수 계약 검증이 실패하면 일반 Wine 경로로 몰래
   fallback하지 않고 해당 자식을 실패시킨다.
8. host는 `LSSupportsGameMode=true`와 games category를 선언한다.
   실제 Game Mode 활성화 여부는 ForgePlay가 강제로 결정하는 것이
   아니라 macOS가 실행 문맥을 보고 판단한다.

따라서 “독자 바이너리”라는 표현은 정확히 다음을 뜻한다.
`GameModeProcessHost`는 ForgePlay 프로젝트가 별도 target으로
컴파일·서명하는 고정 Mach-O 실행 파일이다. CrossOver의 host
바이너리를 실행하거나 이름만 바꾼 것이 아니다. 다만 그 바이너리가
Wine과 무관한 완전 신규 loader라는 뜻은 아니다.

## 클린룸 구현과 Wine 유래 부분의 정확한 경계

ForgePlay는 강한 주장을 하되 출처를 흐리지 않는다.

| 영역 | 구현 및 출처 | ForgePlay의 주장 |
| --- | --- | --- |
| Steam 탐색·세션 오케스트레이션 | ForgePlay 소스. VDF/ACF 메타데이터와 실제 Steam 실행 경로 사용 | 독자 구현 |
| Game Mode control plane | 공개된 macOS 동작과 프로젝트가 정의한 실행 계약을 바탕으로 작성한 target 판정, 고정 host routing, identity·sandbox·lease 검증, evidence 및 lifecycle | CrossOver 비공개 코드에 의존하지 않은 클린룸 오케스트레이션 |
| `GameModeProcessHost` 산출물 | `project.yml`의 별도 application target으로 빌드되는 고정 `x86_64` Mach-O | 독자적으로 구축·서명되는 바이너리 target |
| 같은 PID의 Wine 진입부 | Wine 11.12 `loader/main.c`에서 유래한 주소 예약, `wine_main_preload_info`, `ntdll.so` 로딩과 `__wine_main` 호출 | 클린룸이라고 주장하지 않으며 Wine 유래를 명시·귀속 |
| D3DMetal bridge | 공개된 Apple 인터페이스와 관찰 가능한 ABI 계약을 바탕으로 작성한 ForgePlay Wine patch | 공개 경계에 대한 독자 adapter이며 D3DMetal 자체의 소유권 주장이 아님 |
| D3DMetal payload | Apple 조건이 적용되는 별도 제3자 바이너리 | 이 소스 트리에 포함하지 않으며 재라이선스하지 않음 |

특히 `GameModeProcessHost.m`의 낮은 수준 Wine loader 진입부는
Wine 11.12에서 유래했다. 이 부분을 숨기거나 “100% 클린룸 Wine
loader”라고 부르지 않는다. 상세한 유래, 원본 해시와 라이선스
처리는 `Native/GameModeProcessHost/SOURCE-CONTRACT.md`에 기록되어
있다. 반대로 target 판정, 고정 host 계약, runtime identity,
app-group 경계, prefix lease, fail-closed 정책과 evidence 체계는
ForgePlay가 작성한 Game Mode 오케스트레이션이다.

이 구분이 중요한 이유는 간단하다. Wine 공개 코드를 적법한 조건으로
수정해 쓰는 것과 CrossOver의 비공개 구현을 복제하는 것은 같은 말이
아니다. ForgePlay는 전자를 공개적으로 밝히며, 후자를 했다고
주장하지 않는다.

## 소스로 직접 확인할 위치

- Steam 설치 탐색:
  `Sources/ForgePlay/Services/SteamLibraryScanner.swift`
- Steam 실행 환경과 host preflight:
  `Sources/ForgePlay/Services/SafeProcessRunner.swift`
- Game Mode 직접 대상 판정:
  `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch`
- 고정 process host routing:
  `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch`
- 별도 host target:
  `project.yml`
- host 구현 계약:
  `Native/GameModeProcessHost/README.md`
- Wine 유래 코드의 정확한 범위:
  `Native/GameModeProcessHost/SOURCE-CONTRACT.md`
- Wine 11.12 원본 URL, 해시, patch 및 재구축 정보:
  `Resources/Runners/ForgePlayRuntime/SOURCE-AVAILABILITY.md`
- 수동 NVIDIA vendor, 네트워크 표현과 오디오 입력 Wine patch:
  `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-steam-session-compatibility-controls.patch`
- TCP/UDP·어댑터 종류·capture endpoint 자동 probe:
  `Scripts/test-wine-session-compatibility.sh`
- patch provenance lock:
  `Config/ForgePlayRuntimePatchProvenance.lock.json`

주장은 위 파일들로 검증할 수 있다. 코드와 맞지 않는 설명이 있다면
문서의 권위가 아니라 코드·해시·빌드 결과를 기준으로 지적하면 된다.

## 이 공개본에 포함되는 것과 제외되는 것

포함되는 항목:

- ForgePlay Swift 및 Objective-C 소스
- Game Mode process host의 소스와 build contract
- Game Mode unit/routing test와 Steam 세션 호환성 probe 소스
- ForgePlay가 작성한 Wine patch와 Windows launcher 소스
- XcodeGen project specification과 비개인 build setting
- 라이선스 원문, scope 기록, localized notice
- runtime provenance와 재구축 도구

의도적으로 제외되는 항목:

- `ForgePlay.app`, DMG, archive, notarization 자료
- 빌드된 Wine, D3DMetal, renderer, GStreamer, SDL 및 기타 바이너리
- 개인 Xcode 설정, signing team override, 인증서, 개인키와 credential
- 내부 계획 문서, QA evidence, 배포 세션 자료

`Resources/CompatibilityDBPublicKey.base64`는 선택적 compatibility DB
업데이트를 검증하는 공개키이며 개인 서명키가 아니다.

## Xcode project 생성

XcodeGen을 설치한 뒤 저장소 루트에서 다음을 실행한다.

```sh
Scripts/generate-xcode-project.sh
```

서명 없는 source-only build 확인:

```sh
xcodebuild build \
  -project ForgePlay.xcodeproj \
  -scheme ForgePlay \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

이 source-only export에는 Windows compatibility runtime 바이너리가
없으므로 이것만으로 Windows 게임을 실행할 수는 없다. runtime
재구축 정보는 `Resources/Runners/ForgePlayRuntime/`에, 관련 도구는
`Scripts/`에 있다.

## 라이선스

ForgePlay는 여러 라이선스가 적용되는 프로젝트다. 복사·수정·배포
전에 `LICENSE.md`를 읽어야 한다. `SOURCE-LICENSES.md`는 파일별 SPDX,
혼합 파일의 symbol scope, 두 Game Mode Wine patch의 `.license`
sidecar가 권위 있는 정책과 어떻게 연결되는지 설명한다.

ForgePlay Game Mode의 정확한 GPL-3.0-only 범위는
`LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md`에 기록되어
있다. 수정되지 않은 GPL/LGPL 원문은 `LICENSES/`에 포함되어 있다.
디렉터리 이름만으로 모든 파일이 하나의 라이선스로 일괄 변경됐다고
추정해서는 안 된다. 제3자 구성요소는 각각의 조건을 그대로 따른다.

---

ForgePlay Game Mode  
Copyright (C) 2026 Facta-Leopard  
Original source: https://github.com/Facta-Leopard/ForgePlay
