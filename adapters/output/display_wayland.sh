#!/data/data/com.termux/files/usr/bin/bash
# Wayland: Anland: Termux APK -> anland daemon -> startplasma-wayland (patched KWin).
# See docs/wayland-anland.md for pinned upstream sources and device limitations.
source "${BASH_SOURCE[0]%/*}/display_common.sh"
source "${BASH_SOURCE[0]%/*}/anland_install.sh"

_anland_has_kgsl() { [ -r /dev/kgsl-3d0 ]; }

display_preflight() {
    if [ "$(uname -m)" != aarch64 ] || ! _anland_has_kgsl; then
        ui_error "Anland native Wayland는 현재 ARM64 Snapdragon(Adreno/KGSL) 기기가 필요합니다. 이 기기에서는 --display x11을 사용하세요."
        return 1
    fi
    _anland_apk_variant >/dev/null
}

display_setup_runtime() { anland_install_runtime; }
display_setup_apk() { anland_install_apk; }

display_get_packages() {
    # Patched packages are installed by display_setup_runtime with SHA-256 pins.
    # XFCE 4.20 produced no usable desktop on KWin: its panel and settings daemon
    # reported wlr-foreign-toplevel / ext-workspace / wlr-output-management missing,
    # xfdesktop drew no wallpaper, and scaling needs the X11 XSETTINGS selection.
    # The Wayland session therefore runs Plasma on the same compositor.
    # kwin-anland Provides: kwin-x11, which satisfies plasma-workspace's KWin
    # dependency without pulling Termux's X11-only build.
    echo "pipewire util-linux xdotool xclip wmctrl \
          plasma-workspace plasma-desktop kscreen systemsettings \
          plasma-integration plasma-pa milou spectacle"
}

display_emit_kill_session() {
    display_common_emit_kill_session
}

display_emit_session_detect() {
    cat << 'FRAG'
_DISPLAY_SERVER=wayland
export SESSION_STATE_DIR
exec 9>"$SESSION_STATE_DIR/start.lock" || exit 1
if ! flock -n 9; then
    echo "ERROR: 디스플레이 세션이 시작되거나 종료되는 중입니다." >&2
    exit 1
fi
# startplasma-wayland chooses KWin's socket name; the session publishes it here.
_ANLAND_WAYLAND=""
[ -r "$SESSION_STATE_DIR/anland-ready" ] &&
    read -r _ANLAND_WAYLAND < "$SESSION_STATE_DIR/anland-ready"
if _target=$(_session_pidfile_target "$SESSION_STATE_DIR/session.pid"); then
    _pid="${_target#-}"
    case "${_pid:-}" in
        ''|*[!0-9]*) ;;
        *)
            # A live supervisor and socket are not enough: Android's low-memory
            # killer can take plasmashell and leave a compositor drawing nothing,
            # and then pressing startXFCE must rebuild the session rather than
            # report the black screen as already running.
            if kill -0 "$_pid" 2>/dev/null &&
               [ -r "/proc/$_pid/cmdline" ] &&
               tr '\0' ' ' < "/proc/$_pid/cmdline" | grep -q 'termux-xfce-anland-session' &&
               [ -n "$_ANLAND_WAYLAND" ] &&
               [ -S "$XDG_RUNTIME_DIR/$_ANLAND_WAYLAND" ] &&
               ps -eo args | grep -q '\(^\|[ /]\)plasmashell\( \|$\)'; then
                am start -n com.anland.termux/.MainActivity || exit 1
                echo "Anland Plasma 세션이 실행 중입니다. 재시작: kill_display_session 후 startXFCE"
                exit 0
            fi
            ;;
    esac
fi
FRAG
}

