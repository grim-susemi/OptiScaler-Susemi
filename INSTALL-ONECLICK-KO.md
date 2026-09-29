# 한 번에 설치하기: Install_OptiScaler_windows.bat (한국어 안내)

이 문서는 수세미 패키지의 권장 설치 방법을 안내합니다. `Install_OptiScaler_windows.bat` 하나만 실행하면
언어 선택, 게임 실행 파일 선택, 진단, 설치 동의, 적용, 결과 확인까지 한 번에 진행됩니다. 다른 설치
스크립트를 따로 실행할 필요가 없습니다. 화면마다 질문이 하나씩 나오고, Enter는 항상 안전한 기본값입니다.

사용할 패키지는 rc2 이상이어야 합니다. 과거 rc1은 쓰지 마세요. rc1에는 기록된 백업이 없을 때 ASI 로더
제거가 설치된 로더까지 삭제할 수 있는 제거 기능이 있었습니다. rc2부터 고쳐졌고, 이 도구는 rc1의
안전하지 않은 제거 기능을 절대 사용하지 않습니다.

## 시작 전에 필요한 것

1. **게임 실행 파일**: 64비트(.exe) 게임 본체의 경로. 게임과 런처는 종료한 상태로 두세요.
   게임이 실행 중이면 도구가 설치를 중단합니다.
2. **rc2 이상의 수세미 패키지** (위의 rc1 주의를 읽으세요).
3. **ReShade (선택)**: 도구가 ReShade를 내려받지 않습니다. 공식 ReShade 설치로 직접 준비했거나
   기존 ReShade 파일을 이미 보유한 경우에만 함께 설정할 수 있습니다.
4. **NR(뉴럴 렌더링, 선택)**: `nvngx_dlssnr.dll`을 직접 준비해야 합니다. 모델 두 종류의 SHA-256은
   [INSTALL-KO.md](INSTALL-KO.md)에 기록되어 있으니 내려받은 파일의 해시를 확인하세요.
   도구가 모델을 내려받거나 NR을 켜지는 않습니다. NR은 기본 꺼짐이며 게임 메뉴에서 직접 켭니다.
5. **Streamline 런타임 (선택)**: 이 도구는 내려받지 않습니다. 게임에 Streamline이 없을 때만
   뒤의 "레거시 스크립트" 절의 별도 스크립트로 공식 NVIDIA 내려받기를 진행합니다(동의 필요).

안티치트가 있는 온라인 게임에는 이 패키지를 사용하지 마세요.

## 설치 5단계 (화면 순서 그대로)

### 1단계: 도구를 실행하고 언어를 고릅니다

`Install_OptiScaler_windows.bat`를 실행합니다.

```
[1] 한국어 (기본값)
[2] English
언어를 선택하세요 [1/2, Enter=1]:
```

Enter는 한국어, 2는 영어입니다. 이 화면의 질문은 하나뿐입니다.

### 2단계: 게임 실행 파일을 고릅니다

파일 선택 대화상자(제목: "게임 실행 파일(.exe) 선택")가 열립니다. 대화상자를 쓸 수 없는 환경에서는
전체 경로를 붙여넣는 입력으로 전환됩니다. 아무 것도 고르지 않고 끝내면 도구는 아무 것도 바꾸지 않고
종료합니다. 고른 경로는 화면에 다시 표시되니 확인하세요.

### 3단계: 진단 결과를 확인합니다 (읽기 전용)

도구가 선택한 실행 파일의 폴더만 살펴봅니다. 파일을 쓰지 않고, 네트워크를 쓰지 않고, 게임을
실행하지 않습니다. 로더·OptiScaler·ReShade는 파일 이름이 아니라 파일 내용(해시와 PE 정보, 설정
흔적)으로 구분합니다. 알 수 없거나 판단이 서지 않는 파일은 이유를 알려주고 진행하지 않습니다.

결과가 **준비**면 4단계로 진행합니다. 그 외 결과는 세션이 여기서 멈춥니다(아무 것도 설치되지 않음).
각 결과의 평이한 다음 행동은 아래 "진단 결과와 다음 행동" 절을 보세요.

