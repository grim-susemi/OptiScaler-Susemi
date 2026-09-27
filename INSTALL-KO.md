# 설치 안내 (한국어)

이 패키지는 OptiScaler NR 빌드(wilsjo2 v0.8.8 기반, RTX 40 MFG 언락 포함)에 한국어 메뉴 번역과 두 가지 도우미(ASI 로더, Streamline 페처)를 더한 것입니다.

- NR(뉴럴 렌더링)은 실험 기능이며 **기본 꺼짐**입니다.
- 안티치트가 있는 온라인 게임에는 사용하지 마세요.
- 설치 전에 기존 OptiScaler 파일과 INI를 백업하세요.
- 실사용 검증은 이전 v0.8.7 기반 KO 패키지의 붉은사막에서 완료했습니다. 이 v0.8.8 기반 패키지의 인게임 확인은 아직 진행 중입니다.
- RTX 20/30 MFG 언락: 아래 절은 과거 v11.1 B 패키지의 기능 설명입니다. 새 A-only 배포 후보에는 B 페이로드를 넣지 않습니다.

영문 안내: [INSTALL-DLSSNR.md](INSTALL-DLSSNR.md). 리쉐이드를 먼저 로드하는 XeFG 완성 화면 NR 설정과 되돌리기: [로드 순서 안내](docs/XEFG-NR-RESHADE-LOAD-ORDER.md).

## 빠른 설치 (프록시 방식, 기본)

