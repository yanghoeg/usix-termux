#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# ADAPTER: script_builder_zenity.sh
# -----------------------------------------------------------------------------
# Output Adapter — zenity 기반 런타임 스크립트 빌더
# script_builder.sh 포트의 zenity 구현체
# 생성되는 스크립트: startXFCE, kill_display_session, cp2menu
#
# display_emit_* 함수(display 포트)를 조립하여 런타임 스크립트 생성.
# 공유 로직(GPU/PulseAudio/로케일)은 이 파일에 인라인으로 유지.
# =============================================================================

script_build_start_xfce() {
    local output="$1"

    {
        # ── 1. Shebang + 환경 초기화 (공유) ──
        cat << 'HEADER'
#!/data/data/com.termux/files/usr/bin/bash
# shortcut 실행 시 TMPDIR 미상속 방지
TMPDIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"

# 바이너리를 Termux bionic으로 고정 — glibc-runner 셸(예: Claude Code)에서 실행 시
# PATH 앞의 $PREFIX/glibc/bin이 env/cp/mkdir/grep 등 coreutils를 가려, 세션 전역에
# preload되는 bionic force_gettext.so와 충돌(libdl.so 로드 실패 → 세션 미기동)하는
# 것을 방지한다. bionic $PREFIX/bin을 앞세워 coreutils가 bionic으로 해석되게 한다.
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
unset RUNNING_IN_GLIBC_RUNNER APP_PREFIX GLIBC_PREFIX
_native_path=""
IFS=: read -r -a _path_entries <<< "$PATH"
for _path_entry in "${_path_entries[@]}"; do
    case "$_path_entry" in "$PREFIX/glibc/bin"|"$PREFIX/glibc/bin/"|"") continue ;; esac
    _native_path="${_native_path:+$_native_path:}$_path_entry"
done
PATH="$PREFIX/bin:$PREFIX/bin/applets${_native_path:+:$_native_path}"
unset _native_path _path_entries _path_entry
export PATH PREFIX TMPDIR

# XDG runtime dir (dbus 요구: mode 700 user-private) — shortcut은 rc를 source하지 않음
XDG_RUNTIME_DIR="${PREFIX:-/data/data/com.termux/files/usr}/var/run/user/$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
export XDG_RUNTIME_DIR

SESSION_STATE_DIR="$HOME/.cache/termux-xfce/session"
mkdir -p "$SESSION_STATE_DIR"
chmod 700 "$SESSION_STATE_DIR" 2>/dev/null || true

_cleanup_failed_start() {
    local rc=$?
    trap - EXIT INT TERM
    if [ "$rc" -ne 0 ] && { [ "${_X11_START_OWNED:-false}" = true ] || [ "${_ANLAND_START_OWNED:-false}" = true ]; }; then
        _kill_display_session
        termux-wake-unlock 2>/dev/null || true
    fi
    # Both display backends pass fd 9 to their background workers. Release the
    # startup lock explicitly so a later invocation can recover a failed desktop
    # even while its server/supervisor is still alive.
    flock -u 9 2>/dev/null || true
    exit "$rc"
}
trap _cleanup_failed_start EXIT
trap 'exit 130' INT TERM

HEADER

        # ── 2. 세션 종료 함수 (display 어댑터) ──
        display_emit_kill_session

        # ── 3. 세션 중복 감지 (display 어댑터) ──
        display_emit_session_detect

        # ── 4. 디스플레이 서버 시작 (display 어댑터) ──
        # _kill_display_session + wake-lock + 서버 시작 + XDISPLAY 설정
        display_emit_server_start

        # ── 5. PulseAudio 시작 (공유) ──
        cat << 'PULSE'

_PA_PRELOAD=""
[ -f /system/lib64/libskcodec.so ] && _PA_PRELOAD="/system/lib64/libskcodec.so"

LD_PRELOAD="$_PA_PRELOAD" pulseaudio --start \
    --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" \
    --exit-idle-time=-1

LD_PRELOAD="$_PA_PRELOAD" pacmd load-module \
    module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 2>/dev/null || true

PULSE

        # ── 6. 한글 로케일 (공유) ──
        cat << 'LOCALE'
# 한글 로케일 — force_gettext.so가 설치되어 있으면 자동 적용
_PREFIX="/data/data/com.termux/files/usr"
if [ -f "$_PREFIX/lib/force_gettext.so" ]; then
    export LANG="ko_KR.UTF-8"
    export LANGUAGE="ko_KR:ko:en_US:en"
    export FORCE_TEXTDOMAINDIR="$_PREFIX/share/locale"
    export FALLBACK_DOMAINS="__KOREAN_FALLBACK_DOMAINS__"
    export XDG_DATA_DIRS="$_PREFIX/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
    QT_TRANSLATIONS_PATH="$_PREFIX/share/qt6/translations:$_PREFIX/share/qt/translations${QT_TRANSLATIONS_PATH:+:$QT_TRANSLATIONS_PATH}"
    export QT_TRANSLATIONS_PATH
    export KDE_LANG=ko QT_LOCALE_OVERRIDE=ko_KR
    case ":${LD_PRELOAD-}:" in *:"$_PREFIX/lib/force_gettext.so":*) ;; *)
      export LD_PRELOAD="$_PREFIX/lib/force_gettext.so${LD_PRELOAD:+:$LD_PRELOAD}";; esac
