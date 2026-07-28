# ForgePlay Game Mode 라이선스 문서

이 디렉터리는 ForgePlay Game Mode에 적용되는 확정 라이선스 정책,
적용 범위, 저작권 고지와 배포 조건을 기록한다.

## 확정한 방향

- 대상: 현재 구조에서 식별되는 ForgePlay Game Mode 구현 코드
- 공개 라이선스: `GPL-3.0-only`
- 저작권자 표시: `Copyright (C) 2026 Facta-Leopard`
- 외부 코드 기여: 받지 않음
- 배포 방식: GitHub Release의 바이너리와 대응 소스를 동시에 공개

GPLv3를 완전히 준수하는 이용자는 별도 허락 없이 상업적으로도 사용할
수 있다. GPL 의무를 생략한 독점 배포 권한은 부여하지 않는다.

## 문서 구성

1. `DECISION_KO.md`  
   확정한 방향, 허락의 의미와 현재 결합 구조의 핵심 효과
2. `GPL_COMPARISON_KO.md`  
   GPLv2·GPLv3, `only`·`or-later`, GPL·LGPL·PolyForm 차이
3. `GAME_MODE_LICENSE_SCOPE_KO.md`  
   현재 파일 구조와 작동 기전에 따른 상세 한국어 적용 범위
4. `GAME_MODE_LICENSE_SCOPE.md`  
   GitHub 공개용 영문 적용 범위
5. `GAME_MODE_FILE_LICENSES.json`  
   전체 파일·혼합 파일·해시 고정 패치의 기계 판독 가능한 라이선스 지정
6. `GAME_MODE_SYMBOL_MANIFEST.md`  
   Game Mode와 일반 책임이 섞인 파일의 정확한 선언 경계
7. `GAME_MODE_NOTICE`  
   바이너리와 소스 배포물에 포함할 저작권·출처 고지
8. `../GPL-3.0-only.txt`  
   수정하지 않은 GNU GPL version 3 영문 전문
9. `../LGPL-2.1-or-later.txt`  
   Wine 원본에서 복사한 GNU LGPL version 2.1 전문
10. `../../LICENSE.md`  
   다중 라이선스 저장소의 루트 적용 범위표

## 배포 원칙

- 이 문서 세트는 확정 정책이다.
- 정확한 소스 범위는 `GAME_MODE_LICENSE_SCOPE.md`를 기준으로 한다.
- Game Mode 바이너리를 배포할 때는 버전이 일치하는 대응 소스를 같은
  시점에 제공한다.
- 확정된 `bundled-direct-dmg` 구성은 D3DMetal을 Apple의 자체 조건이
  적용되는 별도 제3자 구성요소로 포함한다. Apple 법적 문서와 원본
  코드 서명을 보존하며 D3DMetal을 GPL로 재라이선스하지 않는다.
- 공식 저장소는 외부 코드 기여를 받지 않는다. 이 운영 정책은 GPL이
  허용하는 포크·수정·재배포를 제한하지 않는다.
