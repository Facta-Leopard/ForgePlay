## ForgePlay를 만든 이유

ForgePlay는 CrossOver를 흉내 내기 위해 만든 앱이 아니다. macOS에서 Windows 게임을 실행하는 선택지가 오랫동안 CrossOver 중심으로 굳어졌고, 동급 경쟁자가 거의 없는 동안 CodeWeavers가 기존 구조와 제품 우선순위에 안주했다. 나는 그 안주가 불만이어서 ForgePlay를 시작했다.

다른 방식이 실제로 가능하다는 점을 말로만 주장하고 싶지는 않았다. 그래서 직접 구현했고, 누구나 확인할 수 있도록 코드를 공개한다.

### CrossOver의 공로와 현재의 안주는 별개의 문제다

CodeWeavers가 Wine에 오랫동안 기여해 온 것은 사실이다. CrossOver를 위해 개발한 Wine 코드의 상당 부분을 upstream에 환원해 왔고, Wine 생태계를 유지하는 데도 큰 역할을 했다. 그 공로는 인정한다.

하지만 과거의 공로가 현재 제품에 대한 비판까지 막아 주지는 않는다.

macOS에서 일반 사용자를 대상으로 지속적인 개발과 기술 지원, GUI, 설치 자동화, 게임별 설정, D3DMetal 같은 독점 구성요소의 통합까지 한꺼번에 제공하는 상용 제품에서 CrossOver는 사실상 유일한 기준점이었다. 무료 프런트엔드와 커뮤니티 프로젝트는 있었지만, 같은 조건에서 장기간 경쟁하는 동급 제품은 거의 없었다.

경쟁자가 없으면 기존 제품은 자기 구조를 끊임없이 의심할 이유도 줄어든다. 사용자가 다른 제품으로 옮겨 갈 가능성이 낮으니, 새로운 실행 구조나 운영체제 고유 기능을 먼저 도입해야 할 압력도 약해진다. 그 결과 한 회사가 선택한 방식이 어느 순간 생태계 전체의 한계처럼 받아들여진다.

나는 CrossOver가 바로 그 환경에 안주했다고 본다. 구현 난이도와 QA 비용, 인력 문제는 존재한다. 하지만 그것만으로 이 공백을 설명할 수는 없다. 동급 경쟁자가 있었다면 지금의 구조가 정말 최선인지 더 자주 검증했을 것이고, macOS에 더 깊이 맞춘 기능도 훨씬 일찍 제품의 경쟁 요소가 됐을 것이다.

ForgePlay는 그동안 부족했던 경쟁을 실제 코드로 만들기 위해 시작했다.

### Game Mode는 왜 지금까지 정식 기능이 아니었나

macOS에서 게임을 실행하는 제품을 판매한다면, macOS가 제공하는 Game Mode를 게임 실행 구조와 연결하는 것은 충분히 떠올릴 법한 과제다. 비밀 API나 특수 권한이 필요한 발상도 아니다. 게임을 별도의 macOS 앱 문맥에서 실행하고, 그 앱이 실제 게임 세션의 수명주기를 맡도록 만들면 된다.

그런데 CodeWeavers의 현재 공개 문서에는 CrossOver가 Game Mode를 게임별 정식 기능으로 지원한다는 설명이 없다. D3DMetal, DXMT, DXVK, DLSS, MSync 같은 그래픽·동기화 기능은 상세히 안내하면서도, macOS 자체의 게임 실행 체계와 연결하는 기능은 제품의 핵심 요소로 다뤄지지 않았다.

ForgePlay는 게임마다 전용 **Game Host**를 만든다. 이 Game Host가 Wine 기반 게임 세션의 시작부터 종료까지 직접 관리한다. 실제 게임을 실행하면 macOS의 Game Overlay와 메뉴 막대에서 해당 Game Host의 Game Mode가 정상적으로 활성화된다. ForgePlay 본체에 게임 카테고리만 붙인 것이 아니라, 실제 게임 세션을 소유하고 관리하는 호스트가 macOS에서 게임으로 인식되는 구조다.

Game Mode의 성능 효과는 게임별로 측정하면 된다. 여기서 이미 증명한 것은 **Wine 기반 Windows 게임도 macOS의 Game Mode 실행 문맥에 정상적으로 연결할 수 있다는 사실**이다.

솔직히 묻고 싶다.

