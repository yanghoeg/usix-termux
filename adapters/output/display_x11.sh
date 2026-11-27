#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# ADAPTER: display_x11.sh
# -----------------------------------------------------------------------------
# Output Adapter — Termux:X11 디스플레이 서버 구현체
# ports/display.sh 계약의 X11 구현
# =============================================================================

source "${BASH_SOURCE[0]%/*}/display_common.sh"

display_preflight() { :; }
display_setup_runtime() { :; }

display_emit_kill_session() {
    display_common_emit_kill_session
}

display_emit_session_detect() {
    cat << 'FRAG'
# ─── 동시 실행 방지: 위젯을 연달아 누르면 둘 다 "세션 없음"으로 보고 세션을 두 개 띄운다 ───
# 먼저 시작한 쪽이 끝날 때까지 나중 실행은 아무것도 건드리지 않고 빠진다(원래 세션 유지).
exec 9>"$SESSION_STATE_DIR/start.lock" || exit 1
if ! flock -n 9; then
    echo "XFCE 세션을 시작하는 중입니다. 이번 실행은 건너뜁니다." >&2
    exit 0
fi
# Offer session actions only for the X11 server and XFCE session we started.
if [ -r "$SESSION_STATE_DIR/display-num" ] &&
   read -r _NUM _socket_stamp _lock_stamp < "$SESSION_STATE_DIR/display-num" &&
   [[ "$_NUM" =~ ^[0-9]+$ ]] &&
   _EXISTING_XFCE=$(_session_pidfile_target "$SESSION_STATE_DIR/session.pid") &&
   _EXISTING_TX11=$(_session_pidfile_target "$SESSION_STATE_DIR/display.pid"); then
    export DISPLAY=":${_NUM}"
    am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity 2>/dev/null || exit 1
    sleep 1

    choice=$(zenity --list \
        --title="XFCE 세션 중복 감지" \
        --text="X11 세션이 실행 중입니다 (XFCE PID: ${_EXISTING_XFCE#-}, X11 PID: ${_EXISTING_TX11#-})." \
        --column="동작" --height=320 \
        "기존 세션으로 이동" \
        "세션 종료 후 재시작" \
        "세션 전체 종료" \
        2>/dev/null || true)
    case "$choice" in
        "세션 종료 후 재시작") ;;
        "세션 전체 종료") _kill_display_session; exit 0 ;;
        *) exit 0 ;;
    esac
fi
# ─────────────────────────────────────────────────────────────────
FRAG
}

display_emit_server_start() {
    cat << 'FRAG'
# Only clean up a failed start after this invocation has taken ownership.
# A signal while the existing-session dialog is open must leave that session up.
for _cmd in termux-x11 xdotool wmctrl timeout setsid dbus-run-session; do
    command -v "$_cmd" >/dev/null 2>&1 || {
        echo "ERROR: $_cmd 없음. X11 설치를 확인하세요." >&2
        exit 1
    }
done
_X11_START_OWNED=true
_kill_display_session

termux-wake-lock || { echo "ERROR: wake lock을 획득할 수 없습니다." >&2; exit 1; }
: > "$SESSION_STATE_DIR/wake-lock" || { termux-wake-unlock; exit 1; }

# X 서버 실행 — 사용 가능한 디스플레이 번호 자동 탐색 (:0~:3)
# 띄운 번호를 그대로 확정한다(ls|head 재스캔 금지 — 남의/죽은 소켓 선택 방지)
TX11_PID=""
DISPLAY_NUM=""
_x11_display_ready() {
    DISPLAY="$1" timeout 2 xdotool getdisplaygeometry >/dev/null 2>&1
}
for _DTRY in 0 1 2 3; do
    _socket="${TMPDIR}/.X11-unix/X${_DTRY}"
    _lock="${TMPDIR}/.X${_DTRY}-lock"
    # An occupied path can belong to another X server even if it rejects our
    # X clients. Only the session cleanup may unlink a recorded socket.
    [ ! -e "$_socket" ] && [ ! -L "$_socket" ] &&
        [ ! -e "$_lock" ] && [ ! -L "$_lock" ] || continue
    setsid termux-x11 ":${_DTRY}" 2>/dev/null 9>&- &
    TX11_PID=$!
    if ! _record_session_pid "$SESSION_STATE_DIR/display.pid" "$TX11_PID" termux-x11 group; then
        kill "$TX11_PID" 2>/dev/null || true
        continue
    fi
    _display_ready=false
    for _w in 1 2 3 4 5; do
        kill -0 "$TX11_PID" 2>/dev/null || break
        if [ -S "$_socket" ] && _x11_display_ready ":${_DTRY}" && kill -0 "$TX11_PID" 2>/dev/null; then
            _display_ready=true
            break
        fi
        sleep 1
    done
    if [ "$_display_ready" = true ]; then
        DISPLAY_NUM=$_DTRY
        _socket_stamp=$(stat -c '%d:%i' "$_socket" 2>/dev/null) || exit 1
        _lock_stamp=$(stat -c '%d:%i' "$_lock" 2>/dev/null) || _lock_stamp=''
        printf '%s\t%s\t%s\n' "$_DTRY" "$_socket_stamp" "$_lock_stamp" \
            > "$SESSION_STATE_DIR/display-num" || exit 1
        break
    fi
    _kill_pidfile "$SESSION_STATE_DIR/display.pid"
    TX11_PID=""
done

if [ -z "$DISPLAY_NUM" ]; then
    echo "ERROR: Termux:X11에 사용할 디스플레이(:0~:3)를 시작하지 못했습니다." >&2
    exit 1
fi

# Termux:X11 APK 열기
am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity || exit 1
XDISPLAY=":${DISPLAY_NUM}"
echo "Detected DISPLAY=${XDISPLAY}"
FRAG
}