fi

LOCALE

        # ── 7. Selected input method ──
        cat << 'INPUT_METHOD'
if [ "${_DISPLAY_SERVER:-x11}" = x11 ]; then
    unset WAYLAND_DISPLAY
    export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce
fi
[ ! -r "$PREFIX/etc/profile.d/termux-xfce-input.sh" ] || . "$PREFIX/etc/profile.d/termux-xfce-input.sh"

INPUT_METHOD

        # ── 8. 클립보드 동기화 (display 어댑터) ──
        display_emit_clipboard_sync

        # ── 9. GPU 감지 (공유) — 환경변수 export 후 세션 시작은 display 어댑터가 상속 ──
        cat << 'GPU_ENV'

# GPU 자동 감지 → Zink(OpenGL→Vulkan)+Turnip 또는 llvmpipe 소프트웨어 폴백
if [ "${_DISPLAY_SERVER:-x11}" = x11 ]; then
GPU_MODEL=$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null || echo "")

export PULSE_SERVER=tcp:127.0.0.1:4713
export GSK_RENDERER=cairo

unset MESA_LOADER_DRIVER_OVERRIDE LIBGL_ALWAYS_SOFTWARE TU_DEBUG ZINK_DESCRIPTORS
unset MESA_NO_ERROR MESA_GL_VERSION_OVERRIDE MESA_GLES_VERSION_OVERRIDE MESA_VK_WSI_PRESENT_MODE
if [ -n "$GPU_MODEL" ] && [ -f "$PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json" ]; then
    # Adreno GPU 감지 → Zink + Turnip
    export MESA_LOADER_DRIVER_OVERRIDE=zink
    export TU_DEBUG=noconform
    export ZINK_DESCRIPTORS=lazy
    export MESA_VK_WSI_PRESENT_MODE=fifo

    # Zink present(WSI) 검증 — 일부 mesa/Turnip 버전은 Termux:X11 창에 Vulkan
    # 스왑체인을 만들지 못해(CreateSwapchainKHR 실패) 화면이 검게 나온다. glxinfo로
    # 실제 present 경로를 검사해 실패하면 소프트웨어(llvmpipe)로 폴백한다.
    # 판정은 grep 대신 bash 내장 case로 — 세션 전역 LD_PRELOAD/PATH 오염에도 견고.
    if command -v glxinfo >/dev/null 2>&1; then
        _zink_err=$(DISPLAY="$XDISPLAY" timeout 15 glxinfo -B 2>&1 >/dev/null)
        case "$_zink_err" in
            *"could not create swapchain"*|*"CreateSwapchainKHR failed"*)
                echo "WARN: Zink 스왑체인 생성 실패 감지 — 소프트웨어 렌더링으로 폴백합니다." >&2
                unset MESA_VK_WSI_PRESENT_MODE TU_DEBUG ZINK_DESCRIPTORS
                export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
                export LIBGL_ALWAYS_SOFTWARE=1
                ;;
        esac
        unset _zink_err
    fi
else
    # llvmpipe 소프트웨어 폴백 (KGSL 미감지)
    export LIBGL_ALWAYS_SOFTWARE=1
fi
fi # Anland configures its own KGSL environment in its session supervisor.
GPU_ENV

        # ── 10. 세션 시작 (display 어댑터) ──
        # X11: xfce4-session on $XDISPLAY / Wayland: Anland + KWin + Plasma
        display_emit_session_launch
    } > "$output"

    sed -i "s|__KOREAN_FALLBACK_DOMAINS__|${_KOREAN_FALLBACK_DOMAINS:-}|" "$output"
}