### 4단계: 설치에 동의합니다

```
설치를 진행할까요? [1] 아니요 (기본값)  [2] 예
```

Enter나 1은 아니요입니다. 아무 것도 설치하지 않고 종료합니다. 2는 예입니다. 예를 고르면 설치가
진행되며, 대화형 흐름은 ASI 방식(`OptiScaler.asi` + 로더 `winmm.dll`)으로 설치합니다.

ReShade를 먼저 로드할 수 있는 상태이면 이어서 질문이 하나 더 나옵니다.

```
ReShade를 먼저 로드하도록 winmm.ini를 설정할까요? [1] 아니요 (기본값)  [2] 예
```

예라고 답하면 winmm.ini 설정 동의까지 포함됩니다. 이미 올바르게 설정되어 있으면 도구는 파일을
바꾸지 않고 그 사실만 알려줍니다. 조건이 맞지 않으면 이 질문은 생략되고 건너뜀 사유가 표시됩니다.

### 5단계: 적용과 결과를 확인합니다

진행 과정은 `trace|` 줄로, ReShade 우선 설정에 필요한 정확한 변경(대상 파일과 들어가는 키)은
`preview|` 줄로 적용 전에 보여줍니다. 적용이 끝나면 도구가 설치된 파일의 바이트를 직접 검증하고,
마지막에 기계 판독용 결과 줄(`status=...`) 하나를 남깁니다. 성공하면 결과 화면이 나옵니다.

```
== 설치 결과 ==
게임 내 확인은 소유자만 가능합니다: 게임을 실행해 OptiScaler가 로드되는지 직접 확인하세요.
백업 위치: <게임 폴더>\.susemi-backup
제거 방법: Install_OptiScaler_windows.bat remove -Exe "<게임 exe 경로>" -Consent yes
```

## 진단 결과와 다음 행동

| 진단 결과 | 뜻 | 다음 행동 |
| --- | --- | --- |
| 준비 (ready) | 설치에 필요한 상태입니다 | 4단계 설치 동의 화면으로 진행합니다 |
| 입력 부족 (missing-input) | 필요한 파일이 없거나 찾을 수 없습니다 | 도구가 알려준 부족 항목을 먼저 준비하세요. 실행 파일을 못 찾으면 올바른 게임 .exe를 고릅니다. 로더와 OptiScaler가 아직 없는 게임 폴더라면 명령행 install 모드(아래)로 설치하거나 레거시 스크립트로 기초 설치를 먼저 하세요. winmm.ini가 ReShade.asi를 참조하는데 파일이 없으면 검증된 ReShade 파일을 직접 준비하세요. |
| 충돌 (conflict) | 다른 모드의 파일이나 설정이 막고 있습니다 | 사유에 적힌 파일과 설정을 직접 고친 뒤 다시 실행하세요. 도구는 여러 개인 로더를 지우거나, loadplugins=0 / loadfromscriptsonly=1 을 되돌리거나, 다른 파일의 loadextraplugins 키를 수정하지 않습니다. 로더가 여러 개면 하나만 남기고, 막는 설정은 직접 되돌리세요. |
| 게임 확인 필요 (game-verification-required) | 게임이 실행 중입니다 | 게임과 런처를 종료한 뒤 다시 실행하세요. |

이 밖에 32비트(x86) 실행 파일은 미지원(unsupported)으로 거부합니다.

## ReShade를 먼저 로드하기 (ReShade-first)

공식 OptiScaler ASI 방식입니다. ASI 로더(`winmm.dll`)의 설정 파일 `winmm.ini`에
`[globalsets]` `loadextraplugins=ReShade.asi` 를 넣어, ReShade를 일반 ASI 플러그인보다 먼저
읽게 만듭니다. 이 방식은 로더가 직접 ReShade.asi를 읽기 때문에 dxgi.dll 같은 프록시 이름을
다른 인젝터와 양보 없이 쓸 수 있습니다.

