# CLAUDE.md — usix-termux 프로젝트 컨텍스트

## 프로젝트 개요

Android 기기(Termux)에서 XFCE 데스크탑 환경 + proot-distro(Ubuntu/Arch 선택)를 자동 설치하는 Bash 스크립트 모음.
**헥사고날 아키텍처(Ports & Adapters)** 적용.

저장소는 `yanghoeg/usix-termux`다(2026-10-10 `Termux_XFCE`에서 이름 변경, 옛 URL은 GitHub 리다이렉트).
이미 설치된 기기와 호환되도록 `termux-xfce-*` 명령·경로와 `TERMUX_XFCE_*` 변수 이름은 바꾸지 않는다.

## 실행 환경

- **타겟 환경**: Android 기기의 Termux (`/data/data/com.termux/...` 경로)
- **개발/편집 환경**: Linux PC (`/home/yanghoeg/code/work/linux/usix-termux/`) 및 기기 Termux 내 Claude Code
- 스크립트 shebang: `#!/data/data/com.termux/files/usr/bin/bash` (일반 Linux에서 직접 실행 불가)
- 테스트: PC 수정 → `git push` → 기기에서 `git pull` → `tests/` 단위 테스트 또는 `source domain/*.sh && <func>`

## 설치 방법 (최종 사용자)

```bash
curl -sL https://raw.githubusercontent.com/yanghoeg/usix-termux/main/install.sh | bash
# 또는
bash install.sh --distro archlinux --user lideok
# 또는 환경변수
DISTRO=ubuntu USERNAME=lideok bash install.sh
# 디스플레이 서버 선택 (기본: x11)
bash install.sh --distro ubuntu --user lideok --display wayland
```

## 아키텍처: 헥사고날 (Ports & Adapters)

```
install.sh          → DI(어댑터 선택) → Domain 실행
ports/              → 계약 정의 (pkg_manager, ui, display, script_builder)
adapters/input/     → CLI 인자 / 대화형 입력
adapters/output/    → pkg 매니저 / UI / 디스플레이 서버 / 스크립트 빌더 구현체
domain/             → 비즈니스 로직 (HOW 모름, WHAT만 앎)
tests/              → 단위/통합 테스트, mocks, autopilot
app-installer/      → Git Submodule (독립 repo)
```

### 핵심 원칙
- **Termux native 우선**: XFCE, Firefox, fcitx5, GPU mesa 모두 Termux 네이티브
- **proot는 선택**: Ubuntu 또는 Arch Linux, 또는 없음
- **도메인은 pkg_install/ui_info/display_get_packages만 호출** (어댑터 주입)
- **멱등성**: 모든 함수는 이미 설치된 경우 건너뜀

### 파일 구조

```
usix-termux/
├── install.sh                    ← 진입점 + DI 컨테이너
├── ports/
│   ├── pkg_manager.sh            ← 패키지 관리 계약
│   ├── ui.sh                     ← UI 계약
│   ├── display.sh                ← 디스플레이 서버 계약 (X11/Wayland)
│   └── script_builder.sh         ← 런타임 스크립트 생성 계약
├── adapters/
│   ├── input/{cli,interactive}.sh
│   └── output/{pkg_*,ui_*,display_x11,display_wayland,script_builder_zenity}.sh
├── domain/
│   ├── packages.sh               ← 패키지 정의 목록
│   ├── termux_env.sh             ← Termux 환경 (zsh+p10k 포함)
│   ├── xfce_env.sh               ← XFCE 환경
│   ├── proot_env.sh              ← proot 환경
│   └── locale_ko.sh              ← 한글 로케일 — LD_PRELOAD gettext 훅
├── tests/
│   ├── framework.sh, mocks.sh, run_tests.sh, autopilot.sh
│   ├── test_domain_{termux,xfce,proot,locale_ko}.sh
│   ├── test_{ports,adapters,adapters_deb,app_installer}.sh
│   ├── test_{e2e_install,input_interactive,install_matrix}.sh
│   ├── test_prun_{ld_preload,runtime}.sh, test_hostinfo.sh
│   ├── batch_test_appinstaller.sh
│   └── INSTALL_MATRIX.md
└── app-installer/                ← submodule
```

## App-Installer 연동