display_emit_server_start() {
    cat << 'FRAG'
for _cmd in anland anland-compatible startplasma-wayland plasmashell kwin_wayland Xwayland dbus-run-session pipewire wireplumber flock setsid; do
    command -v "$_cmd" >/dev/null 2>&1 || {
        echo "ERROR: $_cmd 없음. 설치기를 --display wayland로 다시 실행하세요." >&2
        exit 1
    }
done
if ! /system/bin/pm path com.anland.termux 2>/dev/null | grep -q '^package:'; then
    echo "ERROR: Anland Termux APK를 먼저 설치하세요. 설치기가 받은 APK는 Downloads에 있습니다." >&2
    exit 1
fi
if [ ! -r /dev/kgsl-3d0 ]; then
    echo "ERROR: Anland native에 필요한 Adreno/KGSL 장치를 찾지 못했습니다." >&2
    exit 1
fi
# anland unlinks its socket on startup; do not replace another Anland session.
_owned_anland_pid="" _owned_anland_name=""
if _owned_target=$(_session_pidfile_target "$SESSION_STATE_DIR/display.pid"); then
    _owned_anland_pid="${_owned_target#-}"
    read -r _recorded_pid _owned_anland_name _metadata < "$SESSION_STATE_DIR/display.pid" || true
fi
for _other_pid in $(pgrep -x anland 2>/dev/null || true); do
    if [ "$_owned_anland_name" != anland ] || [ "$_other_pid" != "$_owned_anland_pid" ]; then
        echo "ERROR: 다른 Anland 데몬이 실행 중입니다. 해당 세션을 종료한 뒤 다시 실행하세요." >&2
        exit 1
    fi
done
_kill_display_session
_ANLAND_START_OWNED=true
termux-wake-lock || exit 1
: > "$SESSION_STATE_DIR/wake-lock" || { termux-wake-unlock; exit 1; }
rm -f "$SESSION_STATE_DIR/anland-ready"
mkdir -p "${TMPDIR}/.X11-unix"
# KWin's Xwayland refuses a socket dir without the sticky bit and then leaves
# DISPLAY unset, so enforce 1777 even when a restrictive umask created it.
chmod 1777 "${TMPDIR}/.X11-unix" || exit 1
XDISPLAY="" # KWin assigns the inner Xwayland DISPLAY; never guess it here.
FRAG
}

display_emit_clipboard_sync() {
    echo '# Android clipboard is handled by the Anland compositor backend.'
}

display_emit_session_launch() {
    cat << 'FRAG'
_WL_LOG="$HOME/.xfce-wayland.log"
# The supervisor owns one startup deadline, daemon/audio setup included, and
# exits when it passes. Waiting a little longer here keeps a session found by
# its last check from being killed by this launcher.
# Bash printf reads the clock without spawning date for every polling iteration.
printf -v _ANLAND_DEADLINE '%(%s)T' -1
_ANLAND_DEADLINE=$((_ANLAND_DEADLINE + 90))
ANLAND_STARTUP_DEADLINE=$_ANLAND_DEADLINE \
    setsid nohup bash "$PREFIX/bin/termux-xfce-anland-session" >"$_WL_LOG" 2>&1 </dev/null 9>&- &
_ANLAND_PID=$!
_record_session_pid "$SESSION_STATE_DIR/session.pid" "$_ANLAND_PID" termux-xfce-anland-session group || {
    kill "$_ANLAND_PID" 2>/dev/null || true
    echo "ERROR: Anland 세션을 시작하지 못했습니다. 로그: $_WL_LOG" >&2
    exit 1
}
while :; do
    if ! kill -0 "$_ANLAND_PID" 2>/dev/null; then
        echo "ERROR: Anland 세션 시작 실패. 로그: $_WL_LOG" >&2
        tail -n 20 "$_WL_LOG" >&2
        exit 1
    fi
    if [ -f "$SESSION_STATE_DIR/anland-ready" ]; then
        read -r _ANLAND_WAYLAND < "$SESSION_STATE_DIR/anland-ready" || true
        if [ -n "${_ANLAND_WAYLAND:-}" ] &&
           [ -S "$XDG_RUNTIME_DIR/$_ANLAND_WAYLAND" ]; then
            echo "Anland Plasma 세션 시작. 키보드는 Anland 설정의 소프트키보드 호출키를 사용하세요."
            exit 0
        fi
    fi
    printf -v _ANLAND_NOW '%(%s)T' -1
    [ "$_ANLAND_NOW" -lt "$((_ANLAND_DEADLINE + 15))" ] || break
    sleep 0.5
done
echo "ERROR: Anland/Plasma 시작 대기 시간 초과. 로그: $_WL_LOG" >&2
exit 1
FRAG
}