> 개인 개발자인 나도 이런 구조를 떠올리고 구현했는데, 수십 년 동안 Wine 기반 상용 제품을 만든 CodeWeavers는 왜 지금까지 하지 않았는가?

생각하지 못했든, 생각하고도 중요하지 않다고 판단했든, 사용자 입장에서 결과는 같다. 오랫동안 CrossOver에는 이 선택지가 없었다.

나는 그 공백이 이렇게 오래 유지될 수 있었던 가장 큰 이유 중 하나가 경쟁 부족이라고 본다. 동급 경쟁자가 있었다면, Game Mode처럼 macOS 게임 제품이라면 검토할 법한 기능을 이토록 오래 제품 밖에 두기는 어려웠을 것이다. 경쟁자가 없으니 기존 방식으로도 시장의 기준점 자리를 유지할 수 있었고, 결국 “굳이 지금 바꿀 필요가 없다”는 안주가 가능했다.

ForgePlay의 Game Host는 그 안주에 대한 말이 아니라 구현된 반론이다.

### macOS를 단순한 Wine 실행기가 아니라 게임 플랫폼으로 다룬다

CrossOver는 Wine과 그래픽 번역 계층을 잘 묶어 제공하는 제품이다. 그러나 macOS용 게임 제품이라면 Wine 바이너리를 실행하는 것만으로 끝나서는 안 된다.

게임마다 다음 요소가 하나의 실행 체계 안에서 관리돼야 한다.

- 게임별 앱 수명주기
- Game Mode
- 전체 화면 전환
- 프리픽스와 실행 설정
- 그래픽 백엔드
- 환경 변수
- 로그와 오류 진단
- 게임 종료 후 정리

ForgePlay는 이 요소들을 게임별 Game Host를 중심으로 묶는다. macOS를 Wine을 돌리는 바탕 화면으로만 취급하지 않고, Windows 게임도 macOS의 게임 실행 체계 안에서 관리하는 것을 기본 설계로 삼았다.

### 호환성을 블랙박스로 남기지 않는다

Wine 기반 게임 실행에서 중요한 것은 실행 파일이 한 번 열리는지가 아니다. 실제 호환성은 영상, 입력, 오디오, 네트워크, 프레임 유지, 종료 처리, 업데이트 이후의 재현성까지 포함한다.

CrossOver가 게임별 데이터와 자동 설정을 비공개 체계로 운영하는 것은 상용 제품으로서 가능한 선택이다. 그러나 사용자는 어떤 설정이 적용됐는지, 왜 특정 게임이 성공하거나 실패했는지, 버전이 바뀐 뒤 무엇이 달라졌는지 충분히 확인하기 어렵다.

ForgePlay는 게임마다 실행 환경과 설정을 분리하고, 실제로 적용된 구성과 실행 로그를 확인할 수 있도록 만든다. 모든 게임이 된다고 과장하기보다, 성공과 실패를 재현하고 원인을 추적할 수 있는 구조를 우선한다.

호환성은 회사가 내려 주는 판정표가 아니라, 사용자가 직접 확인할 수 있는 기술적 결과여야 한다.

### GPTK 번들링이 아니라 상업적 권한의 불투명성을 묻는다

ForgePlay도 Wine과 GPTK를 함께 번들링한다. 따라서 GPTK나 D3DMetal을 하나의 배포물에 포함하는 행위 자체를 비판하는 것이 아니다.

내가 Apple Developer Downloads에서 받은 공식 Game Porting Toolkit 배포물의 `License.rtf`를 검토했을 때, 해당 개발자용 라이선스는 재배포를 비상업적 목적으로 제한하고 있었다. ForgePlay는 현재 유료 판매 제품이 아니라 오픈소스 프로젝트이며, GPTK와 D3DMetal을 ForgePlay 소유의 오픈소스 구성요소처럼 표시하지 않는다. 포함하는 버전에 동봉된 라이선스를 기준으로 별도의 제3자 구성요소로 관리한다.

반면 CodeWeavers는 CrossOver 26에 D3DMetal 3.0이 포함된다고 공식적으로 밝혔고, CrossOver를 유료로 판매한다.

그렇다면 CodeWeavers가 답할 질문은 하나다.

> **D3DMetal을 유료 CrossOver에 포함해 최종 사용자에게 배포할 수 있는 별도의 상업 계약이나 재배포 권한이 존재하는가?**