- 별도 Git repo 유지 + Git Submodule로 연결 (독립 업데이트 가능) — 변경은 서브모듈에서 커밋한 뒤
  부모에서 포인터 커밋
- 동일 헥사고날 구조(ports/adapters/domain/installers) 적용 완료. distro별 패키지명 차이는
  `adapters/output/pkg_{termux,ubuntu,arch}.sh` 어댑터가 흡수하고, `PROOT_DISTRO` env var로 선택
- 앱은 Termux native 우선 — 레지스트리(`domain/apps.sh`) 설명에 설치 위치(native/proot) 표기
- **다운로드 무결성**: 외부 파일(.deb/tarball/zip/exe)은 버전 핀 + sha256 상수, `lib/fetch.sh`의
  `fetch_verified` 경유. `releases/latest`·GitHub API "최신" 조회 금지 (예외: `llama_cpp.sh`
  사용자 선택 모델). 버전 올릴 때 `sha256sum`으로 상수 함께 갱신
- proot 내부 한글 IME(로케일 + nimf/fcitx5)는 app-installer `korean_proot` 항목
  (2026-09-05 부모 `domain/`에서 이관)
- 테스트: `app-installer/tests/test_{domain_apps,adapters,ports,fetch,proot_path}.sh` 개별 실행
  (run_tests.sh 없음). `test_nimf_*_real.sh`는 실기기 전용
- Claude Code 핀 상향/롤백 이력: `app-installer/docs/claude-code-login-regression.md`

## 남은 TODO (실기기 검증 — PC에서는 mock/정적 검사만 가능)

2026-10-01 리뷰 수정은 격리된 mock 환경으로 검증한다. 새 컨테이너의 GPU/IME 선택,
Wine 설치·제거 및 실제 GUI 임포트는 설치 환경을 변경하는 별도 검증 대상이다.
Wayland의 아래 알려진 차단 문제도 남아 있다.

### 완료 (2026-09-05~06 실기기 검증)

- 당시 `prun` GPU env 전파 확인. 현재 GPU 설정 소유자는 App Installer의
  `/etc/profile.d/gpu-accel.sh`이며 부모 기본 프로필에는 DISPLAY·XDG_RUNTIME_DIR만 둔다.
  배포판 Turnip(Ubuntu 25.10·Arch 26.2.x)은 msm 전용이라 KGSL에서 GPU를 못 찾는다 →
  `gpu_proot`는 Termux glibc-repo `mesa-vulkan-icd-freedreno-glibc`(24.2.6, sha256 고정)의
  드라이버만 rootfs `/usr/local/lib/termux-turnip/`에 넣는다(RUNPATH 없음·GLIBC_2.38까지 →
  배포판 라이브러리로 로드). 2026-10-10 Ubuntu에서 Zink+Turnip Adreno 750 확인. vkcube 1.4.304만
  `vkEnumeratePhysicalDevices` -3으로 실패(proot도 동일 — 런타임 무관)
- 2026-10-10 GPU 실측(SM-F956N): Ubuntu는 OpenGL을 lfdevs `mesa-for-android-container`
  26.3.0-devel 표준 빌드의 Freedreno KGSL(`kgsl`)로 돌린다 — 배포판 LLVM에 링크돼 Ubuntu 버전별로
  sha256을 고정하고, 배포판 파일을 덮지 않게 `/opt/termux-xfce-mesa` + LD_LIBRARY_PATH 등으로 앞세운다.
  화면 glmark2 kgsl 1251~1300 대 Zink 110. surfaceless `eglinfo`로 FD 렌더러를 확인한 뒤에만 켠다.
  headless vkmark(패치 Turnip): 네이티브 4004, chroot-ng 4252, proot 501. 단 xMeM 패치 Turnip
  (lfdevs 표준 26.3·Termux 네이티브 26.2.4)은 이 Termux:X11에서 X11 스왑체인 생성에서 죽고,
  `turnip-` 접두어(패치 없는) 빌드는 vkcube는 되지만 FIFO 31 FPS·headless SIGBUS → Vulkan은 24.2.6 유지
