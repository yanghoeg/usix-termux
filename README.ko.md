# usix-termux

<div align="center">

**[한국어](README.ko.md)** &nbsp;|&nbsp; [English](README.md)

[![Android](https://img.shields.io/badge/Android-Termux-3DDC84?logo=android)](https://termux.dev)
[![Arch](https://img.shields.io/badge/Arch-aarch64-0070C0)](https://github.com/yanghoeg/usix-termux)
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

<img src="assets/desktop.png" alt="Galaxy Fold6에서 실행 중인 Termux XFCE 데스크탑" width="720">

</div>

---

Android 기기의 Termux에서 **XFCE 데스크탑 환경**을 자동 설치하는 Bash 스크립트입니다.  
[phoenixbyrd/Termux_XFCE](https://github.com/phoenixbyrd/Termux_XFCE) 에서 파생되었습니다.

**테스트 기기**: Galaxy Fold6 (Adreno 750, SD 8 Gen3), Galaxy Tab S9 Ultra (Adreno 740, SD 8 Gen2)

## 특징

- **Termux native 우선** — XFCE와 Firefox는 Termux에서 실행하고 Ubuntu / Arch proot는 필요에 따라 추가
- **proot 선택 가능** — Ubuntu / Arch Linux / 없음
- **헥사고날 아키텍처** — distro 추상화로 Ubuntu·Arch 공통 코드 유지
- **재실행 지원** — 설치된 패키지는 가능한 한 건너뛰고 관리 대상 런처와 설정은 갱신
- **선택적 GPU 가속** — App Installer로 드라이버를 설치하면 X11 런처가 Zink + Turnip 사용 여부를 판단하고 소프트웨어 렌더링으로 폴백
- **ptrace 없는 컨테이너 실행(선택)** — chroot-ng 런타임과 Android Host Info Bridge. 미코(meeco.kr) 흡혈귀왕님의 glibc rootfs 런타임 구성을 참고해 구현([아래](#ptrace-없는-런타임과-host-info-bridge))
- **Termux API 연동** — Android 클립보드 동기화, 배터리 모니터, 밝기/볼륨 조절
- **zsh + Powerlevel10k** — 기본 쉘로 설정, 자동완성·구문강조 포함

## 설치

**Android Termux**에서 실행하며 ARM64(`aarch64`)를 주 대상으로 합니다. 옵션 없이
실행하면 배포판, 필요한 경우 proot 사용자 이름, 디스플레이 백엔드를 묻습니다.
기본 백엔드는 Termux:X11 + XFCE입니다.

```bash
# 저장소를 자동으로 clone한 뒤 대화형 설치 시작
curl -sL https://raw.githubusercontent.com/yanghoeg/usix-termux/main/install.sh | bash
```

코드를 확인하거나 다시 실행할 수 있도록 직접 clone해도 됩니다.

```bash
git clone --recurse-submodules https://github.com/yanghoeg/usix-termux.git
cd usix-termux
bash install.sh
```

이미 clone했다면 설치 전에 `git submodule update --init --recursive`를 실행하세요.
`app-installer` 서브모듈은 native 전용 설치에서도 공통 헬퍼를 제공합니다.
설치된 `app-installer` 명령이 이 저장소 경로를 참조하므로 설치 후에도 폴더를 유지하세요.
위 한 줄 설치 명령은 `~/.termux-xfce-installer`를 사용합니다.

```bash
# 스크립트 실행 예: desktop을 사용할 proot 사용자 이름으로 변경
bash install.sh --distro ubuntu --user desktop
bash install.sh --distro archlinux --user desktop
bash install.sh --no-proot
bash install.sh --distro archlinux --user desktop --proot-only
bash install.sh --distro ubuntu --user desktop --no-conky

# 같은 옵션을 환경변수로 지정
DISTRO=ubuntu USERNAME=desktop bash install.sh
```

| 옵션 | 환경변수 | 설명 |
|------|----------|------|
| `--distro`, `-d` | `DISTRO=ubuntu` 또는 `archlinux` | proot 배포판 |
| `--user`, `-u` | `USERNAME=desktop` | proot 사용자 이름 |
| `--no-proot` | `SKIP_PROOT=true` | proot 구성 생략 |
| `--proot-only` | `PROOT_ONLY=true` | native 데스크탑을 다시 설치하지 않고 proot만 구성 |
| `--no-conky` | `SKIP_CONKY=true` | 배터리 절약을 위해 Conky 자동시작 끄기 |
| `--display` | `DISPLAY_SERVER=x11` 또는 `wayland` | `x11`: XFCE, `wayland`: 실험적 KDE Plasma |
| — | `PROOT_SHELL=bash` 또는 `zsh` | proot 대화형 셸. 새 설정의 기본값은 `bash`이며 `zsh` 선택 전에는 컨테이너 안에 해당 셸 설치 필요 |
| `--help`, `-h` | — | 도움말 |

CLI 옵션은 대응하는 환경변수보다 우선합니다. 배포판이나 사용자 이름이 빠지면
추가 입력을 물을 수 있으므로 플래그를 썼다고 항상 무인 실행이 되는 것은 아닙니다.
사용자 이름은 `[a-z_][a-z0-9_-]{0,31}` 형식이어야 합니다. `--no-proot`는
`--proot-only`, `--distro`, `--user`와 함께 쓸 수 없습니다.

설정은 `~/.config/termux-xfce/config`에 권한 600으로 저장합니다. `--proot-only`는
기존 디스플레이 설정을 유지하고 새로 구성한 배포판·사용자를 `prun`과 App Installer의
대상으로 저장합니다. `PROOT_SHELL`을 명시하면 기존 셸 설정보다 우선합니다.
`--no-proot`는 컨테이너 구성을 생략하고 저장된 `PROOT_DISTRO`와 `PROOT_USER`를
비워 native 전용으로 전환합니다. 기존 컨테이너 파일은 유지합니다. 다시 사용하려면
해당 배포판과 사용자를 지정해 재실행하세요. native 데스크탑을 갱신할 필요가 없다면
`--proot-only`를 함께 사용하세요.

Conky는 proot 안에서 실행되므로, 떠 있는 동안 컨테이너가 유지되고
`termux-xfce-hostinfo`도 1초마다 계속 깨어납니다. `--no-conky`는
`~/.config/autostart/conky.desktop`에 `Hidden=true`를 추가하며, 이미 설치한 기기에서
재실행해도 적용됩니다. 다시 켜려면 XFCE 설정 → 세션 및 시작 프로그램 → 응용 프로그램
자동 시작에서 체크하거나 해당 줄을 지우세요.

**Wayland는 실험적 기능입니다.** `--display wayland`는 Anland/KWin + KDE Plasma를
추가하며 XFCE도 X11용으로 유지합니다. ARM64 Adreno/KGSL 기기가 필요합니다.
기록된 Plasma 팝업·Xwayland 오류는 이 설치기의 실기기 검증에서 해결된 것으로
확인되지 않았습니다. 업스트림은 패치된 LayerShellQt 패키지를 요구하지만 현재 설치기는
이를 명시적으로 설치하지 않습니다. [Anland 안내](docs/wayland-anland.md)의
[고정 의존성](docs/wayland-anland.md#pinned-dependencies), APK 선택 방법,
[알려진 문제](docs/wayland-anland.md#known-blockers)를 확인하세요.

GPU 패키지, 한글 입력기 등 선택적 구성요소는 App Installer로 관리합니다.
다운로드된 APK는 Android 설치 화면에서 설치를 완료해야 합니다.

## 사용법

```bash
startXFCE             # 설치 시 선택한 백엔드 시작: XFCE 또는 Plasma
ubuntu                # Ubuntu proot 진입 (설치한 경우)
archlinux             # Arch Linux proot 진입 (설치한 경우)
prun libreoffice      # 설정된 proot 배포판에서 명령 실행
PRUN_RUNTIME=chroot-ng prun libreoffice  # ptrace 없이 실행 (App Installer `chroot_ng` 설치 후)
cp2menu               # proot .desktop 런처를 native 메뉴로 가져오기
app-installer         # 추가 앱 GUI
screenshot            # 현재 데스크탑 전체 스크린샷
screenshot region     # full, window도 사용 가능
kill_display_session  # 데스크탑과 디스플레이 서버 종료
```

선택한 백엔드용 `startXFCE-x11` 또는 `startXFCE-wayland` 런처도 생성합니다.
해당 설치에서 선택한 백엔드의 런처만 만듭니다. GUI 명령은 데스크탑 안의 터미널에서
실행해야 해당 세션의 `DISPLAY`/`WAYLAND_DISPLAY`를 상속합니다.
스크린샷은 X11에서 `xfce4-screenshooter`, Wayland에서 `spectacle`을 사용합니다.

## GPU 가속

GPU 가속은 App Installer에서 선택해 설치합니다. Termux:X11용 `gpu_native`를
설치하면 `startXFCE`가 Adreno GPU와 Turnip ICD를 확인한 뒤 Zink를 사용합니다.
조건을 충족하지 않거나 Zink 스왑체인 실패가 감지되면 소프트웨어 렌더링으로 실행합니다.
패키지 설치만으로 모든 Adreno 모델의 가속을 보장하지는 않습니다. GPU 환경변수는 세션
런처에서 관리하며 모든 셸에 강제로 적용하지 않습니다. X11의 GTK4 호환 설정인
`GSK_RENDERER=cairo`는 유지합니다.

proot 앱에는 `gpu_proot`를 따로 설치합니다. 배포판 Turnip은 데스크톱용 DRM(msm)만
지원하므로, Termux glibc 저장소의 KGSL Turnip 드라이버(버전·SHA-256 고정)를 컨테이너에
넣고 Zink에는 배포판 Mesa를 그대로 씁니다. `vulkaninfo`로 KGSL의 Turnip을 확인한 뒤에만
Zink를 활성화합니다. Termux의 Bionic ICD를 컨테이너에서 공유하지 않습니다.
Ubuntu 24.04·25.10·26.04에서는 [lfdevs](https://github.com/lfdevs/mesa-for-android-container)
Mesa 빌드(버전·SHA-256 고정)도 배포판 Mesa 파일을 건드리지 않고 `/opt/termux-xfce-mesa`에 넣습니다.
그리고 OpenGL을 Zink 대신 Freedreno KGSL 드라이버로 돌립니다. 화면 출력 OpenGL이 약 10배 빨라집니다.
화면 없는 EGL 확인에서 Freedreno 렌더러가 잡힐 때만 켜고, 아니면 OpenGL은 Zink로 남습니다. `gpu_proot`를 제거하면
기존 기본 설치기가 남긴 GPU 설정도 함께 해제됩니다. 변경 후 실행 중인 앱을 다시 시작하세요.

```bash
gpu-info          # GPU 모델 확인
glxinfo -B        # 데스크탑 안의 터미널에서 실제 렌더러 확인
hud glxgears      # 현재 그래픽 세션의 FPS 표시
```

Wayland는 별도의 Anland/KWin 런타임을 사용합니다. 자세한 내용은
[Wayland 안내](docs/wayland-anland.md)를 참고하세요.

## ptrace 없는 런타임과 Host Info Bridge

미코(meeco.kr)의 흡혈귀왕님이 공개한 "glibc rootfs 리눅스 런타임" 작업을 참고해 구현했습니다.
그 작업의 핵심은 ptrace 오버헤드 없는 실행([06-16](https://meeco.kr/mini/41529519)), Android Host Info Bridge와
앱 체크리스트([06-29](https://meeco.kr/ITplus/41603434)), Turnip/Zink GPU입니다. 원 작업은 공개되지 않아서 같은 구성을
공개된 구성요소로 이 저장소에 직접 구현했습니다.

| 구성 | 이 저장소의 구현 |
|---|---|
| ptrace 없는 실행 | `PRUN_RUNTIME=chroot-ng`(env 또는 config)이면 App Installer `chroot_ng`가 소스 빌드한 [chroot-ng](https://github.com/sylirre/fake-chroot-ng)(Apache-2.0)로 같은 proot-distro rootfs를 실행합니다. 패키지 설치 같은 root 작업은 proot-distro가 계속 맡습니다. |
| Android Host Info Bridge | `termux-xfce-hostinfo`가 Android이 막은 `/proc/stat`·`uptime`·`loadavg`를 코어별 cpuidle과 `sysinfo`로 만들고, getprop으로 기기 정보(DMI)와 SoC 이름을 채웁니다. 게스트의 htop·btop·glances·fastfetch·inxi와 Termux 네이티브 htop에 실제 값이 나옵니다. 인터페이스별 네트워크 바이트 수는 권한 없이 부를 수 있는 Android 시스템 서비스 `netstats`에서 받아, 네이티브와 chroot-ng의 btop 네트워크 칸에 나옵니다. 같은 값으로 `/proc/net/dev`도 만들어, 네이티브(훅)와 proot·chroot-ng 게스트의 htop 네트워크 미터·psutil이 읽습니다. |
| GPU | `gpu_proot`가 KGSL Turnip(Vulkan)과 Freedreno KGSL(OpenGL, Ubuntu)을 넣습니다([GPU 가속](#gpu-가속)). |
| 큰 CPU 코어 | GitHub판 Termux에는 Termux:X11 sharedUid 판을 설치합니다(일반판이 이미 있으면 제거 후 설치하도록 안내). X11 화면을 보는 동안에도 Samsung OneUI가 Termux 쪽 앱을 작은 코어로 묶지 않습니다([termux-x11#1022](https://github.com/termux/termux-x11/issues/1022)). 실측: XFCE 프로세스가 `/moderate`(코어 4개)에서 `/top-app`(8개 전부)로 바뀌고, 컨테이너 sysbench 8스레드가 4809→19576 events/s(약 4.1배) |

Galaxy Z Fold6(SM-F956N)에서 잰 값은 다음과 같습니다.

| 측정 | proot-distro | chroot-ng | 네이티브 |
|---|---|---|---|
| `prun true` | 0.6–0.9초 | 0.15초 | — |
| `find /usr` (Ubuntu) | 4–15초 | 0.6초 | — |
| vkmark (headless, xMeM 패치 Turnip) | 501 | 4252 | 4004 |

남은 한계도 있습니다.
- 이 기기의 Termux:X11에서는 xMeM 패치 Turnip의 X11 스왑체인 생성이 실패합니다(네이티브 Termux Turnip도 같음). 그래서 Vulkan 화면 출력은 Turnip 24.2.6을 쓰고, vkcube는 실행되지 않습니다.
- 배터리 통계는 Android에 원천이 없어 비어 있습니다. 네트워크 카운터는 Android 16의 `netstats` 형식에서만 확인했고(이 기기), proot 게스트는 네트워크 인터페이스를 볼 수 없어 btop 네트워크 칸이 비어 있습니다. `/proc/net/dev`에는 바이트·패킷 수만 있고 에러·드롭 열은 0입니다.
- iftop·nethogs는 raw 소켓으로 패킷을 잡으므로 root가 필요합니다.
- 경로 번역은 seccomp 트랩만 쓰고 LD_PRELOAD 속도 계층은 없습니다.
- 게스트에는 상주 D-Bus 세션이 없어 GSettings(dconf) 설정이 저장되지 않습니다. 파일 열기·저장 대화상자는 정상입니다.

## Termux API 연동

native 구성 시 `termux-api` 패키지를 설치합니다. Termux:API, Termux:Float,
Termux:Widget, Termux:Boot APK는 다운로드 후 Android 설치 화면을 엽니다. 각 화면에서
설치를 완료하세요. `--proot-only`는 이 단계를 생략합니다.

이 설치기가 받는 컴패니언 APK는 GitHub 빌드입니다. Termux와 컴패니언은 같은 출처의
서명을 사용해야 하므로 F-Droid Termux를 쓴다면 해당 컴패니언도 F-Droid에서 설치하세요.
[Termux 설치 안내](https://github.com/termux/termux-app#installation)를 참고하세요.
Anland의 standard/compatible 선택은 이 컴패니언 APK 선택과 별개입니다.

### 자동 활성화

- **X11 클립보드 동기화** — XFCE 시작 시 Android↔X11 양방향 동기화 데몬 실행
- **Wayland 클립보드** — Anland가 처리하며 X11 폴링 데몬은 실행하지 않음

### App Installer에서 추가 설치

| 도구 | 설명 |
|------|------|
| 패널 배터리 (`api_conky_battery`) | XFCE Generic Monitor용 잔량·온도 스크립트. 패널 항목은 직접 추가 |
| 밝기 조절 | XFCE 패널용 화면 밝기 조절 스크립트 |
| 볼륨 조절 | XFCE 패널용 볼륨 조절 스크립트 |
| 알림 도구 | 스크립트에서 Android 알림바 전송 |
| TTS 음성 | 텍스트를 음성으로 변환 (Android TTS) |
| 음성인식 | 음성을 텍스트로 변환 (Android STT) |
| 배경화면 동기화 | XFCE 배경화면을 Android에 적용 |

## 한글 로케일 (옵션)

XFCE 메뉴/설정/앱 UI를 한글로 표시합니다. Termux의 bionic libc가 `setlocale(LC_MESSAGES)`를 지원하지 않기 때문에 **LD_PRELOAD 기반 gettext 후킹**으로 우회합니다.

> 이 접근법은 **미코(미니기기 코리아) — 흡혈귀왕님**이 공유해 주신 방법을 바탕으로 구현되었습니다. 🙏

native 한글 입력기(`korean_input`: fcitx5, 또는 `nimf`)와 UI 한글화(`korean_locale`)는
서로 다른 App Installer 항목입니다. 새 기본 설치는 입력기를 선택하지 않습니다.
native 입력기 선택은 `~/.config/termux-xfce/input-method`에 저장하고
`$PREFIX/etc/profile.d/termux-xfce-input.sh`에서 읽습니다. 입력기를 설치하면 해당
입력기를 선택합니다. 다른 입력기를 설치하면 선택이 바뀌며 선택된 입력기를 제거하면
선택이 해제됩니다. 기존 선택은 재설치 시 이전합니다. XFCE를 재시작해 적용하세요.
Wayland에서는 이 X11 입력기 변수를 지우고 Anland가 전달하는 Android 키보드를 사용합니다.

Android 소프트 키보드(삼성 키보드 등)의 한글 자판으로 치면 조합 중인 글자가 백스페이스에
받침부터 지워지지 않고 통째로 지워집니다. Termux:X11은 조합을 흉내만 내고 키보드에 조합 중인
글자를 알려 주지 않아서 키보드가 일반 삭제를 보내기 때문이며, Termux:X11 설정으로는 바뀌지
않습니다. "Enforce char based input"은 조합 자체를 막으니 꺼 두세요(기본값). 받침부터 지우려면
nimf를 선택하고 Android 키보드를 영문 자판으로 둔 채 Shift+Space로 nimf를 한글 모드로 바꾸세요.
Termux:X11 추가 키 설정(extra keys config)에 `{macro: 'SHIFT SPACE', display: '한/영'}`을
넣으면 한 번에 전환할 수 있습니다. 키보드의 클립보드 버튼으로 붙여넣은
글이 깨지는 것은 Termux:X11이 그 글을 한 글자씩 키 입력으로 흉내 내기 때문이며
(termux/termux-x11#1124), nimf가 한글 모드이면 영문은 자모로 바뀝니다. X11 앱에서는 Ctrl+V로
붙여넣으세요. Android 클립보드는 동기화 데몬과 Termux:X11 "Clipboard sharing"이 X11 클립보드에
그대로 넣어 둡니다.

로케일 설치에는 `ko/LC_MESSAGES/*.mo`가 담긴 ZIP이 필요합니다. GUI에서 파일을
선택하거나 CLI에 `KOREAN_LOCALE_ZIP=/path/to/locale.zip`를 지정하세요.
자세한 방법은 [App Installer 안내](app-installer/README.ko.md#한글-입력과-ui-한글화)에 있습니다.

proot 한글 입력기(`korean_proot`)는 컨테이너 안에 별도의 로케일과 nimf/fcitx5를
설치하고 `/etc/profile.d/termux-xfce-locale.sh`에 설정을 기록합니다. `prun`으로 전달한
명령은 Bash 로그인 셸을 거쳐 컨테이너 프로필을 읽습니다. 명령 없이 대화형으로 진입할
때는 설정된 `PROOT_SHELL`을 사용합니다.

| 파일 | 역할 |
|------|------|
| `assets/force_gettext.c` | gettext 후킹 C 소스 (clang -shared 빌드) |
| `domain/locale_ko.sh` | .mo 카탈로그 배치 + `.so` 빌드 |
| `$PREFIX/lib/force_gettext.so` | 런타임 주입 shared object |

## App Installer

추가 앱·시스템 도구·Termux API 도구를 탭 기반 GUI로 설치/제거합니다:

```bash
app-installer          # 전체 (탭: 앱 | 시스템 | Termux API | Wine)
app-installer wine     # Wine 앱만
```

usix-termux 저장소 폴더에서 GUI 없이 실행할 수도 있습니다.

```bash
bash app-installer/app-install.sh list
bash app-installer/app-install.sh list Wine
bash app-installer/app-install.sh install vlc
bash app-installer/app-install.sh status vlc
bash app-installer/app-install.sh remove vlc
```

- **탭 기반 UI** — 앱 / 시스템 / Termux API / Wine 탭으로 분류
- **검색** — 이름/설명 타이핑으로 즉시 필터링 (yad notebook, zenity 폴백)
- **Termux native 우선** — GIMP, Inkscape, Thunderbird 등은 네이티브 설치
- **proot 자동 라우팅** — LibreOffice, VS Code, DBeaver 등은 proot 내부 설치
- **업그레이드** — 설치된 Claude Code, Codex CLI, Notion에는 *업그레이드*가 표시됩니다.
  Claude Code는 고정 버전으로 갱신하며 다운로드나 버전 스모크 검사에 실패하면 백업으로
  복원할 수 있습니다. 이 검사는 `/login`을 확인하지 않습니다. Codex는 자체 고정 버전으로
  갱신하지만 같은 롤백 절차는 없고, Notion은 Firefox 런처를 갱신합니다.

CLI에는 `upgrade`나 `rollback` 하위 명령이 없습니다. 앱 ID, 설치 위치, 제약은
[App Installer README](app-installer/README.ko.md)를 참고하세요.

소스: [yanghoeg/App-Installer](https://github.com/yanghoeg/App-Installer) (Git Submodule)

## 쉘 (zsh + Powerlevel10k)

설치 시 **zsh**가 기본 쉘로 설정되고 Powerlevel10k가 자동으로 구성됩니다.

```bash
p10k configure        # p10k 프롬프트 재설정

# 자동 설치되는 별칭
ll          # eza -alhgF
ls          # eza -lF --icons
cat         # bat
gpu-info    # Adreno GPU 모델 확인
zink        # Zink 강제 지정으로 앱 실행
hud         # FPS 오버레이로 앱 실행
zrunhud     # proot 앱을 Zink + FPS 오버레이로 실행
```

## 설치 구성

### Termux Native (`--proot-only` 제외)

| 분류 | 패키지 |
|------|--------|
| 기본 유틸 | wget, unzip, which, ncurses-utils, dbus, pulseaudio, yad, zenity, termux-api, termux-services |
| XFCE | xfce4, xfce4-goodies, firefox, flameshot, papirus-icon-theme, pavucontrol-qt, fontconfig-utils, libuv, libsimdutf |
| 디스플레이 서버 | x11: termux-x11-nightly, xdotool, xclip, wmctrl, mesa-demos<br>wayland: Anland 5.13.3, 패치 KWin/Xwayland/Mesa, pipewire, util-linux, xdotool, xclip, wmctrl |
| Plasma (wayland 전용) | plasma-workspace, plasma-desktop, kscreen, systemsettings, plasma-integration, plasma-pa, milou, spectacle |
| CLI | git, zsh, eza, bat, fzf, ripgrep, fd, sd, zoxide, lazygit, gitui, git-delta, difftastic, starship, atuin, zellij, htop, procs, dust, duf, ncdu, yazi, glow, tealdeer, xh, uv, onefetch, jq, fastfetch, netcat-openbsd |
| APK | Termux:X11(x11) 또는 Anland(wayland), Termux:API, Termux:Float, Termux:Widget, Termux:Boot |

### proot (선택)

| distro | 기반 | 진입 명령 |
|--------|------|-----------|
| ubuntu | Ubuntu (proot-distro) | `ubuntu` |
| archlinux | Arch Linux (proot-distro) | `archlinux` |

> `btop`, 선택적 X11/proot GPU 패키지, 한글 입력기, Wine은 App Installer 항목입니다.
> 기본 패키지 목록은 TUR·root-repo를 요구하지 않습니다. Wayland 그래픽 구성은 예외로,
> 고정된 Mesa/KWin/Xwayland 스택을 설치기가 직접 설치합니다.

패키지 목록은 [domain/packages.sh](domain/packages.sh)와
[X11](adapters/output/display_x11.sh) / [Wayland](adapters/output/display_wayland.sh)
어댑터에서 관리합니다. proot에는 배포판별 유틸리티와 Conky, Zenity, Onboard 등의
데스크탑 도구도 설치합니다.

## Wine — 두 가지 백엔드

Windows 앱 실행 백엔드를 두 가지 중에서 고를 수 있고, **둘을 동시에 설치**할 수도 있습니다.

| | Wine (Box64+Staging) | Wine (Hangover) |
|---|---|---|
| 방식 | Wine 전체를 Box64로 x86 에뮬레이션 | Wine은 네이티브 arm64, **앱 바이너리만** FEX/ARM64EC 에뮬 |
| 설치 위치 | proot 내부 또는 glibc-runner | Termux native (proot 불필요) |
| 출처 | Kron4ek/Wine-Builds tarball | Termux x11-repo `hangover` 패키지 |
| 기본 WINEPREFIX | proot 사용자의 `$HOME/.wine`, proot가 없으면 Termux의 `$HOME/.wine` | Termux의 `$HOME/.wine-hangover` |
| 래퍼 | `$PREFIX/bin/wine-box64` | `$PREFIX/bin/wine-hangover` |

PATH 상의 `wine`은 **활성 백엔드로 위임하는 디스패처**입니다. Notepad++ · 7-Zip ·
SumatraPDF · WinMerge 같은 Wine 앱은 설치 시점의 활성 백엔드 WINEPREFIX에 배치됩니다.

```bash
wine-backend              # 활성 백엔드 + 설치 상태 확인
wine-backend hangover     # Hangover로 전환
wine-backend box64        # Box64 + Wine-Staging으로 전환
wine notepad.exe          # 활성 백엔드로 실행
wine-hangover notepad.exe # 백엔드를 직접 지정해 실행
```

> 기본 prefix는 서로 분리되어 있으며 백엔드를 바꿔도 Windows 앱이 옮겨지지는 않습니다.
> 선택한 백엔드에 앱을 다시 설치하세요. 기존 백엔드의 공용 런처 때문에 설치 상태가 그대로
> 표시될 수 있습니다. 성능과 앱 호환성은 기기와 작업에 따라 다릅니다.
> [Wine 안내](app-installer/README.ko.md#wine--두-가지-백엔드)를 참고하세요.

## 부팅 시 자동 시작

`termux-services`(runit) + Termux:Boot APK로 기기 부팅 직후 서비스를 올릴 수 있습니다.

```bash
pkg install openssh # 아래 예제의 선행 패키지
sv-enable sshd      # 서비스 등록 (부팅 시 자동 기동)
sv-disable sshd     # 해제
sv status sshd      # 상태 확인
sv up sshd          # 지금 바로 시작
```

설치 시 `~/.termux/boot/start-services`가 자동 생성되며, 이 스크립트가
`termux-wake-lock` 후 runit을 기동합니다. 파일이 이미 있으면 덮어쓰지 않습니다.

> Android 제약상 Termux:Boot APK는 **설치 후 최소 한 번 앱을 열어야** 활성화됩니다.

## 테스트

usix-termux 저장소 폴더에서 실행합니다.

```bash
bash tests/run_tests.sh
bash tests/run_tests.sh install_matrix
bash tests/run_tests.sh display_wayland modern_install
```

스위트 이름과 테스트 수는 실행기를 기준으로 확인합니다. 호스트 검사는 포트, 어댑터,
도메인, 생성된 런처, 입력기/GPU 마이그레이션, 설치 분기, mock 기반 E2E를 다룹니다.
Wayland 런타임 검사는 mock 프로세스로 실제 supervisor를 실행하며 Python 3가 필요합니다.
`force_gettext`는 문자열 정규화 하네스를 AddressSanitizer와 UndefinedBehaviorSanitizer로
빌드하므로 해당 기능을 지원하는 Clang 또는 GCC가 필요합니다.

검증 범위와 호스트 테스트·실기기 설치 스크립트의 구분은
[설치 매트릭스 안내](tests/INSTALL_MATRIX.md)를 참고하세요. App Installer에는
[별도 테스트 스위트](app-installer/README.ko.md#테스트)와
[실기기 검증 체크리스트](app-installer/TEST_LOG.md)가 있습니다. 호스트 테스트 통과만으로
Android 기기의 실제 설치, 그래픽, 입력, 오디오, 인증 동작까지 확인한 것은 아닙니다.

## Android 시스템 최적화

### 팬텀 프로세스 수 제한 조정 (Android 12+)

Android 12 이상에서는 백그라운드 프로세스 제한으로 세션이 종료될 수 있습니다.
아래 명령은 팬텀 프로세스 수 한도를 늘리며 모든 프로세스 종료 정책을 끄지는 않습니다.
적용 여부는 Android 버전과 제조사에 따라 다릅니다.
[Termux의 Android 12 관련 안내](https://github.com/termux/termux-app#termux-application)를
확인하고 PC에서 ADB로 연결한 뒤 실행하세요.

```bash
adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"
```

### 배터리 최적화 해제

**안드로이드 설정 → 앱 → Termux**와 선택한 디스플레이 앱(Termux:X11 또는 Anland)의
배터리 설정을 **제한 없음**으로 지정하세요. 메뉴 이름은 기기에 따라 다릅니다.

### Wakelock

`startXFCE` 실행 시 `termux-wake-lock`이 자동 호출됩니다.

---

## 알려진 문제

### Termux:X11 — 앱 전환 후 보조키 고착

Alt-Tab 후 마우스 클릭이나 방향키가 동작하지 않으면 Alt를 다시 눌러 보조키를 해제하거나
Android 제스처로 앱을 전환하세요. 이 증상을 다룬
[#781](https://github.com/termux/termux-x11/issues/781)은
[보조키 해제 수정](https://github.com/termux/termux-x11/pull/1025)이 병합되면서 닫혔습니다.
미해결 업스트림 문제로 판단하기 전에 설치된 APK 버전을 확인하세요.

Samsung DeX에서는 Termux:X11 → Preferences → Keyboard → **Intercept system shortcuts**
설정도 확인하세요.

---

## 파일 구조

```
usix-termux/
├── install.sh                    ← 진입점 + DI 컨테이너
├── ports/                        ← 계약 정의 (인터페이스)
├── adapters/
│   ├── input/                    ← CLI 인자 / 대화형 입력
│   └── output/                   ← pkg 어댑터, UI, 스크립트 빌더
├── domain/
│   ├── packages.sh               ← 패키지 목록
│   ├── termux_env.sh             ← Termux 환경 (API APK, 클립보드 동기화 포함)
│   ├── xfce_env.sh               ← XFCE 설정
│   ├── proot_env.sh              ← proot (Ubuntu/Arch 공통)
│   └── locale_ko.sh              ← 한글 로케일 (LD_PRELOAD)
├── runtime/                      ← Anland 세션 supervisor
├── docs/                         ← Anland 구성과 제약
├── tests/                        ← 자동화 테스트와 설치 매트릭스 안내
└── app-installer/                ← 앱 설치 GUI (Git Submodule)
    ├── install.sh                ← yad notebook 탭 GUI
    ├── app-install.sh            ← list/install/remove/status CLI
    └── domain/installers/        ← 앱별 핸들러 (제거 전용 항목 포함)
```

## 브랜치 전략

| 브랜치 | 용도 |
|--------|------|
| `main` | 한 줄 설치 명령이 사용하는 기본 브랜치 |
| `dev` | `main` 반영 전 개발·검증 |

부모 저장소는 App Installer 서브모듈의 특정 커밋을 기록합니다. `.gitmodules`의 추적
브랜치는 `dev`지만 일반적인 `git submodule update --init --recursive`는 기록된 커밋을
checkout합니다.

## 기여

버그 리포트·PR은 GitHub Issues / Pull Requests를 통해 환영합니다.