계약서 전문이나 금액을 공개하라는 것이 아니다. 권한이 있다면 있다고 밝히고, 어느 제품이나 버전에 적용되는지만 설명하면 된다. 그 정도의 확인조차 없이 유료 제품에 포함된 제3자 구성요소의 상업적 권리 관계를 계속 불분명하게 두는 것은 불필요한 불투명성이다.

이 기준은 ForgePlay에도 그대로 적용한다. ForgePlay의 배포 방식이나 수익 구조가 바뀌면, 그 시점에 포함된 GPTK와 D3DMetal의 라이선스를 다시 검토한다. 공개된 라이선스가 주지 않은 권리를 당연한 것으로 여기지 않는다.

### 그래서 오픈소스로 공개한다

ForgePlay를 오픈소스로 공개하는 이유는 비판을 구호로 끝내고 싶지 않기 때문이다.

- Game Host가 실제로 어떻게 동작하는지 확인할 수 있어야 한다.
- Game Mode가 어떤 실행 문맥에서 활성화되는지 검토할 수 있어야 한다.
- 게임별 설정과 프리픽스가 어떻게 분리되는지 확인할 수 있어야 한다.
- 성능과 호환성 주장은 코드와 로그로 검증할 수 있어야 한다.
- 실패와 한계도 숨기지 않아야 한다.

공식 ForgePlay 프로젝트는 유지보수자가 방향을 정하며, 현재 코드 기여는 받지 않는다. 그러나 적용 라이선스가 허용하는 범위에서 누구나 코드를 검토하고, 포크하거나, 별도의 구현으로 발전시킬 수 있다.

CrossOver는 비공개 제품을 선택했다. ForgePlay는 공개를 선택한다. 구조와 결과를 드러내고, 사용자가 직접 비교하게 한다.

### 경쟁자가 없었다면, 이제는 만들면 된다

CodeWeavers의 Wine 기여는 존중받아야 한다. 그러나 그 기여가 CrossOver의 현재 구조를 생태계의 최종 답으로 만들지는 않는다.

CrossOver가 Game Host 같은 구조를 생각하지 못했든, 생각하고도 우선하지 않았든, 결과는 같았다. 사용자는 선택지가 없었다. 그리고 경쟁자가 거의 없었기 때문에 그 공백은 오래 유지될 수 있었다.

ForgePlay는 바로 그 상황이 불만이어서 만든 앱이다.

> **경쟁자가 없어서 생각하지 못했다면, 다른 사람이 생각하면 된다.**  
> **경쟁자가 없어서 만들지 않았다면, 새로운 경쟁자가 만들면 된다.**

ForgePlay는 CrossOver를 비난하기 위한 구호가 아니다. CrossOver가 하지 않은 선택을 실제로 구현하고, 그 결과를 공개적으로 검증하기 위한 프로젝트다.

ForgePlay는 경쟁이 없던 자리에 경쟁을 만들기 위해 존재한다.

---

### 참고 자료

- [CrossOver 26 발표 — Wine 11.0 및 D3DMetal 3.0 포함](https://www.codeweavers.com/blog/mjohnson/2026/2/10/crossover-26-cures-artificial-incompatibility-with-windows-games-on-mac)
- [CrossOver Mac User Guide](https://support.codeweavers.com/en_US/crossover-mac-user-guide)
- [Advanced Settings in CrossOver Mac 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26)
- [CodeWeavers Open Source 페이지 — CrossOver의 독점 구성요소 설명](https://www.codeweavers.com/open-source)
- [CodeWeavers CrossOver 페이지 — Wine 개발 코드의 upstream 환원 설명](https://www.codeweavers.com/crossover/)
- [Apple Game Porting Toolkit 공식 페이지](https://developer.apple.com/games/game-porting-toolkit)
- [Apple Developer Downloads의 Game Porting Toolkit 배포물](https://developer.apple.com/download/all/?q=game%20porting%20toolkit) — Apple Developer 로그인이 필요하다. 본문의 라이선스 설명은 작성자가 공식 배포물에 동봉된 `License.rtf`를 직접 검토한 결과를 기준으로 한다.
- [Apple 게임 모드 공식 안내](https://support.apple.com/ko-kr/105118)
- [Apple Developer — `LSSupportsGameMode`](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsgamemode)