- zsh + Powerlevel10k 설정 순서 검증(`_setup_zsh_p10k` → `_setup_aliases`, 코드 수정 불필요)
- Termux native nimf `pgrep -x` 가드(`nimf.desktop` Exec)
- `korean_proot` 로케일: Arch `~/.bash_profile→~/.bashrc` 체인이 `~/.profile`을 무시하는 버그를
  근본 수정 — `/etc/profile.d/termux-xfce-locale.sh`(모든 로그인 셸 경유)에 `export`로 이전.
  실기기에서 `LANG=ko_KR.UTF-8`·IM env 자식 프로세스 전파 확인
- Claude Code 2.1.261 `/login` 2026-09-06 검증 완료 (세션 보존 스왑으로 업그레이드 후
  `/login` 정상. 회귀 시 롤백: `app_rollback_claude_code 2.1.132`)

### 완료 (2026-10-01 실기기 검증)

- Claude Code 핀 2.1.286 `/login` 검증 완료 — 사인인 URL → 브라우저 인증 → 터미널 복귀 →
  인증 후 실제 요청까지 정상. 환경·셸 프로필 어디에도 토큰이 없어 결과가 가려지지 않은
  조건. 회귀 시 롤백: `app_rollback_claude_code 2.1.261`
- codex 핀 0.159.3 검증 완료 (`d2fefe0` 커밋 메시지의 "실기기 검증 미실시"는 그 시점 기준,
  이후 완료) — `app_upgrade codex` 실행 시 sha256 2건(본체·code-mode 헬퍼) 검증 통과,
  래퍼 경유 `codex --version` = 0.159.3, `codex doctor` **20 ok / 0 fail**(DNS·TLS·websocket·
  reachability 포함), TUI 기동 시 `no complete local package` 치명 오류 해소 확인,
  Code Mode는 `$PREFIX/share/codex/codex-code-mode-host` 프로세스 spawn까지 실측.
  회귀 시 롤백은 본체·code-mode 헬퍼의 sha256이 둘 다 등록된 버전으로만 가능하다.
  0.153.4는 본체 sha256만 등록돼 있으므로 헬퍼 해시를 검증·등록하기 전에는
  `CODEX_PIN_VERSION`을 해당 버전으로 되돌려 재설치할 수 없다.
- codex의 `exec` 기본 sandbox는 Android에서 못 뜬다 — `sandbox failed: Permission denied
  (os error 13)`. 0.153.4 때부터 같은 bwrap/Android 비호환이며 이번 상향과 무관하다.
  명령을 실제로 돌리려면 `-c sandbox_mode=danger-full-access` 같은 해제가 필요하다.

## 주의사항

- `set -euo pipefail` 사용 중 — 오류 시 즉시 종료
- `local` 키워드는 bash 함수 내에서만 유효 (함수 밖에서 쓰면 에러)
- Termux 패키지: `--force-confold` 옵션으로 설정 파일 충돌 방지
- **패키지 배치 규칙**: `PKGS_TERMUX_*`(항상 설치)에는 **termux-main + x11-repo** 패키지가
  들어갈 수 있다 — XFCE/firefox/yad 자체가 x11-repo 제공이기 때문이다. `domain/termux_env.sh`의
  `_setup_termux_repos()`는 설치 초입에 **x11-repo만** 켠다 — tur-repo/root-repo는 여기서
  켜지 않는다.
  단 **tur-repo/root-repo 패키지는 반드시 App Installer 선택 항목**으로만 넣는다 — TUR/root는
  커뮤니티 빌드·소규모 저장소라 base에 넣으면 저장소 장애가 설치 전체를 깨뜨린다.
  선택 항목 설치기 안에서는 `termux_pkg_enable_repo <repo>`로 저장소를 먼저 켠다.
- **새 패키지 추가 시 오라클 대조 필수** (패키지명 추측 금지):
  `curl -s https://packages.termux.dev/apt/termux-main/dists/stable/main/binary-aarch64/Packages | grep '^Package: '`
  (x11 = `termux-x11/dists/x11/main/binary-aarch64/Packages`,
   root = `termux-root/dists/root/stable/binary-aarch64/Packages`,
   tur = `https://tur.kcubeterm.com/dists/tur-packages/tur/binary-aarch64/Packages`)