- **검증만 통과한 파일을 변환합니다.** 이름이 `dxgi.dll` 같은 ReShade 프록시 DLL이라도 내용
  (PE 구조, ReShade 버전 정보, ReShade.ini나 reshade-shaders 폴더 같은 흔적)이 검증될 때만
  다룹니다. 검증되지 않은 파일은 절대 변환하지 않습니다. 대화형 흐름은 ReShade.asi가 이미
  있고 검증을 통과할 때만 이 설정을 제안하고, 프록시 변환은 명령행 모드의 `-ConvertReshade`로
  제공합니다.
- **변환은 항상 복사입니다.** `ReShade.asi`는 원본 프록시 파일의 사본으로 만들어지고 원본은
  그대로 남습니다. 이후 게임이 두 파일을 모두 읽을 수 있으니, 원본을 다른 용도로 쓰는 중이면
  직접 정리하세요. 파일을 옮기거나 이름을 바꾸지는 않습니다.
- **winmm.ini 규칙.** 파일이 없으면 새로 만들고, 기존 파일은 이 설치기가 이전에 만들거나 수정한
  경우에만 키를 추가합니다(기존 바이트는 그대로 보존). 소유하지 않은 INI나 이미
  loadextraplugins 키가 있는 INI는 편집하지 않고 이유를 알려줍니다. 나중에 읽히는 다른
  global.ini가 이 키를 덮어쓰면 그 파일을 절대 고치지 않고 경고를 남깁니다.

## 명령행 모드 (고급 사용자, 자동화용)

```
Install_OptiScaler_windows.bat diagnose -Exe <게임.exe 경로> [-Lang ko|en]
Install_OptiScaler_windows.bat install  -Exe <게임.exe 경로> -Consent yes|no
                                        [-Route asi|proxy] [-ProxyName <이름>]
                                        [-ReshadeFirst [-IniConsent yes|no] [-ConvertReshade]] [-Lang ...]
Install_OptiScaler_windows.bat remove   -Exe <게임.exe 경로> -Consent yes [-Lang ...]
```

- `diagnose`: 읽기 전용 진단만 하고 끝냅니다.
- `install`: 게임이 실행 중이거나, 충돌이 있거나, 실행 파일을 못 찾거나 32비트인 경우가 아니면
  진행합니다.
  `-Consent no`이면 항상 거부합니다. `-Route proxy`(기본 프록시 이름 dxgi.dll, `-ProxyName`으로
  변경)는 코어를 프록시 DLL로 놓는 방식입니다. `-ReshadeFirst`는 ASI 방식에서만 동작하고
  `-IniConsent yes`가 필요합니다.
- `remove`: `-Consent yes`가 필수입니다.
- 종료 코드: **0** 성공/준비, **1** 거부·실패·취소, **2** 잘못된 실행(인자 오류).
- 출력: 마지막 `status=...` 줄이 기계 판독용 결과입니다. 그 앞의 `trace|` 줄은 진행 과정,
  `preview|` 줄은 적용 전 미리보기입니다.

## 실제 실행 예제 (임시 폴더의 비어 있는 게임 폴더에서 실행한 실제 결과)

```
> Install_OptiScaler_windows.bat diagnose -Exe "C:\Users\USER\AppData\Local\Temp\susemi-t11-fixture\GameX\GameX.exe"
status=missing-input reason=no-loader-or-optiscaler
입력 부족: UAL 로더/OptiScaler가 식별되지 않았습니다 (C:\Users\USER\AppData\Local\Temp\susemi-t11-fixture\GameX; *.dll/*.asi 0개).
```
종료 코드 1, 폴더 변화 없음.

```
> Install_OptiScaler_windows.bat install -Exe "C:\Users\USER\AppData\Local\Temp\susemi-t11-fixture\GameX\GameX.exe" -Consent no
status=refused reason=consent-required
동의(Consent)가 필요합니다. -Consent yes 로 다시 실행하세요.
```
종료 코드 1, 아무 것도 설치하지 않음.

