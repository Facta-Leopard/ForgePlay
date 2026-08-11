# ForgePlay update-check contract

## 목적

`site-data/current-release.json`은 ForgePlay 안정 릴리스의 기계 판독용
단일 기준이다. 홈페이지와 호환성 페이지가 이 파일을 표시용으로 읽고,
향후 앱의 **업데이트 확인** 기능도 같은 공개 URL을 사용한다.

공개 URL:

`https://facta-leopard.github.io/ForgePlay/site-data/current-release.json`

호환성 DB에는 과거 버전, 여러 테스트 버전, 미기재 버전 및
`development` 기록이 함께 존재한다. 따라서
`site-data/compatibility-games.json`에서 최신 앱 버전을 추론하면 안 된다.
HTML 문구나 화면에 표시된 버전 문자열을 파싱해서도 안 된다.

호환성 카탈로그 갱신은 별도 계약이다. 앱 바이너리 업데이트 확인은
`current-release.json`, 게임 호환성 목록 갱신은 `compatibility-games.json`을
사용하며 두 상태를 서로 추론하지 않는다. 호환성 카탈로그의 캐시와 리비전
규칙은 `docs/compatibility-catalog-consumer-contract.md`에 정리되어 있다.

## 데이터 소유권

- 소유자: 안정 릴리스 게시 절차
- 생산자: 릴리스를 게시하고 검증하는 작업
- 소비자: ForgePlay 웹사이트와 앱의 수동 업데이트 확인 기능
- 스키마: `site-data/current-release.schema.json`
- 현재 채널: `stable`

`schemaVersion`이 변경되면 기존 앱이 알 수 없는 형식을 최신 버전으로
오판하지 않도록 지원하지 않는 스키마 오류로 처리한다.

## 필드 계약

| 필드 | 의미 | 앱에서의 사용 |
| --- | --- | --- |
| `schemaVersion` | 매니페스트 형식 버전 | 지원 형식인지 먼저 확인 |
| `product` | 제품 식별자 | 반드시 `ForgePlay`인지 확인 |
| `channel` | 업데이트 채널 | 현재는 `stable`만 허용 |
| `marketingVersion` | `CFBundleShortVersionString`과 같은 표시 버전 | 사용자에게 표시 |
| `buildNumber` | `CFBundleVersion`과 같은 단조 증가 정수 | 업데이트 여부의 기준 |
| `releaseTag` | GitHub 릴리스 태그 | 표시 및 URL 일관성 확인 |
| `publishedAt` | ISO 8601 UTC 게시 시각 | 릴리스 정보 표시 및 진단 |
| `minimumMacOSVersion` | 릴리스의 최소 macOS 버전 | 설치 가능 여부 안내 |
| `releaseURL` | 검증 정보와 릴리스 노트가 있는 HTTPS URL | 업데이트 발견 시 열기 |
| `download` | DMG 이름, HTTPS URL, SHA-256, 바이트 크기 | 향후 다운로드·무결성 확인 |

## 앱의 업데이트 판정

앱은 번들에서 다음 값을 읽는다.

- `CFBundleShortVersionString`: 표시용 현재 버전
- `CFBundleVersion`: 현재 빌드 번호

원격 매니페스트를 검증한 뒤 `buildNumber`를 정수로 비교한다.

| 조건 | 결과 |
| --- | --- |
| 원격 빌드가 로컬 빌드보다 큼 | 업데이트 있음 |
| 원격 빌드와 로컬 빌드가 같음 | 최신 버전 |
| 원격 빌드가 로컬 빌드보다 작음 | 최신 버전으로 표시하되 진단에 매니페스트 지연 기록 |
| 네트워크·HTTP·JSON·스키마·필드 검증 실패 | 업데이트 확인 실패 |

실패를 **최신 버전**으로 바꾸어 표시하면 안 된다. 버전 문자열을 사전식으로
비교하지 않으며, 업데이트 판정은 단조 증가하는 `buildNumber`가 담당한다.

## 요청 및 캐시 정책

- HTTPS 공개 URL만 사용한다.
- 요청 헤더에 `Accept: application/json`을 보낸다.
- 사용자가 버튼을 누른 확인 요청은 로컬 캐시를 무시한다.
- 합리적인 타임아웃을 두고 취소를 지원한다.
- HTTP 성공 상태와 JSON MIME 유형을 확인한다.
- 응답 크기에 상한을 둔다. 현재 매니페스트는 작은 정적 JSON이다.
- 동시 요청은 하나로 합치고 버튼의 진행 상태를 사용자에게 보여준다.

웹사이트는 캐시 우회를 위한 쿼리 값과 `cache: "no-store"`를 함께 사용한다.
앱에서는 `URLRequest.CachePolicy.reloadIgnoringLocalCacheData`에 해당하는
정책을 사용한다.

## 입력 검증 및 보안

앱은 최소한 다음을 검증한다.

1. `schemaVersion`, `product`, `channel`
2. 버전 형식과 양의 정수 `buildNumber`
3. ISO 8601 `publishedAt`
4. HTTPS URL
5. GitHub 저장소와 릴리스 경로가 예상된 범위인지 여부
6. `releaseTag`, `releaseURL`, 다운로드 URL의 일치
7. SHA-256 형식과 양의 `byteSize`

첫 구현은 업데이트가 발견되면 `releaseURL`을 열어 사용자가 GitHub에서
직접 받도록 한다. 향후 앱이 DMG를 직접 다운로드하거나 실행한다면 JSON에
포함된 SHA-256만으로 신뢰를 결정하지 않는다. 다운로드한 파일의 해시뿐만
아니라 Developer ID 서명, Apple 공증 및 기대한 서명 주체를 별도로 검증해야
한다.

## 릴리스 게시 절차

새 안정 릴리스를 게시할 때 다음 순서를 지킨다.

1. 앱의 마케팅 버전과 빌드 번호를 확정한다.
2. 서명·공증된 DMG와 검증 자료를 GitHub Release에 게시한다.
3. 공개 다운로드 URL, 자산 크기, SHA-256을 실제 릴리스 자산과 대조한다.
4. `current-release.json`의 모든 필드를 새 릴리스로 한 번에 변경한다.
5. 정적 사이트 검증을 통과시킨 뒤 GitHub Pages에 배포한다.
6. 공개 JSON을 다시 읽어 태그, 빌드, URL 및 해시를 확인한다.
7. 앱의 업데이트 확인 성공·최신·실패 흐름을 검증한다.

릴리스 자산이 공개되기 전에 매니페스트를 먼저 올리면 사용자가 존재하지 않는
다운로드로 이동할 수 있으므로 순서를 바꾸지 않는다.

## 앱 구현의 최소 검증 사례

- 같은 빌드: 최신 버전
- 더 높은 원격 빌드: 업데이트 있음 및 올바른 릴리스 URL
- 더 낮은 원격 빌드: 매니페스트 지연 진단
- 지원하지 않는 `schemaVersion`
- 다른 `product` 또는 `channel`
- 손상된 JSON과 누락 필드
- 유효하지 않거나 허용 범위를 벗어난 URL
- 타임아웃, 오프라인, HTTP 오류 및 요청 취소
- 중복 버튼 입력 시 단일 네트워크 요청

웹사이트 표시 실패와 앱 업데이트 확인 실패는 서로 독립적으로 처리한다.
웹사이트가 매니페스트를 불러오지 못하면 버전을 추측하지 않고 안정적인
GitHub `releases/latest` 링크를 유지한다.
