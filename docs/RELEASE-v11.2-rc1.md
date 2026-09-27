# OptiScaler-Susemi v11.2-rc1 후보 안내

**실험판, 게시 전 소스 안내입니다.** 이 문서가 저장소에 있다고 해서 태그나 다운로드 파일이 이미 게시됐다는 뜻은 아닙니다. 게시 후에는 [v11.2-rc1 직접 페이지](https://github.com/grim-susemi/OptiScaler-Susemi/releases/tag/v11.2-rc1)에서 자산과 체크섬을 확인하세요. [안정판 최신 릴리스](https://github.com/grim-susemi/OptiScaler-Susemi/releases/latest)는 별도 경로이며 현재 기준 v11.1입니다. 이 후보는 A 패키지 하나만 계획합니다. 예정 파일 이름은 `OptiScaler-NR-v11.2-rc1.zip`입니다. 아직 새 ZIP을 만들지 않았으므로 이 문서에는 새 ZIP의 크기나 SHA-256이 없습니다. 빌드 후 검증된 값은 게시할 때 릴리스 노트와 `SHA256SUMS.txt`에 적습니다.

## 소스의 출처와 경계

v11.1 태그 `8f387acad612e7ce8ea0b4811823d08f31e204db`의 트리에는 당시 배포한 ZIP 제작 시점의 전체 소스가 들어 있지 않습니다. ZIP은 커밋되지 않은 donor 작업 트리 상태에서 만들어졌습니다. donor HEAD `a8eac0c4195bb5d2c93a08055c05b584d5c98953`와 v11.1은 서로 다른 역사입니다. 한쪽을 다른 쪽의 조상이나 v11.1 ZIP의 정확한 소스 스냅샷으로 부르지 않습니다. [소스 출처 기록](SUSEMI-SOURCE-PROVENANCE.md)에 파일별 복구 및 제외 근거가 있습니다.

복구 커밋 R `877f9acd1aeb3989d7ce5d30a58b150c305285e2`는 v11.1을 단일 부모로 삼아 검토한 제품 소스를 명시적으로 되살린 기록입니다. 이전에 거부된 캐시 포함 복구 커밋과도 구별됩니다. R 뒤의 설치, 패키지 안전장치, XeFG 수정과 검증 커밋은 별개입니다. 최종 문서 소스 커밋 S는 이 문서를 포함해 검증 후 확정되며, **R이나 v11.1 태그가 새 후보 ZIP의 빌드 입력이라는 뜻이 아닙니다.** 후속 빌드는 S만을 소스 입력으로 고정해야 합니다. 기존 v11.1 태그, 릴리스 문구와 A/B 자산은 이 작업에서 수정하지 않습니다.

## A-only 배포 범위

새 후보는 RTX 20/30용 B 바이너리를 배포하지 않습니다. `sdli1995/dlssg_for_sm86`의 재배포 권한이 확인되지 않았고 NVIDIA 구성품 및 파생 SM75 커널에도 별도 권리 문제가 있습니다. 과거 v11.1 B 자산은 그대로 남지만, 이 후보에 복사하거나 별도 사이드로드하는 설치 경로로 소개하지 않습니다. 새 ZIP에 RTX 20/30 MFG 페이로드가 들어 있다는 뜻도 아닙니다. `[DLSSG] AmpereMfgUnlock` 설정만 바꿔도 빠진 바이너리가 생기지 않습니다. RTX 40 내장 언락도 별도 선택 빌드 기능이며 기본 패키지에 포함됐다고 가정하지 마세요.

NR은 기본 OFF이며 호환 `nvngx_dlssnr.dll`은 별도로 구해야 합니다. ASI 방식에는 동봉된 MIT Ultimate ASI Loader v9.7.4를 `winmm.dll`로 설치하는 선택지가 있습니다. 붉은사막 DX12의 XeFG, ReShade, 완성 화면 NR 조합에 관한 [제한된 선행 로드 절차](XEFG-NR-RESHADE-LOAD-ORDER.md)는 UAL 설정에 기존 extras 키, 충돌하는 후순위 global.ini, 암묵적 modloader 의존성이나 경쟁 로더가 없는 경우에만 적용합니다. ReShade.asi와 OptiScaler.asi는 게임 실행 파일 옆에 두고, 사용자가 로컬 `winmm.ini`에서 ReShade를 먼저 로드하도록 선택합니다. ZIP은 이 설정을 자동 작성하지 않습니다. NR, finished picture, XeFG 언락은 각각 직접 켜야 하며 기본값을 강제로 바꾸지 않습니다.

앞선 R12 게임 세션에서는 ReShade 선행 로드와 NR 키 세 가지 변경이 **동시에** 일어났습니다. 당시 화면 관찰 및 적용 로그는 그 옛 게임 로컬 바이너리에 한정되고, 어느 변경 하나만의 효과나 이번 후보의 실게임 성공을 증명하지 않습니다. 새 후보의 게임 화면, 재시작 및 설정 일치 확인은 별도 검증 대상입니다. XeFG의 HDR10 `R10G10B10A2_UNORM` 경로는 FP16/scRGB를 지원하지 않습니다. 로그의 제출 프레임 수는 실제 표시 주사나 모든 화면의 품질을 증명하지 않습니다. 4X 초과에는 VSync 또는 프레임 제한을 권장하며 외부 `XeFGUnlock.asi`와 네이티브 언락을 함께 사용하지 마세요.

## 되돌리기와 upstream 현황

게임과 런처를 종료한 다음, 변경 전 백업한 `winmm.dll`, ASI, `winmm.ini`, `OptiScaler.ini` 및 관련 ReShade 설정을 원래 바이트로 복원하고 저장해 둔 SHA-256과 대조하세요. 원래 없던 파일만 생성 사실을 확인하고 제거합니다. 해시가 다르면 수기로 INI를 재작성하지 말고 중단하세요. 설치 도우미가 만든 백업은 해당 도우미의 제거 절차로만 복원합니다.

2026-09-27 확인 기준 upstream [#106](https://github.com/wilsjo2/OptiScaler-DLSSNR-PreSR-Multipass/pull/106) XeFG 완성 화면 NR 핸드오프와 [#107](https://github.com/wilsjo2/OptiScaler-DLSSNR-PreSR-Multipass/pull/107) 네이티브 언락 및 페이싱은 **둘 다 OPEN**입니다. main 대상 통합 PR 설명은 로컬 초안이며 아직 게시된 PR이 아닙니다. 이 후보의 로컬 코드 및 테스트가 upstream 병합이나 upstream 공식 지원을 의미하지 않습니다. 정식 v11.2로 자동 승격하지 않습니다.
