# ForgePlay

[![Copyright](.github/assets/readme-copyright.svg)](https://github.com/Facta-Leopard)
[![Native Game Mode and Frame Generation license](.github/assets/readme-native-gpl.svg)](https://github.com/Facta-Leopard/ForgePlay/releases/tag/v1.3.0)
[![Source distribution](.github/assets/readme-source-archives.svg)](https://github.com/Facta-Leopard/ForgePlay/releases)

[한국어](#한국어) · [English](#english)

[최신 버전 다운로드 / Download](https://github.com/Facta-Leopard/ForgePlay/releases/latest) · [홈페이지 / Website](https://facta-leopard.github.io/ForgePlay/) · [문제 제보 / Issues](https://github.com/Facta-Leopard/ForgePlay/issues)

## 한국어

**macOS에서 Windows 게임을 실행하고 즐기는 경험을 개선합니다.**

ForgePlay는 Wine을 기반으로 Windows 게임 실행 환경을 관리하는 macOS 앱입니다. 게임 실행뿐 아니라 프레임 생성, 네트워크 관련 제어, 단축키와 입력 설정까지 사용자가 직접 조정할 수 있도록 설계했습니다.

### ForgePlay를 만든 이유

Wine 생태계에 대한 CodeWeavers의 기여와 공로를 존중합니다. 다만 그 기여가 Wine의 공개 소스나 Windows 게임 호환 계층을 설계할 권리를 독점한다는 뜻은 아닙니다. **과거의 기여와 현재의 사용자 경험에 대한 요구는 별개입니다.**

ForgePlay는 macOS에서 Windows 게임을 즐길 때, CrossOver와 실질적으로 비교하고 선택할 수 있는 대안이 부족하다는 문제의식에서 출발했습니다. 선택지가 적으면 기존 방식을 돌아보거나 다른 구조의 가능성을 검증할 기회도 줄어듭니다. 이미 자리 잡은 제품이 있다는 이유로 새로운 시도가 멈춰서는 안 된다고 생각했습니다.

그래서 **“CrossOver와 다른 구현 경로도 실제로 동작할 수 있다”는 것을 직접 보여주기 위해 ForgePlay를 만들었습니다.** 실제로 사용할 수 있는 앱과 라이선스에 따라 공개하는 소스를 통해, 그 가능성을 누구나 확인할 수 있도록 하고자 합니다.

같은 문제를 해결한다는 사실만으로 한 제품이 다른 제품의 복제품이 되지는 않습니다. 판단의 기준은 이름이나 인상이 아니라 코드의 출처, 구현의 경계, 빌드 구조, 배포하는 구성요소와 각각의 라이선스입니다. 공개 대상 구현은 릴리스에 첨부한 소스 압축파일로 제공합니다. 누구나 해당 코드를 읽고 비교하며, 설명과 실제 구현이 일치하는지 확인할 수 있습니다.

ForgePlay가 지향하는 차이는 게임을 실행시키는 데서 끝나지 않습니다. “이미 실행되니 충분하다”는 기준에 머물지 않고, 사용 중 겪는 불편과 추가로 필요한 기능을 제품에 반영하는 것이 목표입니다.

프레임 생성, AWDL 제어, 게임용 단축키 설정은 실제 사용 과정에서 직접 구상하고 구현한 기능입니다. Wine과 macOS의 기반 기술 위에 ForgePlay만의 설계와 제어 기능을 더했습니다. 독자적으로 더한 기능의 가치는 실제 구현과 사용자 피드백으로 보여드리고자 합니다.

### ForgePlay가 아닌 것

- 설치된 CrossOver를 실행하거나 감싸는 프런트엔드가 아닙니다.
- CrossOver의 bottle 디렉터리, 제품 번들, 실행 파일 또는 비공개 패치에 의존하는 구조가 아닙니다.
- CodeWeavers의 비공개 구현을 ForgePlay가 작성한 코드라고 주장하지 않습니다.
- Wine, D3DMetal 또는 제3자 구성요소의 권리까지 ForgePlay가 소유한다고 주장하지 않습니다.

ForgePlay는 Wine을 기반으로 합니다. Wine의 공개 코드를 해당 라이선스에 따라 사용·수정하는 것과 CrossOver의 비공개 구현을 복제하는 것은 서로 다른 일입니다. Game Mode 호스트에도 Wine에서 유래한 부분이 있으며, 이를 전부 새로 작성한 Wine 로더라고 주장하지 않습니다. 해당 부분의 출처와 저작권, 라이선스 경계는 공개 소스에 포함된 고지에 명시합니다.

### ForgePlay가 추가로 구현한 기능

| 기능 | ForgePlay의 설계와 구현 |
| --- | --- |
| Game Mode 연동 | Wine 게임 프로세스가 macOS Game Mode의 대상이 될 수 있도록 네이티브 호스트와 실행 경로를 구성합니다. 실제 활성화는 macOS가 판단합니다. |
| Frame Generation · Frame Check | Metal 기반의 자체 프레임 생성 파이프라인과 원본·생성·표시 FPS 확인 기능을 제공합니다. 현재 프레임 생성은 베타 기능입니다. |
| AWDL 제어 | AWDL 상태 확인과 켜기·끄기 제어를 앱에 통합해 사용자가 게임 환경에 맞게 선택할 수 있도록 합니다. |
| 단축키 설정 · 입력 보호 | 보조키 매핑과 macOS 단축키 차단 설정을 통해 게임 조작과 시스템 동작 사이의 충돌을 줄일 수 있도록 합니다. |

이 기능들은 ForgePlay의 추가 구현을 설명합니다. Wine, Apple의 기반 기술, 제3자 렌더러 자체에 대한 소유권을 주장하는 것은 아닙니다.

### Wine 라이선스에 따른 소스 공개

**ForgePlay는 Wine의 오픈소스 라이선스에 따른 배포 의무를 준수하기 위해, 배포물에 대응하는 Wine 소스와 수정 패치, 필요한 빌드 자료 및 라이선스·저작권 고지를 공개합니다.** 이 자료는 참고용 코드가 아니라, 실제 배포한 Wine 구성요소에 대응하는 소스입니다.

Wine 원본의 기본 라이선스는 [GNU LGPL 2.1 이상(`LGPL-2.1-or-later`)](https://github.com/wine-mirror/wine/blob/master/LICENSE)입니다. ForgePlay의 네이티브 Game Mode·프레임 생성에는 별도의 `GPL-3.0-only` 범위를 명시하며, Game Mode의 Wine 유래 코드와 지정 변경본에 적용되는 GPL 조건도 함께 고지합니다. 구성요소별 적용 범위는 해당 소스 압축본의 라이선스 원문과 고지를 따릅니다.

#### 공개 소스는 어디에서 받나요?

**공개 대상 소스는 [GitHub Releases](https://github.com/Facta-Leopard/ForgePlay/releases)에 별도 압축파일로 제공합니다.** 특정 버전의 소스를 확인·수정하거나 재구축하려면, 해당 릴리스에 직접 첨부한 소스 아카이브와 라이선스 고지를 참고해 주세요.

- 공개 대상인 네이티브 코드, Wine 원본 소스와 패치, 해당 제3자 소스를 제공합니다.
- 바이너리 배포에 필요한 필수 빌드 소스와 재링크 자료를 함께 제공합니다.
- Swift 앱 래퍼, 개인 키·계정 정보, 내부 개발·검토 문서는 공개 대상에 포함하지 않습니다.
- 공개 대상 소스가 바뀌지 않은 유지보수 릴리스는 기존 공개 아카이브를 그대로 사용합니다. 같은 파일을 매번 중복 첨부하지 않습니다.

현재 공개 소스 기준은 [1.3 소스 배포](https://github.com/Facta-Leopard/ForgePlay/releases/tag/v1.3.0)입니다. 1.3.1은 해당 네이티브·Wine 코드를 변경하지 않아 같은 소스를 사용합니다.

[네이티브·Wine 코드](https://github.com/Facta-Leopard/ForgePlay/releases/download/v1.3.0/ForgePlay-1.3-Native-Wine-Code.tar.gz) · [제3자 소스](https://github.com/Facta-Leopard/ForgePlay/releases/download/v1.3.0/ForgePlay-1.3-ThirdParty-Code.tar.gz) · [필수 빌드 소스](https://github.com/Facta-Leopard/ForgePlay/releases/download/v1.3.0/ForgePlay-1.3-Build-Sources.tar.gz)

이 저장소의 기본 브랜치는 버전별 배포 소스의 기준이 아닙니다. GitHub가 자동 표시하는 `Source code (zip/tar.gz)`도 태그 스냅샷이므로, 배포 소스를 확인할 때에는 위의 직접 첨부된 아카이브를 사용해 주세요.

공개 소스의 복사·수정·재배포 권리는 각 구성요소의 라이선스에 따릅니다. 압축파일로 제공하는 방식이 이러한 권리를 제한하지는 않습니다.

### 저작권과 라이선스

ForgePlay가 작성한 코드의 저작자: **[Facta-Leopard](https://github.com/Facta-Leopard)**<br>
**Copyright © 2026 Facta-Leopard**

- **네이티브 Game Mode·프레임 생성 구현:** `GPL-3.0-only`. 정확한 범위와 추가 고지는 소스 압축본의 `LICENSE.txt`와 관련 고지에 명시합니다.
- **Swift 앱 래퍼:** 저작자 소유 코드에 대한 별도 배포 허용을 적용합니다. 상단 GPL 배지는 앱 전체를 일괄 GPL로 지정하는 표시가 아닙니다.
- **Wine 및 Wine 유래 코드:** 해당 LGPL/GPL 조건에 따라 소스와 필수 빌드 자료를 제공하고, Wine 저작자의 저작권과 출처 고지를 보존합니다. Swift 래퍼의 별도 배포 허용은 이 의무를 면제하지 않습니다.
- **MoltenVK·DXVK·폰트·Apple 구성요소 등:** 각각의 라이선스와 원래 저작권 고지를 보존합니다. ForgePlay의 표시는 제3자 권리를 대체하지 않습니다.

실제 적용 조건은 해당 배포본의 라이선스 원문과 구성요소별 고지를 기준으로 합니다.

### 실행 결과를 알려주세요

**잘 되는 게임과 실행되지 않는 게임 모두 도움이 됩니다.**

[GitHub Issues](https://github.com/Facta-Leopard/ForgePlay/issues)에 ForgePlay 버전, Mac 사양, 게임명, 그래픽 백엔드와 FG 사용 여부를 함께 알려주세요. 실제 사용 환경에서 보내주시는 피드백을 바탕으로 호환성과 사용성을 개선하겠습니다.

---

## English

**A better Windows gaming experience on macOS—from launching to playing.**

ForgePlay is a macOS app that manages Windows gaming environments built on Wine. It gives users control over game launching, frame generation, network-related settings, keyboard shortcuts, and input behavior.

### Why ForgePlay was created

We respect CodeWeavers' contributions to the Wine ecosystem. Those contributions do not confer exclusive ownership of Wine's public source or an exclusive right to design a Windows-game compatibility layer. **Past contributions and present-day user expectations are separate matters.**

ForgePlay began with a concern that macOS users had too few alternatives they could meaningfully compare with CrossOver for Windows gaming. Limited choice also means fewer opportunities to question established approaches or test a different architecture. The existence of an established product should not be a reason to stop exploring alternatives.

**ForgePlay was created to demonstrate that an implementation path different from CrossOver can actually work.** A working app and source published under the applicable licenses allow others to see that possibility for themselves.

Solving the same problem does not by itself make one product a copy of another. What matters is code provenance, implementation boundaries, build structure, shipped components, and their respective licenses—not names or impressions. The published implementation is available in source archives attached to releases. Anyone can inspect and compare that code and check the descriptions against the implementation.

ForgePlay's goals extend beyond getting a game to launch. It aims to address practical frustrations and add useful features, rather than treating “the game already launches” as the finish line.

Frame generation, AWDL controls, and game-oriented shortcut settings were conceived and implemented in response to needs encountered during actual use. ForgePlay adds its own design and controls on top of Wine and macOS technologies. We aim to demonstrate the value of these additions through the implementation and user feedback.

### What ForgePlay is not

- It is not a front end that launches or wraps an installed copy of CrossOver.
- It does not depend on CrossOver bottle directories, product bundles, executables, or private patches.
- It does not present CodeWeavers' private implementation as ForgePlay-authored code.
- It does not claim ownership of Wine, D3DMetal, or other third-party components.

ForgePlay is based on Wine. Using and modifying Wine's public source under its license is different from copying a private CrossOver implementation. The Game Mode host also contains Wine-derived material; we do not present it as a Wine loader written entirely from scratch. Notices in the published source identify that material's provenance, copyrights, and license boundaries.

### Features implemented in ForgePlay

| Feature | ForgePlay's design and implementation |
| --- | --- |
| Game Mode integration | A native host and launch path allow Wine game processes to be considered for macOS Game Mode. macOS determines whether it activates. |
| Frame Generation · Frame Check | ForgePlay's own Metal-based frame-generation pipeline, with original, generated, and displayed FPS reporting. Frame generation is currently a beta feature. |
| AWDL controls | Built-in status checks and on/off controls let users choose a setting that suits their gaming environment. |
| Shortcut settings · Input protection | Modifier-key mapping and configurable macOS shortcut blocking help reduce conflicts between game controls and system actions. |

These describe ForgePlay's added implementation. They do not claim ownership of Wine, Apple's underlying technologies, or third-party renderers.

### Source publication under Wine's license

**To comply with the distribution obligations of Wine's open-source license, ForgePlay publishes the corresponding Wine source, modification patches, required build materials, and license and copyright notices.** These are the sources for the Wine components actually distributed with ForgePlay, not merely reference code.

Upstream Wine's baseline license is [GNU LGPL version 2.1 or later (`LGPL-2.1-or-later`)](https://github.com/wine-mirror/wine/blob/master/LICENSE). ForgePlay separately identifies the `GPL-3.0-only` scope of its native Game Mode and Frame Generation implementation, and preserves the GPL terms applicable to the identified Wine-derived Game Mode code and modifications. The license texts and notices in each source archive define the applicable component boundaries.

#### Where can I get the source?

**Published source materials are available as separate archives in [GitHub Releases](https://github.com/Facta-Leopard/ForgePlay/releases).** To inspect, modify, or rebuild a particular version, use the source archives attached directly to its release and the accompanying license notices.

- The published materials include covered native code, original Wine sources and patches, and the corresponding third-party sources.
- The archives also include the essential build sources and relinking materials required for the binary distribution.
- The Swift app wrapper, personal keys and account information, and internal development/review documents are excluded.
- When a maintenance release does not change the covered sources, the existing archives remain applicable. Identical source files are not reattached to every release.

The current published source baseline is the [1.3 source release](https://github.com/Facta-Leopard/ForgePlay/releases/tag/v1.3.0). Version 1.3.1 reuses those native/Wine sources without changing them.

[Native/Wine code](https://github.com/Facta-Leopard/ForgePlay/releases/download/v1.3.0/ForgePlay-1.3-Native-Wine-Code.tar.gz) · [Third-party sources](https://github.com/Facta-Leopard/ForgePlay/releases/download/v1.3.0/ForgePlay-1.3-ThirdParty-Code.tar.gz) · [Essential build sources](https://github.com/Facta-Leopard/ForgePlay/releases/download/v1.3.0/ForgePlay-1.3-Build-Sources.tar.gz)

This repository's default branch is not the authoritative source snapshot for a binary release. GitHub's automatically displayed `Source code (zip/tar.gz)` links are tag snapshots; use the directly attached archives above for the release sources.

Rights to copy, modify, and redistribute published source follow each component's license. Providing that source in archives does not restrict those rights.

### Copyright and licensing

Author of ForgePlay's own code: **[Facta-Leopard](https://github.com/Facta-Leopard)**<br>
**Copyright © 2026 Facta-Leopard**

- **Native Game Mode and Frame Generation:** `GPL-3.0-only`. The exact scope and additional terms are specified in `LICENSE.txt` and the accompanying source-archive notices.
- **Swift app wrapper:** Separate distribution permission applies to the author's own code. The GPL badge is not a blanket GPL designation for the entire app.
- **Wine and Wine-derived code:** Source and required build materials are provided under the applicable LGPL/GPL terms, with Wine authorship and provenance notices preserved. The separate Swift wrapper permission does not waive these obligations.
- **MoltenVK, DXVK, fonts, Apple components, and other third-party material:** Their respective licenses and original copyright notices remain in force. ForgePlay's notices do not replace third-party rights.

The actual terms are the license texts and component notices accompanying the relevant distribution.

### Share your game results

**Reports of both working and non-working games are useful.**

Please include your ForgePlay version, Mac specifications, game title, graphics backend, and whether FG was enabled when reporting through [GitHub Issues](https://github.com/Facta-Leopard/ForgePlay/issues). Feedback from real-world use helps us improve compatibility and usability.
