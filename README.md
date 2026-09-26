# ForgePlay

[![Game Mode — GPL-3.0-only](.github/assets/readme-game-mode-gpl.svg)](#game-mode-gpl)
[![Frame Generation — GPL-3.0-only](.github/assets/readme-frame-generation-gpl.svg)](#frame-generation-gpl)
[![DLSS5 Emulation — GPL-3.0-only](.github/assets/readme-dlss5-gpl.svg)](#dlss5-gpl)

[한국어](#한국어) · [English](#english)

## 한국어

**macOS에서 Windows 게임을 실행하고 즐기는 경험을 개선합니다.**

ForgePlay는 Wine을 기반으로 Windows 게임 실행 환경을 관리하는 macOS 앱입니다.
Game Mode 연동, 프레임 생성, HyPER-GAN 기반 DLSS5 Emulation, AWDL 제어와
게임용 단축키 설정을 제공합니다.

**Game Mode·Frame Generation·DLSS5 Emulation의 작성자 소유 네이티브 구현을
각각 GPL-3.0-only로 공개합니다.** 위 배지는 이 세 구현과 명시된 빌드 소스의
라이선스를 뜻하며, 앱 전체나 제3자 구성요소를 일괄 GPL로 지정하지 않습니다.

[최신 버전 다운로드](https://github.com/Facta-Leopard/ForgePlay/releases/latest) · [2.0.0 공개 소스](https://github.com/Facta-Leopard/ForgePlay/releases/download/v2.0.0/ForgePlay-2.0.0-6-OpenSource.tar.gz) · [홈페이지](https://facta-leopard.github.io/ForgePlay/) · [문제 제보](https://github.com/Facta-Leopard/ForgePlay/issues)

### ForgePlay를 만든 이유

Wine 생태계에 대한 CodeWeavers의 기여와 공로를 존중합니다. 다만 그 기여가
Wine의 공개 소스나 Windows 게임 호환 계층을 설계할 권리를 독점한다는 뜻은
아닙니다. **과거의 기여와 현재의 사용자 경험에 대한 요구는 별개입니다.**

ForgePlay는 macOS에서 Windows 게임을 즐길 때, CrossOver와 실질적으로
비교하고 선택할 수 있는 대안이 부족하다는 문제의식에서 출발했습니다.
선택지가 적으면 기존 방식을 돌아보거나 다른 구조의 가능성을 검증할 기회도
줄어듭니다. 이미 자리 잡은 제품이 있다는 이유로 새로운 시도가 멈춰서는
안 된다고 생각했습니다.

그래서 **“CrossOver와 다른 구현 경로도 실제로 동작할 수 있다”는 것을 직접
보여주기 위해 ForgePlay를 만들었습니다.** 실제로 사용할 수 있는 앱과
라이선스에 따라 공개하는 소스를 통해, 그 가능성을 누구나 확인할 수 있도록
하고자 합니다.

같은 문제를 해결한다는 사실만으로 한 제품이 다른 제품의 복제품이 되지는
않습니다. 판단의 기준은 이름이나 인상이 아니라 코드의 출처, 구현의 경계,
빌드 구조, 배포하는 구성요소와 각각의 라이선스입니다. 공개 대상 구현은
릴리스의 소스 압축파일로 제공합니다. 누구나 코드를 읽고 비교하며 설명과
실제 구현이 일치하는지 확인할 수 있습니다.

ForgePlay가 지향하는 차이는 게임을 실행시키는 데서 끝나지 않습니다.
“이미 실행되니 충분하다”는 기준에 머물지 않고, 사용 중 겪는 불편과 추가로
필요한 기능을 제품에 반영하는 것이 목표입니다. 프레임 생성, DLSS5 Emulation,
AWDL 제어와 게임용 단축키 설정은 이러한 문제의식에서 구상하고 구현했습니다.
Wine과 macOS의 기반 기술 위에 더한 기능의 가치는 실제 구현과 사용자
피드백으로 보여드리고자 합니다.

ForgePlay는 설치된 CrossOver를 실행하거나 감싸는 프런트엔드가 아니며,
CrossOver의 제품 번들·실행 파일·비공개 패치에 의존하지 않습니다.
공개 라이선스에 따라 배포된 Wine·제3자 수정분을 사용하는 것과 비공개 구현을
복제하는 것은 구분합니다. 사용한 공개 코드의 출처와 저작권은 보존하며,
그 부분까지 ForgePlay가 새로 작성했다고 주장하지 않습니다.

### 세 가지 GPL 공개 구현

아래 경로는 GitHub 기본 브랜치가 아니라 **2.0.0 릴리스에 별도로 첨부한
소스 압축본 내부 경로**입니다. 각 구현에 같은 GPL v3 원문을 적용하되,
공개 대상과 구현 근거를 구성요소별로 구분해 명시합니다.

<a id="game-mode-gpl"></a>

#### 1. ForgePlay Game Mode — GPL-3.0-only

**공개 범위:** `Native/GameModeProcessHost/`의 작성자 소유 구현과 고지에서
지정한 빌드 설정·스크립트. Wine에서 유래한 부분은 별도의 출처와 GPL 전환
고지를 함께 보존합니다.

**구현 방식:** 대상 Windows 프로세스를 고정된 네이티브 Mach-O 호스트로
연결하고, 동일한 프로세스 ID 안에서 Wine의 `ntdll.so`와 `__wine_main`으로
진입합니다. 호스트는 런타임 식별 정보와 실행 환경을 확인하고 Game Mode
지원 정보를 선언합니다. 실제 Game Mode 활성화 여부는 macOS가 판단합니다.

이는 ForgePlay가 별도로 빌드하는 호스트이지만, Wine 로더 전체를 처음부터
새로 작성했다는 뜻은 아닙니다. Wine 11.12에서 유래한 로더 진입부의 저작권과
라이선스 전환 근거를 공개 소스에 명시했습니다.

**확인할 근거:**

- `Native/GameModeProcessHost/GameModeProcessHost.m` — 호스트와 Wine 진입 구현
- `Native/GameModeProcessHost/SOURCE-CONTRACT.md` — Wine 유래 부분, 원본 해시와 구현 계약
- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch` — 호스트 연결
- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch` — 적용 대상 판정

<a id="frame-generation-gpl"></a>

#### 2. ForgePlay Frame Generation — GPL-3.0-only

**공개 범위:** `Native/D3DMetalFrameGenerationProxy/`의 작성자 소유 네이티브
구현과 지정된 빌드 자료. Wine·MoltenVK 쪽 연동 변경은 각 구성요소의 라이선스
경계를 따릅니다.

**구현 방식:** 원본 프레임을 바탕으로 GPU에서 중간 프레임을 만들고,
캡처·대기열·표시 시점을 관리합니다. 기본 혼합(Simple), 움직임 속도 우선
(Motion Lite), 정밀 추정(Motion Quality), 경계 복원(Motion Repair)의
네 가지 방식을 제공합니다. Metal 셰이더의 움직임 추정·보간 처리와 상태
관리 코드를 함께 공개합니다.

Frame Check는 원본 제출, AI 처리, 생성 프레임 표시와 최종 표시 FPS를
구분합니다. 보간을 계산했다는 사실만으로 실제 화면에 표시된 프레임이라고
집계하지 않습니다. 프레임 생성과 Frame Check는 각각 켜고 끌 수 있습니다.

**확인할 근거:**

- `Native/D3DMetalFrameGenerationProxy/ForgePlayD3DMetalFrameGenerationProxy.m` — 캡처·출력 연결
- `Native/D3DMetalFrameGenerationProxy/FrameGenerationMotion.metal` — GPU 움직임 추정·보간
- `Native/D3DMetalFrameGenerationProxy/FrameGenerationStateMachine.c` — 프레임 수명과 표시 상태 관리
- `Native/D3DMetalFrameGenerationProxy/WineD3DOpenGLFrameGeneration.inc` — OpenGL 연동
- `Tests/ForgePlayD3DMetalFrameGenerationProxyTests/` — 동봉된 관련 검증 코드

<a id="dlss5-gpl"></a>

#### 3. ForgePlay DLSS5 Emulation — GPL-3.0-only

**공개 범위:** `Native/NeuralRendering/`의 작성자 소유 네이티브 통합과
고지에 열거된 `Tools/NeuralRendering/`의 모델 변환·검증 코드 및 빌드 자료.
소스에서 사용하는 구성요소 이름은 **ForgePlay Neural Rendering**입니다.

**구현 방식:** Windows 게임이 렌더링한 완료 프레임에 HyPER-GAN 기반의
실사화 후처리를 연결합니다.

1. Metal에서 화면을 모델 입력으로 변환하고 공유 버퍼를 준비합니다.
2. 별도의 네이티브 추론 프로그램이 Core AI로 모델을 실행합니다.
   Neural Engine(NPU)을 우선 사용하도록 요청하며, 모든 연산의 NPU 전용
   실행을 보장한다는 뜻은 아닙니다.
3. Metal에서 추론 결과를 원래 화면과 합성하고 색조·보정 강도를 처리합니다.
4. 프레임 생성 및 최종 표시 경로와 연동합니다. 같은 프레임을 여러 번
   보정하는 횟수를 생성 FPS로 계산하지 않습니다.

**NVIDIA DLSS 5의 코드·모델·가중치를 포팅한 기능이 아닙니다.** HyPER-GAN의
공개된 사전 학습 가중치를 사용해 유사한 실사화 효과를 근사하는 별도
구현입니다. HyPER-GAN의 발명을 주장하거나 새 가중치를 학습한 것은 아닙니다.
모델 원본과 가중치·파생 모델 자료의 MIT 고지는 그대로 유지합니다.

`NeuralWorker.swift`는 비공개 앱 UI가 아니라 실제 추론에 필요한 **GPL 공개
helper**입니다. MLX·PyTorch 등은 모델 변환·검증을 위한 개발 도구이며,
게임 실행 시 Python 추론 환경을 함께 구동하는 방식은 아닙니다.

**확인할 근거:**

- `Native/NeuralRendering/NeuralFrameBridge.m` — 프레임 버퍼와 추론 프로그램 연결
- `Native/NeuralRendering/NeuralWorker.swift` — Core AI 추론·모델 무결성 확인
- `Native/NeuralRendering/NeuralFrameProcessor.m` 및 `NeuralRenderingStage.m` — 전후처리·표시 연동
- `Tools/NeuralRendering/` — 공개 범위에 명시된 가중치 변환·검증 코드
- `Upstream/HyPERGAN/manifest.json` — 원본 커밋·가중치·변환 결과의 출처와 해시
- `MODEL-BUILDING.md` — 모델 출처·변경 내역·재구축 절차

개발자는 2026년 9월 19일 MVP 테스트를 마친 상태에서 전후 비교 결과를
공개했습니다. [당시 결과 공개 기록](https://github.com/Facta-Leopard/ForgePlay/commit/d9fd184569e3bf737438630e10e731284d516e0d)은 공개 시점의 근거이며,
모든 게임의 성능이나 NPU 배치를 입증하는 자료로 확대 해석하지 않습니다.

### GPL 적용 범위와 제3자 라이선스

**세 가지 GPL 공개 구현과 제3자 기술, 비공개 UI의 적용 범위는 구분합니다.**

| 구분 | 적용 범위와 조건 |
| --- | --- |
| ForgePlay Game Mode | 지정된 작성자 소유 네이티브 구현·빌드 자료: **GPL-3.0-only** |
| ForgePlay Frame Generation | 지정된 작성자 소유 네이티브 구현·빌드 자료: **GPL-3.0-only** |
| ForgePlay DLSS5 Emulation / Neural Rendering | 지정된 작성자 소유 네이티브 통합·모델 변환·빌드 자료: **GPL-3.0-only** |
| Wine 및 Wine 유래 코드 | 원본의 **LGPL-2.1-or-later**와 지정 Game Mode 사본의 GPL 전환·저작권 고지를 보존 |
| HyPER-GAN 원본·가중치·파생 모델 자료 | **MIT** 고지와 Stefanos Pasios의 저작권을 보존. ForgePlay의 GPL 고지로 대체하지 않음 |
| MoltenVK 및 지정 캡처 패치 | **Apache-2.0**과 해당 제3자 고지를 보존 |
| DXVK·폰트·그 밖의 제3자 구성요소 | 각 구성요소의 원래 라이선스·저작권·적용 조건 유지 |
| Apple D3DMetal·Metal·Core AI | Apple의 별도 조건 적용. Apple 구현 자체를 GPL로 재라이선스하지 않음 |
| 작성자 소유 Swift 앱·런처 UI | 별도 바이너리 배포 허용에 따라 소스 공개 대상에서 제외. GPL 추론 helper는 이 제외 대상이 아님 |

Wine의 지정 Game Mode 변경은 [LGPL 2.1 제3항](https://github.com/wine-mirror/wine/blob/master/COPYING.LIB)에 따른 GPL 전환으로 고지합니다.
**이 GPL 변경을 포함한 Wine 파생 배포본의 의무는 패치 파일 두 개에만
한정되지 않습니다.** 해당 결합 파생물은 GPLv3에 맞게 배포하며, 원본 Wine과
별도 사본에 남아 있는 LGPL 권리 및 제3자 저작권은 보존합니다.

Swift라는 언어를 썼거나 프로세스를 분리했다는 이유만으로 공개 의무가
면제되는 것은 아닙니다. 비공개 UI의 별도 허용은 저작자 소유 기여분에만
적용되며, 네이티브 GPL 코드·Wine·다른 저작권자의 의무를 면제하지 않습니다.

### 공개 소스와 라이선스 근거

**Wine과 각 오픈소스 구성요소의 라이선스에 따른 배포 의무를 준수하기 위해,
실제 배포물에 대응하는 소스·수정 패치·필수 빌드 자료와 고지를 제공합니다.**
GPL로 공개한 세 구현의 이용·수정·재배포도 해당 라이선스에 따릅니다.

현재 공개본은 [ForgePlay 2.0.0 (Build 6) 릴리스](https://github.com/Facta-Leopard/ForgePlay/releases/tag/v2.0.0)에 첨부되어 있습니다.

- [ForgePlay-2.0.0-6-OpenSource.tar.gz](https://github.com/Facta-Leopard/ForgePlay/releases/download/v2.0.0/ForgePlay-2.0.0-6-OpenSource.tar.gz)
- [ForgePlay-2.0.0-6-SHA256SUMS.txt](https://github.com/Facta-Leopard/ForgePlay/releases/download/v2.0.0/ForgePlay-2.0.0-6-SHA256SUMS.txt)

압축본의 다음 파일에서 범위와 대응 관계를 확인할 수 있습니다.

- `LICENSE.md` — 2.0 전체 라이선스 구성 안내
- `LICENSES/ForgePlayRelease20/LICENSE.txt` — 세 구현의 GPL 범위·저작자 고지·별도 UI 허용
- `LICENSES/ForgePlayRelease20/SOURCE-SCOPE.json` — GPL 고지 대상 파일과 SHA-256
- `SOURCE-FILES.json` — 공개 파일 전체의 해시와 대응 DMG 식별 정보
- `BUILDING.md`, `MODEL-BUILDING.md` — 네이티브·Wine·모델 재구축 안내
- `ThirdPartyCorrespondingSource/relinking/` — 제3자 구성요소의 교체·재링크 안내

이 공개본은 빌드 당시 미커밋 변경을 포함한 소스 스냅샷입니다. 기록된 과거
Git 기준 커밋이나 이후 정리한 커밋 하나만으로 해당 바이너리가 재현된다고
표시하지 않으며, 파일별 해시와 배포물 대응 정보를 기준으로 합니다.

GitHub가 자동 표시하는 `Source code (zip/tar.gz)`는 저장소 태그의 스냅샷입니다.
**배포물의 대응 소스는 위에 직접 첨부한 압축파일을 사용해 주세요.**
공개 대상 소스가 바뀌지 않은 유지보수 버전은 기존 대응 아카이브를 안내할 수
있습니다. 압축파일로 제공하는 방식은 라이선스가 허용하는 복사·수정·재배포
권리를 제한하지 않습니다.

### 저작권과 재배포 고지

ForgePlay 작성 부분의 저작자: **[Facta-Leopard](https://github.com/Facta-Leopard)**

**Copyright © 2026 Facta-Leopard**

재배포할 때에는 해당 구성요소의 저작권·출처·라이선스와 적용되는 고지를
보존하고, 수정본은 수정 사실을 표시해 주세요. 공식 ForgePlay 배포물이나
저작자가 보증하는 배포물로 오인하게 표시해서는 안 됩니다. GPL 조건을
준수하는 이용에는 상업적 이용도 포함됩니다.

이 README는 적용 범위와 구현을 설명하는 안내입니다. 실제 조건은 해당
공개본의 라이선스 원문과 구성요소별 고지를 기준으로 하며, 제3자의 권리나
상표권을 새로 부여하지 않습니다.

### 실행 결과를 알려주세요

**잘 되는 게임과 실행되지 않는 게임 모두 도움이 됩니다.**

[GitHub Issues](https://github.com/Facta-Leopard/ForgePlay/issues)에 ForgePlay 버전, Mac 사양, 게임명, 그래픽 백엔드와
DLSS5·프레임 생성 사용 여부를 함께 알려주세요. 실제 사용 환경의 피드백을
바탕으로 호환성과 사용성을 개선하겠습니다.

---

## English

**A better Windows gaming experience on macOS—from launching to playing.**

ForgePlay is a macOS app that manages Windows gaming environments built on Wine.
It provides Game Mode integration, frame generation, HyPER-GAN-based DLSS5
Emulation, AWDL controls, and game-oriented shortcut settings.

**The author-owned native implementations of Game Mode, Frame Generation, and
DLSS5 Emulation are each published under GPL-3.0-only.** The badges refer to
these three implementations and the explicitly identified build sources, not
a blanket GPL license for the entire app or its third-party components.

[Download the latest version](https://github.com/Facta-Leopard/ForgePlay/releases/latest) · [2.0.0 source archive](https://github.com/Facta-Leopard/ForgePlay/releases/download/v2.0.0/ForgePlay-2.0.0-6-OpenSource.tar.gz) · [Website](https://facta-leopard.github.io/ForgePlay/) · [Report an issue](https://github.com/Facta-Leopard/ForgePlay/issues)

### Why ForgePlay was created

We respect CodeWeavers' contributions to the Wine ecosystem. Those contributions
do not confer exclusive ownership of Wine's public source or an exclusive right
to design a Windows-game compatibility layer. **Past contributions and
present-day user expectations are separate matters.**

ForgePlay began with a concern that macOS users had too few alternatives they
could meaningfully compare with CrossOver for Windows gaming. Limited choice
also means fewer opportunities to question established approaches or test a
different architecture. The existence of an established product should not be
a reason to stop exploring alternatives.

**ForgePlay was created to demonstrate that an implementation path different
from CrossOver can actually work.** A working app and source published under
the applicable licenses allow others to see that possibility for themselves.

Solving the same problem does not by itself make one product a copy of another.
What matters is code provenance, implementation boundaries, build structure,
shipped components, and their respective licenses—not names or impressions.
The published implementation is available in source archives attached to
releases. Anyone can inspect and compare the code and check the descriptions
against the implementation.

ForgePlay's goals extend beyond getting a game to launch. It aims to address
practical frustrations and add useful features, rather than treating “the game
already launches” as the finish line. Frame generation, DLSS5 Emulation, AWDL
controls, and game-oriented shortcut settings were conceived and implemented
in response to those needs. We aim to demonstrate the value of these additions
to Wine and macOS technologies through the implementation and user feedback.

ForgePlay is not a front end that launches or wraps an installed copy of
CrossOver, and it does not depend on CrossOver product bundles, executables,
or private patches. Using Wine and third-party modifications distributed
under public licenses is distinct from copying a private implementation.
The provenance and copyrights of reused public code are preserved; we do
not claim to have newly authored those parts.

### Three separately identified GPL implementations

The paths below refer to **the source archive attached separately to the 2.0.0
release**, not this repository's default branch. The same GPL v3 license text
applies to each implementation, with the covered material and implementation
evidence identified separately for each component.

<a id="game-mode-gpl-en"></a>

#### 1. ForgePlay Game Mode — GPL-3.0-only

**Published scope:** The author-owned implementation in
`Native/GameModeProcessHost/` and the build settings/scripts identified in
the notice. Wine-derived material retains its separate provenance and GPL
conversion notices.

**Implementation:** Eligible Windows processes are routed through a fixed
native Mach-O host, which enters Wine's `ntdll.so` and `__wine_main` within
the same process ID. The host checks the runtime identity and execution
environment and declares Game Mode support. macOS determines whether
Game Mode actually activates.

Although this is a host built separately by ForgePlay, it is not a claim
that the entire Wine loader was written from scratch. The published source
identifies the Wine 11.12-derived loader entry code, its copyrights, and the
basis for its license conversion.

**Implementation evidence:**

- `Native/GameModeProcessHost/GameModeProcessHost.m` — host and Wine entry implementation
- `Native/GameModeProcessHost/SOURCE-CONTRACT.md` — Wine-derived portions, upstream hashes, and implementation contract
- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch` — host routing
- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch` — target classification

<a id="frame-generation-gpl-en"></a>

#### 2. ForgePlay Frame Generation — GPL-3.0-only

**Published scope:** The author-owned native implementation in
`Native/D3DMetalFrameGenerationProxy/` and the identified build materials.
Integration changes on the Wine and MoltenVK sides follow those components'
respective license boundaries.

**Implementation:** Intermediate frames are generated on the GPU from source
frames, with capture, queues, and presentation timing managed by the native
pipeline. Four methods are available: Simple blending, speed-focused
Motion Lite, precise Motion Quality, and Motion Repair for boundary repair.
The Metal motion-estimation/interpolation shaders and state-management code
are published together.

Frame Check distinguishes original submissions, AI processing, generated-frame
presentation, and final presentation FPS. Computing an interpolated frame
does not by itself count as actually displaying it. Frame generation and
Frame Check can be enabled or disabled separately.

**Implementation evidence:**

- `Native/D3DMetalFrameGenerationProxy/ForgePlayD3DMetalFrameGenerationProxy.m` — capture and output integration
- `Native/D3DMetalFrameGenerationProxy/FrameGenerationMotion.metal` — GPU motion estimation and interpolation
- `Native/D3DMetalFrameGenerationProxy/FrameGenerationStateMachine.c` — frame lifetime and presentation-state management
- `Native/D3DMetalFrameGenerationProxy/WineD3DOpenGLFrameGeneration.inc` — OpenGL integration
- `Tests/ForgePlayD3DMetalFrameGenerationProxyTests/` — accompanying verification code

<a id="dlss5-gpl-en"></a>

#### 3. ForgePlay DLSS5 Emulation — GPL-3.0-only

**Published scope:** The author-owned native integration in
`Native/NeuralRendering/`, the model-conversion/verification files enumerated
in the notice under `Tools/NeuralRendering/`, and the identified build materials.
The component's name in the source is **ForgePlay Neural Rendering**.

**Implementation:** HyPER-GAN-based photorealistic post-processing is applied
to completed frames rendered by Windows games.

1. Metal converts the image into model input and prepares shared buffers.
2. A separate native inference program runs the model through Core AI.
   It requests the Neural Engine (NPU) as the preferred compute unit; this
   does not guarantee exclusive NPU execution of every operation.
3. Metal composites the inference result with the original image and handles
   color tones and adjustment strength.
4. The result is integrated with frame generation and final presentation.
   Repeatedly processing the same frame does not count as generated FPS.

**This is not a port of NVIDIA DLSS 5 code, models, or weights.** It is a separate
implementation that uses publicly available pretrained HyPER-GAN weights to
approximate a similar photorealistic effect. We do not claim to have invented
HyPER-GAN or trained new weights. MIT notices are preserved for the original
model, weights, and derived model material.

`NeuralWorker.swift` is the **GPL-published helper** needed for actual inference,
not the private app UI. MLX and PyTorch are development tools for model
conversion and verification; the game does not run a bundled Python inference
environment.

**Implementation evidence:**

- `Native/NeuralRendering/NeuralFrameBridge.m` — frame buffers and inference-program connection
- `Native/NeuralRendering/NeuralWorker.swift` — Core AI inference and model-integrity checks
- `Native/NeuralRendering/NeuralFrameProcessor.m` and `NeuralRenderingStage.m` — preprocessing, post-processing, and presentation integration
- `Tools/NeuralRendering/` — weight-conversion and verification code identified in the published scope
- `Upstream/HyPERGAN/manifest.json` — upstream commit, weights, conversion provenance, and hashes
- `MODEL-BUILDING.md` — model provenance, modifications, and rebuild instructions

The developer published before-and-after results on September 19, 2026 after
completing MVP testing. [The original publication record](https://github.com/Facta-Leopard/ForgePlay/commit/d9fd184569e3bf737438630e10e731284d516e0d)
establishes the publication timing; it should not be interpreted as evidence
of performance in every game or of NPU placement.

### GPL scope and third-party licenses

**The three GPL implementations, third-party technologies, and private UI
have distinct licensing scopes.**

| Component | Scope and terms |
| --- | --- |
| ForgePlay Game Mode | Identified author-owned native implementation and build materials: **GPL-3.0-only** |
| ForgePlay Frame Generation | Identified author-owned native implementation and build materials: **GPL-3.0-only** |
| ForgePlay DLSS5 Emulation / Neural Rendering | Identified author-owned native integration, model-conversion code, and build materials: **GPL-3.0-only** |
| Wine and Wine-derived code | Preserve upstream **LGPL-2.1-or-later**, the GPL conversion of identified Game Mode copies, and original copyright notices |
| Original HyPER-GAN, weights, and derived model material | Preserve the **MIT** notice and Stefanos Pasios's copyright; ForgePlay's GPL notice does not replace them |
| MoltenVK and the identified capture patch | Preserve **Apache-2.0** and the applicable third-party notices |
| DXVK, fonts, and other third-party components | Retain each component's original license, copyrights, and applicable terms |
| Apple D3DMetal, Metal, and Core AI | Separate Apple terms apply; Apple's implementations are not relicensed under GPL |
| Author-owned Swift app and launcher UI | Excluded from source publication under separate binary-distribution permission; the GPL inference helper is not part of this exclusion |

The identified Game Mode changes to Wine are notified as a GPL conversion
under [LGPL 2.1 section 3](https://github.com/wine-mirror/wine/blob/master/COPYING.LIB).
**The obligations for a Wine derivative containing those GPL changes are not
limited to the two patch files.** That combined derivative is distributed
consistently with GPLv3, while preserving the LGPL rights in upstream Wine and
other separate copies, as well as third-party copyrights.

Writing code in Swift or placing it in a separate process does not by itself
remove source-publication obligations. The separate permission for the private
UI applies only to the author's own contributions and does not waive
obligations for native GPL code, Wine, or another copyright holder's material.

### Published sources and license evidence

**To comply with the distribution obligations of Wine and the other open-source
components, we provide source corresponding to the actual distribution,
modification patches, required build materials, and notices.** Use,
modification, and redistribution of the three GPL implementations are also
governed by their applicable licenses.

The current source package is attached to the
[ForgePlay 2.0.0 (Build 6) release](https://github.com/Facta-Leopard/ForgePlay/releases/tag/v2.0.0).

- [ForgePlay-2.0.0-6-OpenSource.tar.gz](https://github.com/Facta-Leopard/ForgePlay/releases/download/v2.0.0/ForgePlay-2.0.0-6-OpenSource.tar.gz)
- [ForgePlay-2.0.0-6-SHA256SUMS.txt](https://github.com/Facta-Leopard/ForgePlay/releases/download/v2.0.0/ForgePlay-2.0.0-6-SHA256SUMS.txt)

The following files in the archive identify the scope and release correspondence:

- `LICENSE.md` — overview of the 2.0 licensing arrangement
- `LICENSES/ForgePlayRelease20/LICENSE.txt` — the three implementations' GPL scopes, author notices, and separate UI permission
- `LICENSES/ForgePlayRelease20/SOURCE-SCOPE.json` — files identified by the GPL notice and their SHA-256 hashes
- `SOURCE-FILES.json` — hashes of all published files and the corresponding DMG identity
- `BUILDING.md` and `MODEL-BUILDING.md` — native, Wine, and model rebuild instructions
- `ThirdPartyCorrespondingSource/relinking/` — third-party replacement and relinking instructions

This source package is a snapshot containing changes that were uncommitted
at build time. Neither its historical Git base nor a later housekeeping commit
alone is represented as reproducing the binary. File hashes and the recorded
source-to-distribution correspondence are authoritative.

GitHub's automatic `Source code (zip/tar.gz)` links are snapshots of the
repository tag. **Use the explicitly attached archive above for the
distribution's corresponding source.** Maintenance releases with unchanged
covered sources may refer to an existing corresponding archive. Archive-based
delivery does not restrict the copying, modification, or redistribution
rights granted by the applicable licenses.

### Copyright and redistribution notices

Author of ForgePlay-authored material: **[Facta-Leopard](https://github.com/Facta-Leopard)**

**Copyright © 2026 Facta-Leopard**

When redistributing, preserve the relevant component's copyrights, provenance,
licenses, and applicable notices, and identify modified versions as modified.
Do not misrepresent them as official ForgePlay releases or distributions
endorsed by the author. Use that complies with the GPL includes commercial use.

This README explains scope and implementation. The actual terms are the license
texts and component-specific notices in the relevant source package; this
README grants no new third-party or trademark rights.

### Share your game results

**Reports of both working and non-working games are useful.**

Please include your ForgePlay version, Mac specifications, game title, graphics
backend, and whether DLSS5 and frame generation were enabled when reporting
through [GitHub Issues](https://github.com/Facta-Leopard/ForgePlay/issues).
Feedback from real-world use helps us improve compatibility and usability.