- `proot_exec`는 `PROOT_DISTRO`, `PROOT_USER` 환경변수 필요
- **prun 런타임**: 기본은 proot-distro. `PRUN_RUNTIME=chroot-ng`(env 또는 config, env 우선)이면
  App Installer `chroot_ng`가 설치한 `$PREFIX/bin/chroot-ng`(ptrace 없음)로 같은 rootfs를 실행한다.
  root 작업(apt/pacman, 사용자 생성)은 계속 proot-distro 몫이다.
  - chroot-ng는 다른 실행과 호스트 프로세스를 숨기므로 `--shared-proc`가 있어야 profile.d의
    `pgrep` IME 가드가 동작한다 (없으면 실행마다 `fcitx5 --replace`가 새로 뜬다)
  - `$PREFIX`를 같은 경로로 바인드해야 proot-distro link2symlink의 절대경로 `.l2s` 링크
    (terminfo·zoneinfo·locale-archive 등)가 풀린다. `-l`은 `.l2s` 저장소 이름 규칙이 proot와
    달라 켜지 않는다
- **Host Info Bridge** (`termux-xfce-hostinfo`, prun과 `htop` alias가 기동): Android이 막은 `/proc/stat`을 코어별
  cpuidle 체류 시간으로 만들어 proot-distro `sysdata/{stat,uptime,loadavg}`와 chroot-ng 바인드용 파일에
  1초마다 쓰고, getprop으로 DMI·cpuinfo `Hardware` 줄을 만든다. `Hardware`에는 네이티브 fastfetch가
  아는 SoC 이름(예: Qualcomm Snapdragon 8 Gen 3 [SM8650])을 넣는다 — 게스트의 Linux판 fastfetch는 SoC 코드를
  이름으로 바꾸지 않는다. fastfetch가 없으면 getprop의 SoC 제조사·모델로 돌아간다
  - cpuinfo의 processor 블록마다 `model name`도 넣는다 — ARM에는 없어 btop이 `/sys/devices` 목록(Android이 막음)을
    뒤지다 죽는다. chroot-ng는 netlink 에뮬레이션으로 인터페이스가 보이는데 `/sys/class/net` 통계가 막혀 btop이
    죽으므로 브리지 `net/` 디렉터리로 가린다(proot는 인터페이스가 안 보여 btop 네트워크 칸이 비어 있다)
  - 네트워크 카운터: `/proc/net/dev`·`/sys/class/net`·netlink `RTM_GETLINK`가 모두 막혀 있어, TrafficStats가 쓰는
    시스템 서비스 `netstats`의 `getIfaceStats`(트랜잭션 12, 권한 불필요)를 `hostinfo_net`(`assets/hostinfo_net.c`)이
    부른다. getifaddrs에 보이는 인터페이스마다 `net/<if>/statistics/{rx,tx}_bytes`(btop)와 `proc_net/dev`
    (`/proc/net/dev` 형식 — htop 네트워크 미터·psutil·ifconfig, 에러·드롭 열은 0)를 쓴다. Android 16 모듈은
    `StatsResult getIfaceStats(String)`이다(SM-F956N에서 jar의 트랜잭션 상수와 실제 호출로 확인). 응답 모양(널 아님·
    크기 36·long 4개)이 다르면 쓰지 않으므로, Android 13~15 모듈의 `long getIfaceStats(String, int)`는 0으로
    남는다(실기기 미검증)
    - `libbinder_ndk.so`는 절대경로(`/system/lib64`)로 dlopen한다 — 이름만 쓰면 RUNPATH의 libandroid-stub 가짜가 잡힌다
    - 데몬이 `hostinfo_net -w`를 띄워 두고(1초 갱신, 부모 데몬이 끝나면 같이 끝남), `start`는 데몬이 떠 있어도
      먼저 한 번 쓴다 — btop은 처음 읽은 값을 기준으로 삼아, 0으로 읽으면 다음 갱신에 부팅 이후 누적량을 속도로 본다
    - 네이티브는 훅이 막힌 `/proc/net/*`를 모든 모드에서 `proc_net/`으로 돌리고, 게스트는 `proc_net`을 `/proc/net`에
      디렉터리째 바인드한다 — `/proc/net`은 `self/net` 링크라 `/proc/net/dev` 파일 바인드는 proot·chroot-ng 모두
      적용되지 않는다. 원래 `/proc/net` 아래 69개 항목은 모두 읽을 수 없어 가려도 잃는 값은 없다
    - iftop·nethogs는 패킷 캡처(raw 소켓)라 root 없이는 불가능하다(iftop은 Termux 저장소에도 없다)
  - 반드시 같은 inode에 덮어쓴다 — rename으로 바꿔치기하면 fd를 열어 둔 채 되감아 읽는 top/vmstat이
    옛 값에 멈춘다
  - proot에 `/proc/stat`을 `--bind`하면 sysdata 바인드와 겹쳐 실행마다 경고가 나므로 sysdata로만 공급한다
  - Termux 네이티브에서도 `/proc/{stat,uptime,loadavg}`는 EACCES다. Termux htop은 `access()`로 먼저 확인해
    막혀 있으면 CPU를 읽지 않아 offline으로 표시한다. `htop` alias가 `termux-xfce-hostinfo exec`로
    `hostinfo_proc.so` LD_PRELOAD 훅을 붙여, EACCES인
    읽기 전용 열기·확인만 브리지 파일로 바꾼다. exec는 PID를 `holders/`에 남겨 게스트가 없어도 데몬을 유지한다.
    bionic 훅이 glibc 프로그램에 물리면 로드에 실패하므로 전역 LD_PRELOAD에는 넣지 않는다
  - Termux btop(root-repo)은 패치로 실효 UID가 0이 아니면 바로 끝낸다. `btop` alias로 `exec btop`이면
    `TERMUX_XFCE_HOSTINFO_BTOP=1`이 켜져 훅이 getuid·geteuid를 0으로 보고하고, 브리지 `cpuinfo`(model name)·
    `filesystems`를 열며, 막힌 `/sys/class/net` 아래 열기·stat을 브리지 `net/`의 같은 경로로 돌린다(없으면 ENOENT)
  - 훅·도우미 소스(`assets/hostinfo_{proc,net}.c`)는 `$PREFIX/libexec/termux-xfce/`에 둔다. 기본 설치는 clang을 받지 않으므로
    설치 때 clang이 있으면 바로 빌드하고, 없으면 clang이 생긴 뒤(한글 로케일·chroot_ng 등) 첫 `htop` 실행 때
    `termux-xfce-hostinfo exec`가 빌드한다. 소스 해시가 그대로면 다시 빌드하지 않는다
