# ForgePlay

![Game Mode — GPL-3.0-only](https://img.shields.io/badge/Game_Mode-GPL--3.0--only-blue)
![Frame Generation — GPL-3.0-only](https://img.shields.io/badge/Frame_Generation-GPL--3.0--only-blue)
![DLSS5 Emulation — GPL-3.0-only](https://img.shields.io/badge/DLSS5_Emulation-GPL--3.0--only-blue)
![AI Coordinator — GPL-3.0-only](https://img.shields.io/badge/AI_Coordinator-GPL--3.0--only-blue)
![ForgePlay VR & ForgePlayVP — GPL-3.0-only](https://img.shields.io/badge/ForgePlay_VR_%26_ForgePlayVP-GPL--3.0--only-blue)

[한국어](#한국어) · [English](#english)

## 한국어

**macOS에서 Windows 게임을 실행하고 즐기는 경험을 개선합니다.**

ForgePlay는 Wine 기반의 Windows 게임 실행 환경을 관리하는 macOS 앱입니다. 통합 런처 **ForgePlay**와 게임 실행 환경 **ForgePlay Mac**을 통해 Game Mode 연동, 프레임 생성, HyPER-GAN 기반 DLSS5 Emulation, AI Coordinator, AWDL 제어와 게임용 단축키 설정을 제공합니다.

**Game Mode·Frame Generation·DLSS5 Emulation·AI Coordinator와 ForgePlay VR·ForgePlayVP의 지정된 자체 구현에는 각각 GPL-3.0-only를 적용합니다.**

배지는 해당 구현의 라이선스를 나타냅니다. 앱 전체, 별도 허가된 호스트 래퍼, 모델 가중치, 아트워크와 제3자 구성요소에 하나의 GPL 라이선스를 일괄 적용한다는 뜻은 아닙니다. 정확한 공개 범위와 추가 허가는 구성요소별 고지를 따릅니다.

[최신 버전 다운로드](https://github.com/Facta-Leopard/ForgePlay/releases/latest) · [2.2.0 공개 소스](https://github.com/Facta-Leopard/ForgePlay/releases/download/v2.2.0/ForgePlay-2.2.0-8-OpenSource.tar.gz) · [홈페이지](https://facta-leopard.github.io/ForgePlay/) · [문제 제보](https://github.com/Facta-Leopard/ForgePlay/issues)

### ForgePlay를 만든 이유

Wine 생태계에 대한 CodeWeavers의 기여와 공로를 존중합니다. 다만 그 기여가 Wine의 공개 소스나 Windows 게임 호환 계층을 설계할 권리를 독점한다는 뜻은 아닙니다. **과거의 기여와 현재의 사용자 경험에 대한 요구는 별개입니다.**

ForgePlay는 macOS에서 Windows 게임을 즐길 때, CrossOver와 실질적으로 비교하고 선택할 수 있는 대안이 부족하다는 문제의식에서 출발했습니다. 선택지가 적으면 기존 방식을 돌아보거나 다른 구조의 가능성을 검증할 기회도 줄어듭니다. 이미 자리 잡은 제품이 있다는 이유로 새로운 시도가 멈춰서는 안 된다고 생각했습니다.

그래서 **“CrossOver와 다른 구현 경로도 실제로 동작할 수 있다”는 것을 직접 보여주기 위해 ForgePlay를 만들었습니다.** 실제로 사용할 수 있는 앱과 라이선스에 따라 공개하는 소스를 통해, 그 가능성을 누구나 확인할 수 있도록 하고자 합니다.

같은 문제를 해결한다는 사실만으로 한 제품이 다른 제품의 복제품이 되지는 않습니다. 판단의 기준은 이름이나 인상이 아니라 코드의 출처, 구현의 경계, 빌드 구조, 배포하는 구성요소와 각각의 라이선스입니다. 공개 대상 구현은 릴리스의 소스 압축파일로 제공합니다. 누구나 코드를 읽고 비교하며 설명과 실제 구현이 일치하는지 확인할 수 있습니다.

ForgePlay가 지향하는 차이는 게임을 실행시키는 데서 끝나지 않습니다. “이미 실행되니 충분하다”는 기준에 머물지 않고, 사용 중 겪는 불편과 추가로 필요한 기능을 제품에 반영하는 것이 목표입니다. 프레임 생성, DLSS5 Emulation, AI Coordinator, AWDL 제어와 게임용 단축키 설정은 이러한 문제의식에서 구상하고 구현했습니다. Wine과 macOS의 기반 기술 위에 더한 기능의 가치는 실제 구현과 사용자 피드백으로 보여드리고자 합니다.

ForgePlay는 설치된 CrossOver를 실행하거나 감싸는 프런트엔드가 아니며, CrossOver의 제품 번들·실행 파일·비공개 패치에 의존하지 않습니다. 공개 라이선스에 따라 배포된 Wine·제3자 수정분을 사용하는 것과 비공개 구현을 복제하는 것은 구분합니다. 사용한 공개 코드의 출처와 저작권은 보존하며, 그 부분까지 ForgePlay가 새로 작성했다고 주장하지 않습니다.

### GPL로 공개하는 자체 구현

아래 구현 경로는 **2.2.0 공개 소스의 원래 소스 구조를 기준**으로 합니다. 압축본은 자체 구현·Wine·제3자·빌드·고지를 구분해 보관하므로, 실제 보관 위치와 원래 경로의 대응은 `SOURCE-BOUNDARIES.json`에서 확인해 주세요. GitHub 기본 브랜치의 파일 위치와 다를 수 있습니다.

각 구현에는 같은 GPL v3 원문을 적용하되, 작성자 소유 기여분·Wine 유래 코드·제3자 자료·별도 허락의 범위를 구분합니다.

#### 1. ForgePlay Game Mode — GPL-3.0-only

**공개 범위:** `Mac/Native/GameModeProcessHost/`의 지정된 구현과 필요한 빌드 자료입니다. Wine에서 유래한 부분에는 원저작자의 고지와 해당 GPL 전환 고지를 함께 보존합니다.

**구현 방식:** 대상 Windows 프로세스를 고정된 네이티브 Mach-O 호스트로 연결하고, 같은 프로세스 안에서 Wine의 `ntdll.so`와 `__wine_main`으로 진입합니다. 호스트는 런타임 식별 정보와 실행 환경을 확인하고 Game Mode 지원 정보를 선언합니다. 실제 Game Mode 활성화 여부는 macOS가 판단합니다.

Wine 로더 전체를 처음부터 새로 작성했다는 뜻은 아닙니다. Wine 유래 부분과 자체 수정의 근거는 다음 자료에서 확인할 수 있습니다.

- `Mac/Native/GameModeProcessHost/GameModeProcessHost.m`
- `Mac/Native/GameModeProcessHost/SOURCE-CONTRACT.md`
- `Mac/Resources/Runners/ForgePlayRuntime/Patches/`의 Game Mode 연결·대상 판정 패치
- `LICENSES/ForgePlayRelease13/WINE-GAME-MODE-NOTICE.txt`

#### 2. ForgePlay Frame Generation — GPL-3.0-only

**공개 범위:** `Mac/Native/D3DMetalFrameGenerationProxy/`의 지정된 자체 구현과 빌드 자료입니다. Wine·MoltenVK의 연동 변경은 각각의 라이선스 경계를 따릅니다.

**구현 방식:** 원본 프레임을 바탕으로 GPU에서 중간 프레임을 만들고, 캡처·대기열·프레임 수명·표시 시점을 관리합니다. Simple, Motion Lite, Motion Quality, Motion Repair의 네 가지 방식을 제공합니다.

Frame Check는 원본 제출, AI 처리, 프레임 생성 완료와 최종 화면 표시를 구분합니다. **FG는 생성 처리 완료 속도, Displayed는 실제 표시가 확인된 최종 프레임 속도**입니다. 계산 완료를 화면 표시와 동일하게 취급하지 않습니다.

주요 구현은 다음 파일에 있습니다.

- `Mac/Native/D3DMetalFrameGenerationProxy/ForgePlayD3DMetalFrameGenerationProxy.m`
- `Mac/Native/D3DMetalFrameGenerationProxy/FrameGenerationMotion.metal`
- `Mac/Native/D3DMetalFrameGenerationProxy/FrameGenerationStateMachine.c`
- `Mac/Native/D3DMetalFrameGenerationProxy/WineD3DOpenGLFrameGeneration.inc`

#### 3. ForgePlay DLSS5 Emulation — GPL-3.0-only

**공개 범위:** `Mac/Native/NeuralRendering/`의 지정된 자체 통합 구현과 고지에 명시된 모델 변환·검증·빌드 자료입니다. 소스에서 사용하는 구성요소 이름은 **ForgePlay Neural Rendering**입니다.

**구현 방식:** Windows 게임의 완료된 화면에 HyPER-GAN 기반 실사화 후처리를 연결합니다. Metal이 입력 준비와 결과 합성을 담당하고, 별도의 추론 프로그램이 Core AI로 모델을 실행합니다. Neural Engine을 우선 사용하도록 요청하지만 모든 연산의 NPU 전용 실행을 보장하지는 않습니다.

**NVIDIA DLSS 5의 코드·모델·가중치를 포팅한 기능이 아닙니다.** 공개된 HyPER-GAN 사전 학습 가중치를 활용한 별도 구현이며, 원본·가중치·파생 모델 자료의 MIT 고지와 원저작권을 유지합니다.

`NeuralWorker.swift`는 앱 UI가 아니라 실제 추론을 실행하는 **GPL 공개 런타임**입니다.

- `Mac/Native/NeuralRendering/NeuralFrameBridge.m`
- `Mac/Native/NeuralRendering/NeuralWorker.swift`
- `Mac/Native/NeuralRendering/NeuralFrameProcessor.m`
- `Mac/Native/NeuralRendering/NeuralRenderingStage.m`
- `Mac/Tools/NeuralRendering/`
- `LICENSES/HyPERGAN/`

개발자는 2026년 9월 19일 MVP 테스트 후 전후 비교 결과를 공개했습니다. [당시 공개 기록](https://github.com/Facta-Leopard/ForgePlay/commit/d9fd184569e3bf737438630e10e731284d516e0d)은 공개 시점의 근거이며, 모든 게임의 성능을 보장하는 자료는 아닙니다.

#### 4. ForgePlay AI Coordinator — GPL-3.0-only

**공개 범위:** 시각 인식·프레임 처리·추론 제어·음성 통합을 수행하는 실제 런타임과 지정된 네이티브 연동 구현입니다. 정확한 파일 목록은 `LICENSES/ForgePlayCoordinator/SCOPE.json`에 있습니다. 별도로 지정된 상호운용 계약 선언 두 파일은 MIT입니다.

**구현 방식:** 기존 GPU 렌더링과 별도의 비동기 경로에서 OWLv2 시각 인식을 수행합니다. OWLv2의 Core ML 모델은 CPU·Neural Engine을 사용하도록 구성하며, 화면에 대상 후보의 영역을 표시합니다.

Apple의 온디바이스 Foundation Models에는 장면 이미지와 같은 프레임의 후보 영역 좌표를 전달해 설명·대화에 활용합니다. 검출 결과를 확정된 적·아군 정보로 취급하거나, 박스와 문장이 항상 동시에 갱신된다고 가정하지 않습니다.

이 기능의 시각 인식과 설명·대화는 외부 AI 추론 API 없이 로컬에서 처리합니다. 화면 복사·전처리까지 GPU를 전혀 사용하지 않는다는 뜻은 아닙니다.

주요 공개 구현은 다음과 같습니다.

- `Mac/Coordinator/Core/CoordinatorModel.swift` — 모델 로딩·추론·결과 처리
- `Mac/Coordinator/Core/CoordinatorWorker.swift` — worker 실행과 Apple 모델 연동
- `Mac/Coordinator/Core/CoordinatorDomain.swift` — 관측 식별과 결과 정책
- `Mac/Coordinator/Shared/`의 지정된 런타임 파일 — 입력 구성·대상 처리·음성 제어
- `Mac/Coordinator/Speech/` — 음성 엔진 연동
- `Mac/Native/VisualCoordinator/` — 캡처·전달·권한·영역 표시

**실제 worker와 공유 런타임에 필요한 Swift 8개 파일도 공개 대상입니다.** 일반 UI·연결 래퍼와 구현 역할이 다르므로, Swift라는 확장자만으로 일괄 제외하지 않습니다.

#### 5. ForgePlay VR 및 ForgePlayVP — GPL-3.0-only

**공개 범위:** Mac VR 런타임, Vision Pro용 ForgePlayVP, 공통 전송·영상·입력 구현과 이를 빌드하는 데 필요한 자체 지원 코드·빌드 자료입니다. 정확한 범위는 소스 아카이브의 `Notices/LICENSES/ForgePlayVR/SCOPE.json`, 적용 조건은 같은 폴더의 `NOTICE.txt`에 명시합니다.

**구현 방식:** Wine에서 실행하는 Windows VR 게임과 Mac·Vision Pro 사이의 영상 및 입력 전달을 연결합니다. Mac/Wine 사이의 공유 메모리 전달과 Mac/Vision Pro 사이의 네트워크 전송을 구분하고, 화면 전달·헤드 트래킹·핸드 트래킹·게임패드 입력을 처리합니다. 현재 연결 구성에는 AWDL 실시간 연결 모드를 활용합니다.

이 자체 구현에는 실제 동작을 담당하는 Swift 코드도 포함됩니다. **ForgePlayVP와 공통 VR 런타임을 단순 UI 래퍼로 분류해 공개 대상에서 제외하지 않습니다.**

Wine에서 유래한 `VRUnixBootstrap.cpp`는 원저작권과 **LGPL-2.1-or-later 및 추가 링크 허가**를 유지합니다. Valve의 OpenVR 공개 헤더와 생성된 선언은 **BSD-3-Clause**를 따릅니다. 이 부분을 ForgePlay의 독자 작성 코드로 표시하거나 자체 GPL 고지로 재라이선스하지 않습니다.

여기서 ‘자체 구현’은 공개 인터페이스를 이용해 작성한 ForgePlay의 구현을 뜻합니다. Wine·SteamVR·OpenVR·Apple 프레임워크·게임 또는 관련 표준 자체의 소유권을 주장하는 표현이 아닙니다.

> **Vision Pro 앱 출시 안내:** ForgePlayVP는 별도로 Vision Pro App Store 심사 제출을 준비하고 있습니다. 향후 앱 출시 소식은 [ForgePlay 홈페이지](https://facta-leopard.github.io/ForgePlay/)에서 확인해 주세요. 소스 공개와 App Store 앱 출시는 별도의 절차입니다.

### 공개 런타임과 별도 허가된 호스트 래퍼

ForgePlay의 공개 범위는 **프로그래밍 언어가 아니라 실제 구현 역할과 명시된 이용허락**을 기준으로 정합니다.

- 게임 실행·그래픽 처리·추론·제어·VR 전송 및 입력을 담당하는 공개 대상 런타임은 해당 GPL 범위에 포함합니다.
- 고지에 정확히 지정된 저작자 소유 Mac 런처·데스크탑 UI와 입력·연결 래퍼에는 별도의 바이너리 배포 허가가 적용됩니다.
- 자체 GPL 기여분과 해당 래퍼를 결합하는 데 필요한 추가 허가는 각 고지에 명시된 범위에 한합니다.
- 이 허가는 실제 런타임, Wine 유래 코드 또는 다른 저작권자의 자료에 대한 공개·배포 의무를 면제하지 않습니다.
- 기존에 부여된 GPL 권리는 철회하지 않습니다.

구체적인 조건은 `Notices/LICENSES/ForgePlayWrapper/PERMISSION.txt`와 `SCOPE.json`, 기존 Game Mode·Frame Generation 고지, VR의 `NOTICE.txt`를 함께 확인해 주세요.

**Swift 파일이라는 이유만으로 모두 비공개가 되는 것은 아닙니다.** 실제 추론을 수행하는 `NeuralWorker.swift`, AI Coordinator의 공개 대상 worker·공유 런타임, ForgePlayVP와 공통 VR 구현은 공개 범위에 포함됩니다.

프로세스·IPC·폴더를 분리했다는 사실만으로 라이선스 의무가 없어지는 것도 아닙니다. 별도 허가는 그 원문에서 지정한 저작자 소유 기여분에만 적용됩니다.

### Wine과 제3자 라이선스

ForgePlay는 여러 라이선스가 함께 적용되는 배포물입니다. 자체 작성 코드와 기존 공개 코드를 구분하며, 재사용한 자료의 원저작권·출처·라이선스 고지를 유지합니다.

| 구성요소 | 적용 라이선스와 경계 |
| --- | --- |
| ForgePlay의 지정된 자체 런타임 | GPL-3.0-only 및 구성요소별로 명시된 추가 허가 |
| Wine과 Wine 유래 코드 | LGPL-2.1-or-later 및 개별 고지. 지정된 Game Mode 호스트·패치 사본은 기존 GPL-3.0-only 전환 고지 유지 |
| VR의 Wine 파생 Unix 로더 | LGPL-2.1-or-later 및 원문의 추가 링크 허가 |
| Valve OpenVR 공개 헤더·생성 선언 | BSD-3-Clause |
| HyPER-GAN | MIT. 원본·가중치·파생 모델 자료의 고지 유지 |
| OWLv2 | Apache-2.0 |
| Supertonic 2 모델·음성 스타일 가중치 | BigScience Open RAIL-M. 자체 GPL 코드와 구분 |
| Supertonic 참조 코드·ONNX Runtime | MIT 및 해당 의존성 고지 |
| MoltenVK·DXMT·DXVK·GStreamer·폰트·기타 의존성 | 각 구성요소의 개별 라이선스와 고지 |
| 위쳐 3 호환성 어댑터 | 원저작권과 수정 고지를 보존한 MIT. 게임 원본 DLL은 포함하지 않음 |
| Apple D3DMetal·시스템 프레임워크·모델 | Apple의 별도 조건. ForgePlay의 GPL 선언으로 재라이선스하지 않음 |

지정된 Game Mode 사본에는 [LGPL 2.1 제3항](https://github.com/wine-mirror/wine/blob/master/COPYING.LIB)에 따른 기존 GPL 전환 고지를 유지합니다. **관련 Wine 파생 배포본의 의무를 패치 파일만 공개하는 것으로 한정하지 않습니다.** 원본 Wine과 별도 사본의 LGPL 권리, 제3자 저작권과 적용 가능한 대응 소스·빌드 자료 제공 의무도 유지합니다.

### 공개 소스는 릴리스 첨부파일로 제공합니다

**Wine과 각 구성요소의 라이선스에 따른 배포 의무를 이행하기 위해, 실제 배포물에 대응하는 공개 소스·수정 패치·필수 빌드 자료·저작권 및 라이선스 고지를 GitHub 릴리스에 별도 압축파일로 제공합니다.**

현재 공개본은 [ForgePlay 2.2.0 (Build 8)](https://github.com/Facta-Leopard/ForgePlay/releases/tag/v2.2.0)에 첨부한 [ForgePlay-2.2.0-8-OpenSource.tar.gz](https://github.com/Facta-Leopard/ForgePlay/releases/download/v2.2.0/ForgePlay-2.2.0-8-OpenSource.tar.gz)입니다.

2.2.0 소스 패키지는 다음과 같이 구분합니다.

| 파일·폴더 | 내용 |
| --- | --- |
| `ForgePlay/` | 공개 대상 자체 구현, VR·ForgePlayVP와 공용 지원 코드 |
| `Wine/` | Wine 원본 소스, 해당 버전의 패치와 Wine 유래 코드 |
| `ThirdParty/` | 제3자 원본·명시된 수정본 및 대응 소스 |
| `Build/` | 필요한 빌드·패키징 도구와 설정 |
| `Notices/` | 라이선스 전문, 원저작권, 출처와 정확한 적용 범위 |
| `SOURCE-BOUNDARIES.json` | 원래 소스 경로와 공개 사본·빌드 입력의 대응 해시 |
| `restore-layout.py` | 공개 파일을 빌드에 필요한 원래 상대경로로 복원하는 도구 |

**폴더 이름이 해당 폴더 전체에 하나의 라이선스를 부여하지는 않습니다.** `Notices/LICENSE.md`, 구성요소별 고지·범위 파일과 개별 파일의 고지가 기준입니다.

README의 구현 설명에서 사용하는 경로는 원래 소스 구조를 기준으로 합니다. 압축본의 실제 보관 위치와 원래 경로의 대응은 `SOURCE-BOUNDARIES.json`에서 확인할 수 있습니다.

과거 버전이 적힌 법적 고지는 해당 허락의 기준 시점을 나타냅니다. 현재 배포물과의 대응은 해당 릴리스와 `SOURCE-BOUNDARIES.json`을 확인해 주세요.

GitHub가 자동 생성하는 **`Source code (zip/tar.gz)`는 저장소 태그의 스냅샷**이며, 별도로 첨부한 대응 소스 압축본을 대신하지 않습니다. 공개 패키지는 비공개 앱 전체 저장소의 사본도 아닙니다.

압축파일로 제공한다는 이유로 해당 라이선스가 허용하는 복사·수정·재배포 권리가 제한되지는 않습니다.

### 저작권·출처와 재배포

ForgePlay 자체 작성 부분의 저작자: **[Facta-Leopard](https://github.com/Facta-Leopard)**  
**Copyright © 2026 Facta-Leopard**

Wine과 제3자 자료의 저작권은 각각의 원저작자에게 있습니다. ForgePlay가 작성하거나 수정한 부분의 고지가 원저작자의 권리를 대체하지 않습니다.

재사용·수정·재배포 시에는 다음 사항을 지켜 주세요.

- 해당 구성요소가 요구하는 저작권·출처·라이선스 고지를 보존합니다.
- 필요한 변경 표시와 대응 소스·빌드 자료 제공 의무를 준수합니다.
- 원저작자의 기여를 자신의 독자 작성물로 오인시키거나, 수정본을 공식 ForgePlay 배포물 또는 작성자가 보증하는 배포물처럼 표시하지 않습니다.
- GPL에 따른 권리와 별개로 적용되는 모델·Apple 구성요소·아트워크·상표의 조건을 확인합니다.

GPL이 허용하는 이용에는 조건을 준수하는 상업적 이용도 포함됩니다. **소스 공개는 포플 이미지, 로고, 이름과 브랜드에 대한 새로운 재사용 허가나 상표 사용권을 부여하는 것이 아닙니다.**

이 README는 공개 범위와 구현을 설명하는 안내입니다. 라이선스 전문을 대체하거나 제3자의 권리를 새로 부여하지 않습니다.

### 실행 결과를 알려주세요

**잘 되는 게임과 실행되지 않는 게임 모두 도움이 됩니다.**

[GitHub Issues](https://github.com/Facta-Leopard/ForgePlay/issues)에 ForgePlay 버전, Mac 사양, 게임명, 그래픽 백엔드와 DLSS5·프레임 생성·AI Coordinator 설정을 함께 알려주세요. 실제 사용 경험을 바탕으로 호환성과 사용성을 개선하겠습니다.

---

## English

**A better Windows gaming experience on macOS—from launching to playing.**

ForgePlay manages Wine-based Windows gaming environments on macOS. The unified **ForgePlay** launcher and **ForgePlay Mac** execution environment provide Game Mode integration, frame generation, HyPER-GAN-based DLSS5 Emulation, AI Coordinator, AWDL controls, and game-oriented shortcut settings.

**The identified author-owned implementations of Game Mode, Frame Generation, DLSS5 Emulation, AI Coordinator, and ForgePlay VR / ForgePlayVP use GPL-3.0-only.**

The badges identify those implementations. They do not apply a blanket GPL license to the entire app, separately permitted host wrappers, model weights, artwork, or third-party components. Exact scopes and additional permissions are defined by the component notices.

[Download the latest version](https://github.com/Facta-Leopard/ForgePlay/releases/latest) · [2.2.0 source archive](https://github.com/Facta-Leopard/ForgePlay/releases/download/v2.2.0/ForgePlay-2.2.0-8-OpenSource.tar.gz) · [Website](https://facta-leopard.github.io/ForgePlay/) · [Report an issue](https://github.com/Facta-Leopard/ForgePlay/issues)

### Why ForgePlay was created

We respect CodeWeavers’ contributions to the Wine ecosystem. Those contributions do not confer exclusive ownership of Wine’s public source or an exclusive right to design a Windows-game compatibility layer. **Past contributions and present-day user expectations are separate matters.**

ForgePlay began with a concern that macOS users had too few alternatives they could meaningfully compare with CrossOver for Windows gaming. Limited choice also means fewer opportunities to question established approaches or test a different architecture. The existence of an established product should not be a reason to stop exploring alternatives.

**ForgePlay was created to demonstrate that an implementation path different from CrossOver can actually work.** A working app and source published under the applicable licenses allow others to see that possibility for themselves.

Solving the same problem does not by itself make one product a copy of another. What matters is code provenance, implementation boundaries, build structure, shipped components, and their respective licenses—not names or impressions. The published implementation is available in source archives attached to releases. Anyone can inspect and compare the code and check the descriptions against the implementation.

ForgePlay’s goals extend beyond getting a game to launch. It aims to address practical frustrations and add useful features, rather than treating “the game already launches” as the finish line. Frame generation, DLSS5 Emulation, AI Coordinator, AWDL controls, and game-oriented shortcut settings were conceived and implemented in response to those needs. We aim to demonstrate the value of these additions to Wine and macOS technologies through the implementation and user feedback.

ForgePlay is not a front end that launches or wraps an installed copy of CrossOver, and it does not depend on CrossOver product bundles, executables, or private patches. Using Wine and third-party modifications distributed under public licenses is distinct from copying a private implementation. The provenance and copyrights of reused public code are preserved; we do not claim to have newly authored those parts.

### Separately Identified GPL Implementations

The implementation paths below refer to **the original source layout of the 2.2.0 public source**. The archive separates project-authored code, Wine, third-party material, build tools, and notices. Consult `SOURCE-BOUNDARIES.json` for the mapping between archive locations and original paths; these may differ from this repository’s default branch.

The same GPL v3 text applies to the identified implementations, while author-owned contributions, Wine-derived code, third-party material, and additional permissions remain separately identified.

#### 1. ForgePlay Game Mode — GPL-3.0-only

**Published scope:** The identified implementation under `Mac/Native/GameModeProcessHost/` and its required build materials. Wine-derived portions retain their original authorship and applicable GPL-conversion notices.

**Implementation:** Eligible Windows processes are routed through a fixed native Mach-O host, which enters Wine’s `ntdll.so` and `__wine_main` within the same process. The host verifies runtime identity and the execution environment and declares Game Mode support. macOS determines whether Game Mode actually activates.

This is not a claim that the entire Wine loader was written from scratch. Evidence includes:

- `Mac/Native/GameModeProcessHost/GameModeProcessHost.m`
- `Mac/Native/GameModeProcessHost/SOURCE-CONTRACT.md`
- The Game Mode routing and target-selection patches under `Mac/Resources/Runners/ForgePlayRuntime/Patches/`
- `LICENSES/ForgePlayRelease13/WINE-GAME-MODE-NOTICE.txt`

#### 2. ForgePlay Frame Generation — GPL-3.0-only

**Published scope:** The identified author-owned implementation under `Mac/Native/D3DMetalFrameGenerationProxy/` and its build materials. Wine and MoltenVK integration changes retain their respective licensing boundaries.

**Implementation:** Intermediate frames are generated on the GPU, with capture, queues, frame lifetimes, and presentation timing managed by the runtime. Available methods are Simple, Motion Lite, Motion Quality, and Motion Repair.

Frame Check distinguishes original submissions, AI processing, generation completion, and final presentation. **FG reports the generation-completion rate; Displayed reports the confirmed final presentation rate.** Completing a frame is not treated as proof that it was displayed.

Principal implementation files:

- `Mac/Native/D3DMetalFrameGenerationProxy/ForgePlayD3DMetalFrameGenerationProxy.m`
- `Mac/Native/D3DMetalFrameGenerationProxy/FrameGenerationMotion.metal`
- `Mac/Native/D3DMetalFrameGenerationProxy/FrameGenerationStateMachine.c`
- `Mac/Native/D3DMetalFrameGenerationProxy/WineD3DOpenGLFrameGeneration.inc`

#### 3. ForgePlay DLSS5 Emulation — GPL-3.0-only

**Published scope:** The identified author-owned integration under `Mac/Native/NeuralRendering/`, plus the model-conversion, verification, and build materials specified by the notices. Its source component name is **ForgePlay Neural Rendering**.

**Implementation:** HyPER-GAN-based photorealistic post-processing is applied to completed game frames. Metal prepares inputs and composites results; a separate inference program executes the model through Core AI. It requests the Neural Engine as the preferred compute unit, without guaranteeing exclusive NPU execution of every operation.

**This is not a port of NVIDIA DLSS 5 code, models, or weights.** It uses publicly available pretrained HyPER-GAN weights in a separate implementation. Original copyrights and MIT notices remain with the upstream model, weights, and derived model material.

`NeuralWorker.swift` is an actual **GPL-published inference runtime**, not private application UI.

- `Mac/Native/NeuralRendering/NeuralFrameBridge.m`
- `Mac/Native/NeuralRendering/NeuralWorker.swift`
- `Mac/Native/NeuralRendering/NeuralFrameProcessor.m`
- `Mac/Native/NeuralRendering/NeuralRenderingStage.m`
- `Mac/Tools/NeuralRendering/`
- `LICENSES/HyPERGAN/`

The developer published before-and-after results after MVP testing on September 19, 2026. [That publication record](https://github.com/Facta-Leopard/ForgePlay/commit/d9fd184569e3bf737438630e10e731284d516e0d) establishes publication timing, not guaranteed performance across all games.

#### 4. ForgePlay AI Coordinator — GPL-3.0-only

**Published scope:** The actual visual-recognition, frame-processing, inference-control, and voice-integration runtime, together with the identified native adapters. The exact file list is in `LICENSES/ForgePlayCoordinator/SCOPE.json`. Two separately identified interoperability declaration files use MIT.

**Implementation:** OWLv2 visual recognition operates through an asynchronous path alongside existing GPU rendering. Its Core ML models are configured for the CPU and Neural Engine, and candidate regions are highlighted on screen.

Apple’s on-device Foundation Models receives a scene image and candidate-region coordinates from the same frame for explanations and dialogue. Detections are not treated as verified friend-or-foe information, and region highlights and generated explanations do not necessarily update simultaneously.

Visual recognition and explanations run locally without external AI inference APIs. This does not mean image copying and preprocessing avoid the GPU entirely.

Principal published implementation:

- `Mac/Coordinator/Core/CoordinatorModel.swift` — model loading, inference, and output processing
- `Mac/Coordinator/Core/CoordinatorWorker.swift` — worker execution and Apple model integration
- `Mac/Coordinator/Core/CoordinatorDomain.swift` — observation identity and result policy
- The designated runtime files under `Mac/Coordinator/Shared/` — prompt inputs, detection targets, and voice control
- `Mac/Coordinator/Speech/` — speech-engine integration
- `Mac/Native/VisualCoordinator/` — capture, transport, authorization, and region display

**The eight Swift files required by the inference worker and its shared runtime are included.** They perform a different role from ordinary UI and connection wrappers; a Swift filename alone does not exclude a file from publication.

#### 5. ForgePlay VR and ForgePlayVP — GPL-3.0-only

**Published scope:** The Mac VR runtime, the ForgePlayVP application for Vision Pro, shared transport/media/input implementations, and the project-authored support code and build materials required to build them. The exact scope is recorded in `Notices/LICENSES/ForgePlayVR/SCOPE.json`, with applicable terms in `NOTICE.txt`.

**Implementation:** The runtime connects video and input between Windows VR games running through Wine, the Mac, and Vision Pro. It separates Mac/Wine shared-memory transport from Mac/Vision Pro networking and handles video delivery, head tracking, hand tracking, and gamepad input. The current connection setup uses an AWDL real-time connection mode.

The scope includes Swift code that performs the actual runtime work. **ForgePlayVP and the shared VR implementation are not excluded as ordinary UI wrappers.**

The Wine-derived `VRUnixBootstrap.cpp` retains its original copyrights, **LGPL-2.1-or-later**, and its additional linking permission. Valve’s public OpenVR headers and generated declarations retain **BSD-3-Clause**. These materials are not presented as wholly original ForgePlay code or relicensed by ForgePlay’s GPL notice.

“Original implementation” describes ForgePlay-authored behavior using public interfaces. It does not claim ownership of Wine, SteamVR, OpenVR, Apple frameworks, games, or the underlying standards.

> **Vision Pro app availability:** ForgePlayVP is being prepared separately for review submission to the Vision Pro App Store. Check the [ForgePlay website](https://facta-leopard.github.io/ForgePlay/) for release announcements. Source publication and App Store availability are separate processes.

### Published Runtime and Separately Permitted Host Wrappers

Source scope follows **implementation roles and explicit permissions**, not programming language.

- Covered execution, graphics, inference, control, VR transport, and input runtimes remain within their applicable GPL scope.
- Precisely identified author-owned Mac launcher/Desktop UI, input, and connection wrappers have separate binary-distribution permissions.
- Additional permissions to combine author-owned GPL contributions with those wrappers apply only within their stated scope.
- Those permissions do not exempt the actual runtime, Wine-derived code, or another rights holder’s material from applicable obligations.
- Previously granted GPL rights remain intact.

Consult `Notices/LICENSES/ForgePlayWrapper/PERMISSION.txt` and `SCOPE.json`, the existing Game Mode and Frame Generation notices, and the VR `NOTICE.txt`.

**A Swift filename does not by itself exclude code from publication.** `NeuralWorker.swift`, the covered AI Coordinator worker and shared runtime, ForgePlayVP, and the shared VR implementation remain included.

Neither a process boundary, IPC, nor a separate folder automatically removes license obligations. Additional permissions apply only to the author-owned contributions identified in their terms.

### Wine and Third-Party Licenses

ForgePlay is a multi-license distribution. Project-authored contributions remain distinguishable from reused material, with original copyrights, provenance, and license notices preserved.

| Component | Applicable license and boundary |
| --- | --- |
| Identified ForgePlay-authored runtimes | GPL-3.0-only and expressly stated component permissions |
| Wine and Wine-derived code | LGPL-2.1-or-later and individual notices; designated Game Mode host and patch copies retain their GPL-3.0-only conversion notices |
| Wine-derived VR Unix loader | LGPL-2.1-or-later and its original additional linking permission |
| Valve OpenVR public headers and generated declarations | BSD-3-Clause |
| HyPER-GAN | MIT notices for upstream code, weights, and derived model material |
| OWLv2 | Apache-2.0 |
| Supertonic 2 model and voice-style weights | BigScience Open RAIL-M, separate from ForgePlay’s GPL code |
| Supertonic reference code and ONNX Runtime | MIT and applicable dependency notices |
| MoltenVK, DXMT, DXVK, GStreamer, fonts, and other dependencies | Their individual licenses and notices |
| Witcher 3 compatibility adapter | MIT with upstream and modification notices; the original game DLL is not included |
| Apple D3DMetal, system frameworks, and models | Separate Apple terms; not relicensed under ForgePlay’s GPL declarations |

The designated Game Mode copies retain their existing conversion notices under [LGPL 2.1 section 3](https://github.com/wine-mirror/wine/blob/master/COPYING.LIB). **Obligations for the corresponding modified Wine distribution are not limited to publishing patch files.** Applicable source and build-material obligations, upstream LGPL rights, and third-party copyrights remain preserved.

### Source Is Supplied as Release Assets

**To meet the distribution obligations of Wine and other components, source corresponding to the distributed binaries, modification patches, required build materials, and copyright and license notices are provided as separate archives attached to GitHub releases.**

The current package is [ForgePlay-2.2.0-8-OpenSource.tar.gz](https://github.com/Facta-Leopard/ForgePlay/releases/download/v2.2.0/ForgePlay-2.2.0-8-OpenSource.tar.gz), attached to [ForgePlay 2.2.0 (Build 8)](https://github.com/Facta-Leopard/ForgePlay/releases/tag/v2.2.0).

The 2.2.0 source package is organized as follows.

| File or directory | Purpose |
| --- | --- |
| `ForgePlay/` | Covered original implementations, VR/ForgePlayVP, and shared support code |
| `Wine/` | Wine source, version-matched patches, and Wine-derived code |
| `ThirdParty/` | Third-party originals, identified modifications, and corresponding source |
| `Build/` | Required build and packaging tools and configuration |
| `Notices/` | Full licenses, original copyrights, provenance, and exact scopes |
| `SOURCE-BOUNDARIES.json` | Original paths and corresponding published-source/build-input hashes |
| `restore-layout.py` | Restores the original relative layout required for building |

**Directory names do not assign a single license to every contained file.** Consult `Notices/LICENSE.md`, component notices and scope records, and individual file notices.

Implementation paths in this README refer to the original source layout. `SOURCE-BOUNDARIES.json` maps those paths to their locations in the archive.

Older version numbers in preserved legal notices identify the origin of those permissions. Consult the relevant release and `SOURCE-BOUNDARIES.json` for the current source-to-binary correspondence.

GitHub’s automatic **`Source code (zip/tar.gz)` downloads are repository-tag snapshots**. They do not replace the separately attached corresponding-source archive. The archive is not a copy of the entire private application repository.

Providing source in archives does not restrict copying, modification, or redistribution rights granted by the applicable licenses.

### Copyright, Attribution, and Redistribution

Author of ForgePlay-authored material: **[Facta-Leopard](https://github.com/Facta-Leopard)**  
**Copyright © 2026 Facta-Leopard**

Wine and third-party materials retain their respective original copyrights. Notices for ForgePlay’s contributions do not replace those rights.

When reusing, modifying, or redistributing material:

- Preserve required copyright, attribution, and license notices.
- Identify modifications and provide corresponding source and build materials where required.
- Do not misrepresent another author’s work as solely your own, or present a modified distribution as an official ForgePlay release or as endorsed by its author.
- Observe separate terms for models, Apple components, artwork, and trademarks.

GPL-permitted use includes compliant commercial use. **Source publication grants no new rights to reuse Fopl artwork, logos, names, or branding, and grants no trademark permission.**

This README explains implementation and publication boundaries. It does not replace the license texts or grant additional third-party rights.

### Share your game results

**Reports of both working and non-working games are useful.**

Please include your ForgePlay version, Mac specifications, game title, graphics backend, and DLSS5, frame-generation, and AI Coordinator settings when reporting through [GitHub Issues](https://github.com/Facta-Leopard/ForgePlay/issues). Real-world feedback helps us improve compatibility and usability.