```
> Install_OptiScaler_windows.bat remove -Exe "C:\Users\USER\AppData\Local\Temp\susemi-t11-fixture\GameX\GameX.exe" -Consent yes
status=missing-input reason=no-install-record
해당 게임 폴더에 설치 기록이 없습니다.
```
종료 코드 1, 아무 것도 바뀌지 않음.

잘못된 실행(모르는 동작)은 종료 코드 2로 거부됩니다:
`status=invalid-invocation reason=unknown-action`. 영어 출력(`-Lang en`)도 같은 결과 줄을
냅니다: `missing input: no UAL loader/OptiScaler identified (...; 0 *.dll/*.asi files).`

## 제거하는 방법

현재 버전에서 제거는 명령행으로 합니다 (성공한 설치의 결과 화면에도 같은 명령이 표시됩니다).

```
Install_OptiScaler_windows.bat remove -Exe "<게임 exe 경로>" -Consent yes
```

- 제거 대상은 이 설치기가 만들거나 바꾼 파일뿐입니다. 원본은 `게임 폴더\.susemi-backup`에
  남겨둔 원본 그대로 복원되고, 설치기가 만든 새 파일은 지워집니다. 다른 모드의 파일은 절대
  만지지 않습니다.
- 대상 파일이 설치 뒤에 바뀌었거나, 백업이 없거나 변조되었거나, 설치 기록이 없으면 도구는
  아무 것도 바꾸지 않고 이유와 함께 거부합니다.
- 이미 제거된 상태에서 다시 실행하면 "할 일 없음"으로 끝납니다. 제거 기록이 남은 자리에 이
  도구가 아닌 경로로 파일이 다시 생겨 있으면 삭제를 거부합니다.

## 실패했을 때의 안전 원칙

- 도구는 자신이 만들거나 바꾼 파일만 대상으로 삼습니다. 다른 모드(모더)의 DLL이나 설정 파일은
  절대 삭제하거나 수정하지 않습니다.
- 원본은 게임 폴더 안 `.susemi-backup`에 원본 바이트 그대로 보존되고, 설치 내역은
  `%LOCALAPPDATA%\susemi-installer\journal`의 기록 파일에 남습니다. 제거는 이 기록을 근거로만
  진행됩니다.
- 적용 도중 실패하면 도구가 자체 복구를 실행해 기록된 원본으로 되돌립니다. 거부(동의 없음,
  충돌, 소유 아닌 INI)는 적용 전에 일어나므로 폴더가 바뀌지 않습니다.

## 설치 성공의 의미와 게임 확인 (사용자 몫)

설치 성공은 설치된 파일의 바이트를 검증했다는 뜻까지입니다. 화면에서 NR, ReShade 효과, XeFG가
실제로 나오는지는 도구가 판단하지 않습니다. 게임을 직접 실행해 확인하는 것은 사용자의 몫입니다.
성공 화면은 그 한계를 명시합니다.

## 한계

- 모든 게임을 보장하지 않습니다. 게임마다 로더와 주입 방식이 달라서, 도구가 정상으로 판단해도
  게임에서 동작하지 않을 수 있습니다.
- 32비트 게임은 지원하지 않습니다.
- 모델이나 ReShade를 자동으로 내려받지 않고, 게임을 실행하지 않고, 다른 모드의 설정 파일을
  편집하지 않습니다. Streamline 런타임도 이 도구의 범위가 아닙니다.

## 레거시 스크립트 (고급 사용자용, 그대로 남아 있습니다)

`setup_windows.bat`(단독 실행용), `Install_AsiLoader_windows.bat`,
`Streamline_fetcher_windows.bat`는 기존 사용자를 위해 그대로 남아 있습니다. 원클릭 도구는 이
스크립트들을 실행할 필요가 없고, 이것이 권장 경로입니다. 게임에 Streamline 런타임이 없을 때만
`Streamline_fetcher_windows.bat`로 공식 NVIDIA 내려받기를 동의 후 진행할 수 있습니다.