- **디스플레이 서버 추상화**: `ports/display.sh` 포트로 X11/Wayland 분리
  - X11 어댑터(`display_x11.sh`): Termux:X11 APK + `termux-x11` 프로세스
  - Wayland 어댑터(`display_wayland.sh`): Anland 5.13.3 + 패치 KWin + **KDE Plasma** (ARM64 Adreno)
    — XFCE 4.20은 KWin에서 쓸 만한 데스크탑이 되지 않는다(패널·설정 데몬이
    wlr-foreign-toplevel/ext-workspace/wlr-output-management 미지원 보고, 배율은
    X11 XSETTINGS 필요, xfdesktop 배경화면 미출력). `kwin-anland`의 `Provides: kwin-x11`이
    `plasma-workspace` 의존을 충족해 Termux `kwin-x11`은 끌려오지 않는다.
    세션은 `startplasma-wayland`가 고른 Wayland 소켓 이름을 `anland-ready`에 기록한다.
  - `display_preflight`는 변경 전 지원 기기 검사, `display_setup_runtime`은 버전·SHA-256 고정 패키지 설치
  - **wayland는 현재 실사용 불가** (2026-09-10 실기기): 패널 팝업마다 `plasmashell`이
    치명적 Wayland 프로토콜 오류(`layershellqt: Cannot attach popup of unknown type`)로
    종료되고, 고정 Mesa가 A7xx에서 Xwayland를 크래시(`fd6_texture.cc` 어서션)시킨다.
    Termux x11-repo는 Plasma 6.7.5만, upstream은 `kwin-anland` 6.7.4만 제공해 버전을
    맞출 수 없다. 상세: `docs/wayland-anland.md`의 "Known blockers"
  - Anland APK 일반판/호환판 선택과 실기기 미검증 항목: `docs/wayland-anland.md`
  - `--display x11|wayland` CLI 옵션 / `DISPLAY_SERVER` 환경변수 / 미지정 시 대화형 선택
  - **설치 시 하나 고정**: 선택된 서버의 런처(`startXFCE`)만 생성 (기본: x11)
  - Wayland는 `$TMPDIR/.X11-unix`가 1777이어야 한다 — sticky bit가 없으면 KWin의 Xwayland가
    소켓 생성을 거부하고 `DISPLAY`가 비어 세션이 즉시 죽는다
  - X11: `termux-x11 :N` → 소켓 자동 감지 (`${TMPDIR}/.X11-unix/X*`)