script_build_kill_display() {
    local output="$1"

    {
        cat << 'HEADER'
#!/data/data/com.termux/files/usr/bin/bash
TMPDIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"
SESSION_STATE_DIR="$HOME/.cache/termux-xfce/session"

HEADER

        display_emit_kill_session

        cat << 'BODY'

if pgrep -f '[a]pt|[a]pt-get|[d]pkg|[n]ala' > /dev/null; then
    zenity --info --text="패키지 설치 중입니다. 완료 후 시도하세요."
    exit 1
fi

# 디스플레이 세션 종료 전 존재 여부 확인
XFCE_PID=$(pgrep -x xfce4-session 2>/dev/null | head -1)
DISPLAY_PID=$(pgrep -f '(^|/)(termux-x11|labwc|kwin_wayland|anland)( |$)' 2>/dev/null | head -1)

if [ -z "$XFCE_PID" ] && [ -z "$DISPLAY_PID" ]; then
    zenity --info --text="실행 중인 세션을 찾을 수 없습니다."
    exit 0
fi

_kill_display_session
BODY
    } > "$output"
}

script_build_cp2menu() {
    local output="$1"
    local desktop_helper="${2:-${BASH_SOURCE[0]%/*}/../../app-installer/domain/desktop.sh}"
    desktop_helper="$(cd -- "${desktop_helper%/*}" && pwd)/${desktop_helper##*/}" || return 1

    {
    printf '#!/data/data/com.termux/files/usr/bin/bash\nDESKTOP_HELPER=%q\n' "$desktop_helper"
    cat << 'EOF'
_cp2menu_error() {
    echo "[ERROR] $1" >&2
    zenity --error --text="$1" || true
}
CONFIG="$HOME/.config/termux-xfce/config"
[ -f "$CONFIG" ] && source "$CONFIG"

DISTRO="${PROOT_DISTRO:-}"
if [ -z "$DISTRO" ]; then
    _cp2menu_error 'proot 환경이 설정되지 않았습니다.'
    exit 1
fi
[ -r "$DESKTOP_HELPER" ] || DESKTOP_HELPER="$PREFIX/libexec/termux-xfce/desktop.sh"
if ! source "$DESKTOP_HELPER"; then
    _cp2menu_error "데스크톱 관리 스크립트를 읽을 수 없습니다: $DESKTOP_HELPER"
    exit 1
fi
ROOTFS_BASE="${PROOT_ROOTFS_BASE:-$PREFIX/var/lib/proot-distro}"
if [ -d "$ROOTFS_BASE/containers/$DISTRO/rootfs" ]; then
    ROOTFS="$ROOTFS_BASE/containers/$DISTRO/rootfs"
else
    ROOTFS="$ROOTFS_BASE/installed-rootfs/$DISTRO"
fi
if [ ! -d "$ROOTFS" ]; then
    _cp2menu_error "proot rootfs를 찾을 수 없습니다: $ROOTFS"
    exit 1
fi

action=$(zenity --list --title="cp2menu" --text="작업 선택:" \
    --radiolist --column="" --column="Action" \
    TRUE "Copy .desktop file" FALSE "Remove .desktop file")

[ -z "$action" ] && exit 0

if [[ "$action" == "Copy .desktop file" ]]; then
    selected=$(zenity --file-selection --title=".desktop 파일 선택" \
        --file-filter="*.desktop" \
        --filename="$ROOTFS/usr/share/applications")
    [ -z "$selected" ] && exit 0

    filename="${selected##*/}"
    if ! desktop_import_proot "$selected" "$ROOTFS" "$PREFIX/share/applications/$filename"; then
        _cp2menu_error "복사 실패: $filename"
        exit 1
    fi
    zenity --info --text="복사 완료: $filename"

elif [[ "$action" == "Remove .desktop file" ]]; then
    selected=$(zenity --file-selection --title="제거할 .desktop 선택" \
        --file-filter="*.desktop" \
        --filename="$PREFIX/share/applications")
    [ -z "$selected" ] && exit 0

    if ! rm -- "$selected"; then
        _cp2menu_error "제거 실패: ${selected##*/}"
        exit 1
    fi
    zenity --info --text="제거 완료: $(basename "$selected")"
fi
EOF
    } > "$output"
}
