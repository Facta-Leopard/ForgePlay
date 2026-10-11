# ForgePlay 공개 소스

정확한 릴리스 버전·빌드는 `SOURCE-BOUNDARIES.json`에 기록합니다.

이 묶음은 ForgePlay의 공개 대상 구현과 버전에 맞는 빌드 자료입니다.
Mac 런처/데스크탑의 별도 바이너리 허가 대상 래퍼 전체를 공개한 묶음은 아닙니다.
ForgePlayVP와 자체 VR·공용 전송/영상/입력 구현은 GPL-3.0-only 공개 범위에 포함합니다.

| 폴더 | 범위 |
| --- | --- |
| `ForgePlay/` | 직접 작성한 구성요소·VR/VP·공용 지원 코드. 파일별 고지와 기존 별도 조건을 따릅니다. |
| `Wine/` | Wine 원본, 버전에 맞는 패치, Wine에서 파생한 로더/호스트 코드. 원저작권과 해당 LGPL/GPL 조건을 유지합니다. |
| `ThirdParty/` | Valve ABI·ONNX Runtime·모델 정의 등 별도 권리자의 원본/명시된 수정본과 대응 소스. ForgePlay의 독자 구현으로 주장하지 않습니다. |
| `Build/` | 구성요소 빌드·패키징 도구와 설정. 사용자 서명 설정·개인키는 포함하지 않습니다. |
| `Notices/` | 라이선스 전문, 원저작권 고지, 정확한 적용 범위와 출처. |

**폴더 이름이 단일 라이선스를 부여하지는 않습니다.** `Notices/LICENSE.md`와
`Notices/LICENSES/ForgePlayVR/NOTICE.txt`·`SCOPE.json`, 각 파일의 고지가 기준입니다.
Wine 유래 Game Mode 호스트는 기존 GPL 전환 기록을, VR Unix loader는 LGPL 및 추가 링크
허가를 유지합니다. Wine을 사용한다는 이유로 자체 VR 코드를 Wine 원본으로 분류하지 않습니다.
제3자 자료의 고지는 변경하거나 작성자 소유로 바꾸지 않았습니다.

자체 코드의 빠진 저작권 주석을 공개용 사본에 보완했습니다. 실행문은 변경하지 않았으며
`SOURCE-BOUNDARIES.json`이 실제 빌드 입력과 공개 사본의 SHA-256을 각각 기록합니다.
파일 번호·빌드 환경 등의 차이까지 포함한 비트 단위 재현을 보장한다는 뜻은 아닙니다.
설정 JSON·패치·원본 소스 압축파일의 형식은 주석 삽입으로 변경하지 않았습니다.

빌드에 필요한 원래 상대경로는 다음 명령으로 새 폴더에 복원합니다.

```sh
python3 restore-layout.py --output /원하는/새/ForgePlaySources
```

복원기는 파일 해시와 경로를 검사하고 새 폴더만 생성합니다. 그 폴더의 `BUILDING.md`에
native/VR 빌드 방법이 있습니다. Wine·게임을 자동 실행하거나 설치하지 않습니다.
브랜드 이미지·모델 가중치는 각자의 별도 조건을 따릅니다. Vision Pro의 아카이빙·서명·
App Store 심사와 홈페이지의 실제 공개 소스 연결은 별도 배포 단계입니다.

Copyright (C) 2026 Facta-Leopard. 원저작자와 제3자의 권리는 각 고지대로 유지됩니다.
원본 프로젝트: https://github.com/Facta-Leopard/ForgePlay