- **Termux:X11 소프트 키보드 한글 경로**: 삼성 키보드 등 Android IME의 한글은 Termux:X11이
  `setComposingText`/`commitText`로 받아 음절마다 BackSpace + 유니코드 키 주입(동적 keycode)으로
  조합을 흉내 낸다(`LorieView.replaceText` → `sendTextEvent`). nimf/fcitx5는 이 경로에 관여하지 않는다.
  InputConnection이 커서 앞 글자를 늘 공백으로 답하고 조합 구간을 보고하지 않아, 조합 중 백스페이스에
  삼성 키보드가 줄인 음절(율→유)을 보내지 않고 그냥 지운다 → 음절이 통째로 지워진다(2026-10-23 logcat
  확인, upstream master도 같음). `enforceCharBasedInput`(기본 false)은 이와 무관하다 — 켜면 TYPE_NULL이라
  조합 자체가 막힌다. 자모 단위 삭제는 Android 키보드 영문 자판 + nimf libhangul(X 안에서 조합)로만 된다.
  한/영은 nimf 기본 `org.nimf hotkeys`의 `<Shift> space`, Termux:X11 추가 키는
  `{macro: 'SHIFT SPACE', display: '한/영'}`(macro는 실제 Shift_L+space 키 이벤트를 보낸다). 설치기는
  이 키를 넣지 않는다 — 2026-10-23 넣었다가 사용자가 삼성 한글 자판을 계속 쓰기로 해 되돌렸다. nimf 한/영
  상태는 창(입력 컨텍스트)마다 따로다(`use-singleton`이어도 새 창은 영문으로 시작, 2026-10-23 확인).
  `termux-x11-preference key:value`는 값을 콜론마다 잘라 콜론이 든 값(`extra_keys_config`)이 깨진다 →
  stdin에 `"key"="value"` 줄로 넘긴다. stdin이 tty가 아니면 EOF까지 읽으므로 `list`도 `< /dev/null`로 실행.
  키보드 클립보드 버튼 붙여넣기도 같은 키 주입이라 글자가 바뀔 수 있다
  (termux/termux-x11#1124, 2026-10 미해결) → X11 앱에서는 Ctrl+V. Termux:X11이 Termux와 UID를 공유하므로
  `logcat -d | grep LorieNative`로 "Parsing text"/"Trying to input keysym"을 볼 수 있다
- **기본 쉘은 zsh + Powerlevel10k**: `domain/termux_env.sh` `_setup_zsh_p10k()`가 설치 시 자동 구성
  - RC 파일 수정은 bash/zsh 양쪽 모두 반영해야 함 (`_rc_targets()` + `_append_to_rc()` 참조)
- **Wine 백엔드는 2종 공존**: `app-installer/lib/wine_backend.sh`가 선택 로직을 소유
  - `$PREFIX/bin/wine` = 디스패처, `wine-box64` / `wine-hangover` = 실제 래퍼
  - 활성 백엔드는 `$HOME/.config/termux-xfce/wine-backend` (config 파일은 install.sh가
    덮어쓰므로 별도 파일), 사용자 전환은 `wine-backend` CLI
  - WINEPREFIX가 백엔드별로 분리됨 — Wine 앱은 `wine_exec_shell`로 실행하고
    스니펫 안에서 `$WINEPREFIX`를 쓸 것 (`$HOME/.wine` 하드코딩 금지)
- **부팅 자동 기동**: `termux-services`(runit) + Termux:Boot APK,
  `~/.termux/boot/start-services`는 `_setup_termux_boot_script()`가 생성 (기존 파일 보존)