1. 게임과 런처를 종료합니다.
2. 압축을 **게임 실행 파일이 있는 폴더**에 풉니다. (붉은사막: `...\Crimson Desert\bin64`)
   - `OptiScaler\`, `docs\`, `tools\`, `Licenses\` 등 폴더 구조를 그대로 유지하세요.
3. `setup_windows.bat` 실행 → 프록시 이름 선택. 다른 모드가 쓰지 않는다면 `[1] dxgi.dll`.
4. 게임 실행 → `Insert` 키로 메뉴를 엽니다. (안 되면 `Alt+Insert`도 시도)
5. 제거할 때는 설치 시 만들어진 `Remove_OptiScaler.bat`를 실행합니다.

## ASI 방식 설치 (리쉐이드·XeFG와 같이 쓸 때 권장)

ASI 방식은 로더가 필요합니다. 로더가 없으면 `OptiScaler.asi`는 로드되지 않습니다. 이 패키지는 MIT 라이선스 Ultimate ASI Loader v9.7.4를 `tools\asi-loader\`에 동봉합니다.

1. 위 2번처럼 압축을 게임 폴더에 풉니다.
2. `Install_AsiLoader_windows.bat` 실행 → `[1]` 선택 (동봉된 로더를 `winmm.dll`로 설치).
3. `setup_windows.bat` 실행 → `[8] OptiScaler.asi` 선택.
4. 게임 실행 → `Insert`로 메뉴 확인.
5. 되돌리기: `Install_AsiLoader_windows.bat` → `[4]` (백업해 둔 원본을 자동 복원) 후 `Remove_OptiScaler.bat`.

설치 도우미는 기존 파일을 덮어써야 할 때 백업하고, 확인(Y)을 받은 뒤에만 교체합니다.

## 뉴럴 렌더링(NR) 켜기 — 선택

1. `nvngx_dlssnr.dll`을 게임 실행 파일 옆에 둡니다. (별도 배포 파일입니다 — 아래 해시 확인)
2. 메뉴에서 NR(Neural Rendering)을 켜고 **패스 1개**로 시작합니다.
3. 정상 동작하면 패스를 늘려가며 조정합니다.

| 런타임 | 대상 GPU | SHA-256 |
| --- | --- | --- |
| NVIDIA 서명 원본 | RTX 50 | `E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E` |
| ShortFuse 호환 | RTX 20/30/40 (RTX 50 경로 유지) | `E67DEE209320CDAFE0E93E45675D7AA34323A53ACC57A72B2E40A181581C989A` |

호환 런타임은 [ShortFuse RenoDX 스레드](https://discord.com/channels/1408098019194310818/1545049227321810974)에서 받습니다. 파일이 수정되면 NVIDIA 서명이 무효가 되니 해시를 확인하세요.

```powershell
Get-FileHash .\nvngx_dlssnr.dll -Algorithm SHA256
```

NR은 OptiScaler 안에서 동작합니다. 별도 NR 헬퍼 DLL은 필요 없고, 예전 `nvngx.dll_dlssnr.dll`은 지우세요.

### NR 확대 방식 (선택)

모델 해상도를 100% 아래로 두면 모델의 답을 키우는 방식(Enlargement)을 고를 수 있습니다.

- `Lighting + colour` (`Transfer=3`): 상대 조명 이득과 색 변화를 따로 확대합니다. DX12와 네이티브 Vulkan 처리 경로에서 동작합니다.
- `Lighting + colour + DLSS` (`Transfer=4`): 같은 값을 전용 DLSS SR로 확대합니다. 업스케일 뒤 DX12 처리(기존 DX12 브리지 포함)가 필요하고, 게임 업스케일러 앞 단계와 네이티브 Vulkan 처리에서는 쓸 수 없습니다.

기본값은 지금까지처럼 Matched residual(`Transfer=1`)입니다. Classic, Matched residual, Matched residual + DLSS는 기존 알고리즘을 그대로 쓰고, 네이티브/슈퍼샘플 모델 처리에서는 새 재구성을 거치지 않습니다. 검증 범위를 포함한 자세한 내용은 [v0.8.8 릴리스 노트](docs/RELEASE-v0.8.8.md)와 [확대 문서](docs/NR-DLSS-ENLARGEMENT.md)를 보세요.

## XeFG 프레임 생성에서의 NR 배치 (선택)

XeFG를 켠 상태는 NR 배치 경로가 따로입니다. 아래 설정 전용 경로는 새 빌드 없이 바로 쓸 수 있고, 프레임 생성을 켠 채로 지연(deferred) 캐리어를 유지합니다. 프레임 생성은 계속 켜 둔 상태로 두세요. 이 빌드에는 애플리케이션 프레임 핸드오프(owned application-frame handoff)가 포함되어 있어, XeFG에서 완성 화면(finished picture) 경로를 사용할 수 있습니다. 인게임 검증은 아직 남아 있습니다. 배치 경로 자체는 [브리지 문서](docs/NR-FINISHED-BRIDGES.md)에 설명되어 있습니다.

| 설정 | 값 | 위치 |
| --- | --- | --- |
| Enlargement | Matched residual (`Transfer=1`) | Prepare NR input |
| Model resolution | 75% (`WorkingScale=0.75`) | Prepare NR input |
| Generate before upscale, apply after upscale | ON | NR pipeline |
| Apply NR to the finished picture | 지연 전용 경로에서는 OFF; 새 핸드오프가 이 빌드에 포함되어 XeFG 완성 화면 경로 사용 가능 | NR pipeline |
| Private NR upscaler | DLSS (`PrivateUpscaler=0`) | NR pipeline |
| Apply model | ON | NR pipeline |
| Compare / Debug view / skin-mask preview | OFF | Inspect NR |
| HdrTransfer | auto (false) | INI |

Transfer=1 drops the DLSS-carried enlargement (composed by the shader instead); WorkingScale=100% is the alternative that keeps Transfer=2 at ~+78% model pixels.

`[Log] LogToFile=true`, `LogLevel=2`로 두면 배치 경로가 로그에 그대로 찍힙니다.

- 지연 캐리어: `DLSS-NR deferred upscale: running: <dimensions> contribution -> private DLSS RR -> <dimensions>; applied after SR`
- 완성 화면 핸드오프: `DLSS-NR finished picture: <N> frames, <W>x<H>, OptiScaler FG true, same producer queue true, game-frame handoff true`
- XeFG 경로 콜드 스타트: `NR_XEFG_ROUTE streamline_registered=0 source=app_proxy queue_source=xefg_application format=<DXGI_FORMAT> colorspace=<DXGI_COLOR_SPACE>`
- 원본 프록시 Present 뒤: `NR_XEFG_PRESENT generation=<G> frame=<F> enabled=1 framegen_result=0 frames_presented=6`

주의할 점 세 가지입니다.

- 프레임 생성은 켜 둔 채로 두세요. no FG-OFF workaround exists, 즉 FG를 끄는 우회로는 없습니다.
- 동봉된 XeFG SDK는 HDR10 (`R10G10B10A2_UNORM`)만 지원합니다: no FP16/scRGB, FP16과 scRGB는 지원하지 않습니다.
- frames_presented counts submitted pictures, not verified scanout. 즉 제출된 화면 수를 세는 값이고, 실제 스캔아웃까지 확인한 값은 아닙니다.

이 배치 경로들은 이 장비의 게임 안에서 검증하지 않았습니다. 여기에는 RTX 20/30 실기 GPU도, XeFG 세션도 없습니다. 새 R2 후보 역시 인게임 검증을 마치지 않았습니다. 리쉐이드 선행 로드의 제한 조건과 원본 바이트 복원 방법은 [별도 안내](docs/XEFG-NR-RESHADE-LOAD-ORDER.md)를 보세요. 최종 인게임 확인은 소유자가 직접 진행합니다.

## 프레임 생성 런타임 (선택)

게임에 NVIDIA Streamline DLL이 없거나 낡았을 때만 사용하세요.

1. `Streamline_fetcher_windows.bat` 실행 → `[1]` (최신 NVIDIA Streamline 릴리스를 `OptiScaler\streamline`에 설치)
2. `[3]` 설치 검증, `[4]` 제거

## RTX 40 MFG 언락 (선택, RTX 40 전용)

1. 프레임 생성 설정에서 **RTX 40 MFG unlock (restart)** 를 켭니다.
2. 저장하고 게임을 재시작합니다. (해제도 재시작 필요)
3. RTX 40(Ada) 전용이며, 지원되는 DLSSG 런타임이 필요합니다.

## RTX 20/30 (SM75/SM86) MFG 언락 (선택)

**새 A-only 배포 후보:** `sdli1995/dlssg_for_sm86` B 페이로드, NVIDIA 런타임과 파생 SM75 커널을 동봉하지 않습니다. 재배포 권리 근거가 확인되지 않았으므로 과거 ZIP에서 복사하거나 수동 사이드로드하는 우회 절차도 안내하지 않습니다. 아래 설정과 동작은 과거 v11.1 B 패키지에 대한 설명이며 새 후보의 설치 절차가 아닙니다. 과거 v11.1에서는 동봉되어 사이드로드할 필요가 없었지만, 새 후보에는 `OptiScaler\dlssg_sm86\dlssg_sm86.dll`이 없습니다.

### 요구 사항

- **RTX 20/30 전용**(Turing SM75, Ampere SM86). RTX 40에서는 [RTX 40 MFG 언락](docs/RTX40-MFG.md)을 쓰세요. 두 언락을 동시에 켜면 안 됩니다.
- **드라이버 R580 이상 권장.** 더 낮은 드라이버를 막지는 않지만, 페이로드 제작자가 밝힌 기준이 R580 이상입니다.
- **과거 v11.1 B에만 동봉:** 그 ZIP에는 `OptiScaler\dlssg_sm86\dlssg_sm86.dll`, 같은 폴더의 `dlssg_sm86.ini`와 `THIRD_PARTY_NOTICES.txt`가 있었습니다. 새 A-only 후보에는 없습니다.
- 프레임 생성이 NVIDIA Streamline을 거치는 게임이어야 합니다. 페이로드는 생성한 프레임을 게임 자체의 DLSS-G 플러그인에 넘기고, 배수는 게임 FG 메뉴가 정합니다.
- 기본값은 꺼짐이고, 바꾼 뒤에는 재시작해야 적용됩니다.

### 켜는 방법

메뉴의 프레임 생성 설정에서 **RTX 20 / 30 (SM75 / SM86) MFG 잠금 해제** 절을 엽니다.

1. 과거 B 버전에 한해 **SM75/SM86 MFG 활성화 (실험적; 재시작)** 를 켭니다. External FG도 함께 켜지고, 배수는 게임 자체 FG 메뉴에서 고릅니다. 새 A-only 후보에서 이 설정만 켜도 페이로드가 생기지는 않습니다.
2. 기본 4X보다 높게 쓰려면 **최대 생성 프레임 수**(1~5)를 조정합니다.
3. Auto가 잘 맞지 않을 때만 **커널 이미지**를 고릅니다. Auto는 그래픽카드에서 형식을 판단하고, PTX는 RTX 20에서 안전한 선택이며, Cubin은 Windows에서 정확한 물리 일치가 필요합니다.
4. 선택, RTX 30 전용: **하드웨어 바이리니어 (근사 샘플링)** 는 정확한 출력 대신 GPU 지연을 약 2~4% 줄입니다.
5. 설정을 저장하고 게임을 재시작합니다. 절 안의 상태 줄(20/30 잠금 해제 상태)이 로더 상태(`Disabled`, `Ineligible`, `Conflict`, `Loaded` 등)와 그 이유를 보여줍니다.

INI로 켜려면 실행 전에 아래 키를 넣습니다.

```ini
[DLSSG]
AmpereMfgUnlock=true
AmpereMfgMaxFrames=3
AmpereMfgKernelImage=auto
AmpereMfgHardwareBilinear=false
```

| 키 | 값 | 기본 | 설명 |
| --- | --- | --- | --- |
| `AmpereMfgUnlock` | true/false | false | 20/30 언락을 켭니다. 시작할 때 한 번만 읽습니다. |
| `AmpereMfgMaxFrames` | 1~5 | 3 | 광고하는 최대 배수: **1 = 2X, 2 = 3X, 3 = 4X, 4 = 5X, 5 = 6X**. 실제 배수는 게임 FG 메뉴가 정합니다. |
| `AmpereMfgKernelImage` | auto, PTX, Cubin | auto | 커널 형식. Auto는 물리 GPU에서 판단합니다. |
| `AmpereMfgHardwareBilinear` | true/false | false | RTX 30(SM86) 전용: 근사 하드웨어 바이리니어 샘플링, GPU 지연 약 2~4% 감소. |

**6X 주의:** 5(6X)는 게임이 Streamline FG 플러그인 2.11.1 이상을 함께 배포할 때만 동작합니다. 그보다 낮은 플러그인이면 페이로드가 요청을 잘라내고(로그에 `limit_clamped`) 그 플러그인이 지원하는 최대 배수까지만 나옵니다. 게임이 실제로 그만큼의 프레임을 요청해야 한다는 점도 같습니다.

여기 있는 설정은 모두 시작할 때 한 번만 읽습니다. 설정을 저장하고 게임을 재시작하세요. 실행 중에는 적용되지 않습니다.

### 검증 범위

**이 빌드에는 RTX 20/30 실기 GPU가 없었습니다.** 이 프로젝트의 빌드·테스트 호스트는 RTX 4090이라, 20/30 경로는 로더·설정·패키징·장착 순서 수준까지만 확인했습니다. 실제 RTX 20/30 카드에서 어떻게 동작하는지는 **외부 제보(externally reported)** 로만 알려져 있고, 여기서 측정하지 않았습니다. 20/30의 배수와 성능은 검증되지 않은 것으로 보세요.

### 끄기와 제거

1. `[DLSSG] AmpereMfgUnlock=false`로 바꾸거나 체크를 해제하고, 설정을 저장한 뒤 재시작합니다.
2. External FG를 더 쓰지 않는다면 함께 끕니다. 언락이 켜지면서 External FG를 켜 두고, 언락을 끈 뒤에도 저장된 값이 남습니다.
3. `OptiScaler\dlssg_sm86\` 폴더를 지우면 모듈, 동봉 INI, `logs\` 폴더가 함께 사라집니다. 다른 파일은 추가되지 않았고 레지스트리 키도 쓰지 않습니다.
4. 패키지 전체를 지우려면 평소처럼 `Remove_OptiScaler.bat`를 실행합니다.

### 출처 표기

과거 v11.1 B에 동봉했던 페이로드는 `sdli1995/dlssg_for_sm86` v0.3.5(고정 커밋 `9621db5`)이고 당시 수정 없이 넣었습니다. 원본: https://github.com/sdli1995/dlssg_for_sm86

이 페이로드에 들어 있는 NVIDIA 런타임·모델 구성품과 SM75 커널 계열은 각자의 조건을 따릅니다. 과거 B 패키지에서 업스트림 고지는 `OptiScaler\dlssg_sm86\THIRD_PARTY_NOTICES.txt`로, 사본은 `Licenses\`에 함께 들어 있었습니다. 업스트림은 본문에서 GPLv3를 주장하지만 저장소에 `LICENSE` 파일이 없습니다. 이 라이선스 공백은 숨기지 않고 여기에 적어 둡니다. 페이로드는 자체 서명(`CN=DLSSG for SM86`)이라 SmartScreen에서 알 수 없는 게시자로 표시됩니다.

## XeFG MFG 언락 (네이티브, 선택)

XeFG의 멀티 프레임 생성은 이제 외부 `XeFGUnlock.asi` 없이 본체에서 동작합니다. 업스트림 OptiScaler `bb1619ec`(Coldwood1026)를 그대로 이식한 것으로, 프로바이더 `libxess_fg.dll`의 매핑된 이미지만 패치하고 디스크 파일은 건드리지 않습니다.

- 기본값은 **꺼짐**입니다. `[XeFG] UnlockMFG=auto`(내장 기본 false), `MaxInterpolatedFrames=auto`(내장 기본 5, 즉 6X 상한), `ExtraPacing=auto`(내장 기본 true).
- 설정에서 MFG 배수를 2X/3X/4X 이름 항목이나 `Custom...`으로 고릅니다. 저장하고 게임을 재시작하세요.
- **4X 위에서는 VSync나 프레임 제한이 필요합니다.** 표시 주사율보다 빠르게 제시되면 찢어짐과 끊김이 생기고, 프로바이더 안에서는 되돌릴 수 없습니다. 메뉴가 4X 초과에서 경고를 표시합니다.
- **외부 `XeFGUnlock.asi`와 함께 쓰지 마세요.** 먼저 온 쪽이 `libxess_fg.dll`을 패치해 두면 네이티브 바이트 검증이 실패하고 패치 전체가 롤백되며 프로바이더는 원래 상태로 남습니다. 즉 실패해도 손상이 아니라 “언락 안 됨”입니다.
- 되돌리기: `UnlockMFG=false` 또는 `MaxInterpolatedFrames=1`(패치 자체를 하지 않음). 상한을 낮추려면 `MaxInterpolatedFrames=5`.
- 프로바이더 빌드가 다르면 언락이 스스로 거부합니다. 로그에 `XeFG unlock: unrecognised provider build ...` 뒤에 `rolled back`이 찍힙니다.
- 6X 초과는 검증되지 않았습니다.

이 트리에서는 아직 인게임 검증 전이고, 인게임 확인은 소유자가 진행합니다. 자세한 내용: [MFG 언락 문서](docs/README-XeFG-MFG-Unlock.md), [페이싱 문서](docs/README-XeFG-Pacing.md), [설정 문서](Config.md)

## 파일 구성

| 파일 | 설명 |
| --- | --- |
| `OptiScaler.dll` | 본체. `setup_windows.bat`이 선택한 프록시/ASI 이름으로 바꿔줍니다. |
| `OptiScaler.ini` | 설정 파일. 업데이트할 때 유지하세요. |
| `setup_windows.bat` / `setup_linux.sh` | 설치 및 언인스톨러 생성. |
| `Install_AsiLoader_windows.bat` | 동봉된 Ultimate ASI Loader(MIT) 설치/확인/제거. |
| `Streamline_fetcher_windows.bat` | 게임에 없을 때 NVIDIA Streamline 런타임을 내려받습니다. |
| `tools\` | 두 도우미가 쓰는 스크립트. `tools\asi-loader\`에 로더와 라이선스. |
| `docs\`, `Licenses\` | 상세 기술 문서와 서드파티 라이선스. |

## 문제 해결

먼저 `[Log] LogToFile=true`, `LogLevel=2`로 두고 렌더링 장면에 들어가세요.

- **메뉴가 안 열림:** 게임 실행 파일 폴더가 맞는지, 로드된 프록시, `TargetProcessName=auto`, 백신 격리 여부를 확인합니다. ASI 설치라면 `Install_AsiLoader_windows.bat` → `[3]`으로 로더 존재를 확인하세요.
- **메뉴가 입력을 무시:** `[Hotfix] ManualInputPolling=true`를 켜고 다른 오버레이를 끕니다.
- **NR 모델 초기화 실패:** 런타임 해시와 드라이버 지원을 확인하고, 로그의 정확한 오류 문구를 함께 알려주세요.
- **XeFG + 리쉐이드 동시 사용:** 프록시 방식은 다른 인젝터와 충돌할 수 있습니다. ASI 방식만으로 로드 순서가 정해지지는 않습니다. [리쉐이드 선행 로드 안내](docs/XEFG-NR-RESHADE-LOAD-ORDER.md)의 조건에 맞지 않으면 중단하세요.

프레임 생성은 [upstream OptiFG 안내](https://github.com/optiscaler/OptiScaler/wiki/OptiFG)를 따르세요. NR이 된다고 FG 호환까지 보장되진 않습니다.