display_emit_session_launch() {
    cat << 'FRAG'

# XFCE 세션 시작 (GPU 환경변수는 상위 블록에서 export됨)
# xfwm4 컴포지터가 검은 화면 유발 시:
#   설정 → 창관리자(작업) → 컴포지터 → '화면 컴포지팅 활성화' 해제
_XFCE_LOG="$SESSION_STATE_DIR/xfce.log"
DISPLAY="$XDISPLAY" setsid dbus-run-session -- xfce4-session >"$_XFCE_LOG" 2>&1 9>&- &
_XFCE_PID=$!
if ! _record_session_pid "$SESSION_STATE_DIR/session.pid" "$_XFCE_PID" dbus-run-session group; then
    kill "$_XFCE_PID" 2>/dev/null || true
    echo "ERROR: XFCE 세션을 시작하지 못했습니다. 로그: $_XFCE_LOG" >&2
    exit 1
fi
_XFCE_DEADLINE=$((SECONDS + 30))
while _session_pidfile_target "$SESSION_STATE_DIR/session.pid" >/dev/null &&
      [ "$SECONDS" -lt "$_XFCE_DEADLINE" ]; do
    if DISPLAY="$XDISPLAY" timeout 2 wmctrl -m >/dev/null 2>&1 &&
       _session_pidfile_target "$SESSION_STATE_DIR/session.pid" >/dev/null; then
        exit 0
    fi
    sleep 0.5
done
echo "ERROR: XFCE 세션을 시작하지 못했습니다. 로그: $_XFCE_LOG" >&2
exit 1
FRAG
}

display_emit_clipboard_sync() {
    cat << 'FRAG'
# Android ↔ X11 클립보드 동기화
if command -v termux-clipboard-get >/dev/null 2>&1 && command -v xclip >/dev/null 2>&1; then
    _kill_pidfile "$SESSION_STATE_DIR/clipboard.pid"
    DISPLAY="$XDISPLAY" setsid termux-clipboard-sync 9>&- &
    _record_session_pid "$SESSION_STATE_DIR/clipboard.pid" "$!" termux-clipboard-sync group || true
fi
FRAG
}

display_get_packages() {
    # mesa-demos: glxinfo 제공 — 런처가 Zink present 가능 여부를 검사해
    # 실패 시 소프트웨어 렌더링으로 폴백하는 데 사용 (x11-repo, termux-x11과 동일 저장소)
    echo "termux-x11-nightly xdotool xclip wmctrl mesa-demos util-linux"
}

# 다른 UID인 일반판의 데이터 폴더는 stat부터 거부된다. 없으면 ENOENT, sharedUid 판이면 열린다
_termux_x11_regular_installed() {
    local err
    err=$(LC_ALL=C stat /data/data/com.termux.x11 2>&1 >/dev/null) && return 1
    [[ "$err" == *"Permission denied"* ]]
}

display_setup_apk() {
    # nightly는 ABI별 APK 대신 universal APK만 낸다.
    # GitHub판 Termux와 서명이 같은 sharedUid 판은 Termux:X11 화면을 Termux 프로세스에서 띄워,
    # 그 화면을 보는 동안에도 Termux 쪽 앱이 큰 CPU 코어를 쓴다(Samsung OneUI 8.x — termux/termux-x11#1022).
    # F-Droid·Play판 Termux는 서명이 달라 일반판만 설치된다. 일반판 위에 덮어 설치할 수도 없다.
    local apk_name="termux-x11-universal-debug.apk"
    if [ "${TERMUX_APP__APK_RELEASE:-${TERMUX_APK_RELEASE:-}}" = GITHUB ]; then
        if _termux_x11_regular_installed; then
            ui_warn "Termux:X11 일반판을 업데이트합니다. Termux:X11을 제거하고 termux-x11-universal-sharedUid-debug.apk를 설치하면 X11 화면을 보는 동안에도 큰 CPU 코어를 씁니다."
        else
            apk_name="termux-x11-universal-sharedUid-debug.apk"
        fi
    fi

    termux_download_and_open_apk \
        "https://github.com/termux/termux-x11/releases/download/nightly/${apk_name}" \
        "$apk_name" refresh
}
