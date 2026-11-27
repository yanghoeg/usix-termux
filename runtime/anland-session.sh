#!/data/data/com.termux/files/usr/bin/bash
# Installed as termux-xfce-anland-session. Owns only the children started here.
set -euo pipefail
if [ "${1:-}" != --dbus ]; then
    # Pass the launcher's startup deadline as an argument so it stays out of
    # the session bus and Plasma environments.
    _deadline="${ANLAND_STARTUP_DEADLINE:-}"
    unset ANLAND_STARTUP_DEADLINE
    exec dbus-run-session -- bash "$0" --dbus "$_deadline"
fi
_startup_deadline="${2:-}"

: "${PREFIX:?}" "${TMPDIR:?}" "${XDG_RUNTIME_DIR:?}" "${SESSION_STATE_DIR:?}"
printf '%s\t%s\n' "$$" termux-xfce-anland-session > "$SESSION_STATE_DIR/anland-worker.pid"
_children=()
_owned_files=()
_daemon_started=false
# Everything under this supervisor, collected while the tree is still intact.
# plasma_session puts plasmashell, kded6, ksmserver, kwin_wayland and Xwayland
# two or more levels down, so terminating the tracked children alone orphans
# them — and a surviving compositor then blocks the next session from starting.
_collect_descendants() {
    local changed=1 pid ppid snapshot
    # One snapshot, walked repeatedly: reading ps inside the loop would fork a
    # subshell that is itself a descendant, so the set would never converge.
    snapshot=$(ps -eo pid= -o ppid= 2>/dev/null)
    local -a found=("$1")
    while [ "$changed" = 1 ]; do
        changed=0
        while read -r pid ppid; do
            [ -n "${pid:-}" ] || continue
            case " ${found[*]} " in *" $pid "*) continue ;; esac
            case " ${found[*]} " in
                *" $ppid "*) found+=("$pid"); changed=1 ;;
            esac
        done <<< "$snapshot"
    done
    printf '%s\n' "${found[@]:1}"
}

_cleanup() {
    local rc=$? pid i running file
    trap - EXIT INT TERM
    local _tree
    _tree=$(_collect_descendants "$$")
    for pid in "${_children[@]}"; do kill "$pid" 2>/dev/null || true; done
    for ((i=0; i<20; i++)); do
        running=false
        for pid in "${_children[@]}"; do kill -0 "$pid" 2>/dev/null && running=true; done
        [ "$running" = false ] && break
        sleep 0.1
    done
    for pid in "${_children[@]}"; do
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    for pid in $_tree; do kill -9 "$pid" 2>/dev/null || true; done
    for file in "${_owned_files[@]}"; do rm -f "$SESSION_STATE_DIR/$file"; done
    rm -f "$SESSION_STATE_DIR/anland-ready" "$SESSION_STATE_DIR/anland-worker.pid" \
          "$SESSION_STATE_DIR/plasma.env"
    if [ "$_daemon_started" = true ]; then
        rm -f "$ANLAND_SOCKET"
    fi
    if [ -f "$SESSION_STATE_DIR/wake-lock" ]; then
        termux-wake-unlock 2>/dev/null || true
        rm -f -- "$SESSION_STATE_DIR/wake-lock"
    fi
    exit "$rc"
}
trap _cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

_spawn() {
    local file="$1" expected="$2"; shift 2
    "$@" &
    _last_pid=$!
    _children+=("$_last_pid")
    _owned_files+=("$file")
    printf '%s\t%s\n' "$_last_pid" "$expected" > "$SESSION_STATE_DIR/$file"
}
_wait_socket() {
    local socket="$1" pid="$2" i
    for ((i=0; i<40; i++)); do
        kill -0 "$pid" 2>/dev/null || return 1
        [ -S "$socket" ] && return 0
        sleep 0.1
    done
    echo "ERROR: 소켓 생성 실패: $socket" >&2
    return 1
}

# Discard nested-X11 and Zink settings inherited from an older startXFCE or rc.
unset DISPLAY WAYLAND_DISPLAY WLR_BACKENDS GDK_BACKEND QT_QPA_PLATFORM
unset MESA_LOADER_DRIVER_OVERRIDE GALLIUM_DRIVER LIBGL_ALWAYS_SOFTWARE
unset MESA_VK_WSI_PRESENT_MODE MESA_GL_VERSION_OVERRIDE MESA_GLES_VERSION_OVERRIDE
unset TU_DEBUG ZINK_DESCRIPTORS GTK_IM_MODULE QT_IM_MODULE XMODIFIERS
export ANLAND=1 ANLAND_NO_DRM_DEVICE=1 EGL_PLATFORM=surfaceless
export ANLAND_SOCKET="$TMPDIR/anland/display_daemon.sock"
export MESA_LOADER_DRIVER_OVERRIDE=kgsl TURNIP_KMD=kgsl GALLIUM_DRIVER=freedreno
export FD_FORCE_KGSL=1 XWAYLAND_FORCE_KGSL_SURFACELESS=1
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE
export GDK_BACKEND=wayland,x11 QT_QPA_PLATFORM=wayland MOZ_ENABLE_WAYLAND=1
export GSK_RENDERER=cairo
# KWin resolves the cursor theme at startup, so name the
# theme the desktop installs instead of letting it fall back to a missing "default".
export XCURSOR_THEME=dist-dark XCURSOR_SIZE=32
export PULSE_SERVER=tcp:127.0.0.1:4713

_variant=compatible
if [ -r "$HOME/.config/termux-xfce/anland-variant" ]; then
    read -r _variant < "$HOME/.config/termux-xfce/anland-variant"
fi
case "$_variant" in standard|compatible) ;; *) echo 'ERROR: 잘못된 Anland APK 종류' >&2; exit 1 ;; esac
_spawn display.pid anland anland --socket "$ANLAND_SOCKET"
_daemon_pid=$_last_pid
_daemon_started=true
_wait_socket "$ANLAND_SOCKET" "$_daemon_pid"
if [ "$_variant" = compatible ]; then
    _spawn bridge.pid anland-compatible anland-compatible "$ANLAND_SOCKET"
fi
am start -n com.anland.termux/.MainActivity

# Anland's microphone/camera streams use PipeWire. Desktop audio retains the
# existing Termux PulseAudio endpoint, including the endpoint used by proot.
export PIPEWIRE_RUNTIME_DIR="$XDG_RUNTIME_DIR/termux-xfce-audio"
mkdir -p "$PIPEWIRE_RUNTIME_DIR"
chmod 700 "$PIPEWIRE_RUNTIME_DIR"
_spawn pipewire.pid pipewire pipewire
_wait_socket "$PIPEWIRE_RUNTIME_DIR/pipewire-0" "$_last_pid"
_spawn wireplumber.pid wireplumber wireplumber

# startplasma-wayland starts KWin (and its Xwayland) itself and picks the Wayland
# socket name, so the name is read back from the running shell rather than
# guessed, and published in the ready marker for the launcher.
_spawn compositor.pid startplasma-wayland startplasma-wayland
_compositor_pid=$_last_pid
# /proc/PID/stat holds comm in parentheses and it may contain spaces, so the
# fields are read after the last ')': state is 1 and ppid is 2.
_ppid_of() {
    [ -r "/proc/$1/stat" ] || return 1
    sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $2}'
}
# kill -0 succeeds on a zombie, so a child that exited but has not been reaped
# yet still looks alive. Read the state field instead: 'Z' means it is gone.
_child_running() {
    local st
    [ -r "/proc/$1/stat" ] || return 1
    st=$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $1}')
    [ -n "$st" ] && [ "$st" != Z ]
}
_is_descendant() {
    local pid="$1" want="$2" i
    for ((i=0; i<16; i++)); do
        [ "$pid" = "$want" ] && return 0
        case "$pid" in ''|0|1) return 1 ;; esac
        pid=$(_ppid_of "$pid") || return 1
    done
    return 1
}
_wait_plasma() {
    local pid wd now deadline
    printf -v now '%(%s)T' -1
    # The launcher supplies its deadline so it cannot kill a healthy supervisor
    # while Plasma is still allowed to initialize. Direct starts retain 90s here.
    deadline="${_startup_deadline:-$((now + 90))}"
    case "$deadline" in
        ''|*[!0-9]*) echo 'ERROR: 잘못된 Anland 시작 deadline' >&2; return 1 ;;
    esac
    # Process discovery can be slow on Android; inspect elapsed clock time rather
    # than assuming each iteration takes only the half-second sleep. Each scan
    # runs before the clock check, so a shell that came up during the last
    # sleep is still found.
    while :; do
        _child_running "$_compositor_pid" || return 1
        # The name is matched loosely across the whole command line because a
        # process started through an interpreter reports the interpreter as
        # argv[0]; correctness comes from the descendant check, which also keeps
        # a plasmashell belonging to another Anland session out of this result.
        for pid in $(ps -eo pid,args | awk '$0 ~ /(^|[ \/])plasmashell( |$)/ {print $1}'); do
            _is_descendant "$pid" "$_compositor_pid" || continue
            [ -r "/proc/$pid/environ" ] || continue
            wd=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^WAYLAND_DISPLAY=//p' | head -1)
            if [ -n "$wd" ] && [ -S "$XDG_RUNTIME_DIR/$wd" ]; then
                # Keep the environment plasma_session handed the shell so it can
                # be restarted later with the same session/bus/display.
                cat "/proc/$pid/environ" > "$SESSION_STATE_DIR/plasma.env" 2>/dev/null || true
                printf '%s\n' "$wd" > "$SESSION_STATE_DIR/anland-ready"
                return 0
            fi
        done
        printf -v now '%(%s)T' -1
        [ "$now" -lt "$deadline" ] || break
        sleep 0.5
    done
    echo "ERROR: plasmashell 기동 확인 실패" >&2
    return 1
}
_wait_plasma

# A shell restarted here hangs off this supervisor, not off the compositor, so
# both parentages count as "the desktop is up".
_respawn_pids=()
_plasma_alive() {
    local pid
    for pid in ${_respawn_pids[@]+"${_respawn_pids[@]}"}; do
        _child_running "$pid" && return 0
    done
    for pid in $(ps -eo pid,args | awk '$0 ~ /(^|[ \/])plasmashell( |$)/ {print $1}'); do
        _is_descendant "$pid" "$_compositor_pid" && return 0
    done
    return 1
}
# plasma_session does not restart the shell, and Android's low-memory killer
# reaches plasmashell (oom_score is high, RSS ~300MB) long before the compositor,
# leaving KWin compositing an empty screen. Bring it back with the environment it
# was given rather than leaving the user a black display.
_respawn_plasma() {
    [ -r "$SESSION_STATE_DIR/plasma.env" ] || return 1
    (
        local kv
        while IFS= read -r -d '' kv; do
            case "$kv" in
                [A-Za-z_]*=*) export "$kv" ;;
            esac
        done < "$SESSION_STATE_DIR/plasma.env"
        exec plasmashell
    ) >/dev/null 2>&1 &
    _children+=("$!")
    _respawn_pids+=("$!")
}

# The session ends when a child started here exits, carrying that child's status
# as before; the respawned shells appended to _children are cleanup-only and must
# not count as session failures. A shell that cannot stay up is not retried
# forever — that would hide a real startup failure behind an endless loop.
_core_children=("${_children[@]}")
_session_rc=0
_respawns=0
_RESPAWN_LIMIT=5
while :; do
    for _c in "${_core_children[@]}"; do
        if ! _child_running "$_c"; then
            wait "$_c" 2>/dev/null || _session_rc=$?
            break 2
        fi
    done
    if ! _plasma_alive; then
        if [ "$_respawns" -ge "$_RESPAWN_LIMIT" ]; then
            echo "ERROR: plasmashell이 ${_RESPAWN_LIMIT}회 재시작 후에도 유지되지 않습니다" >&2
            _session_rc=1
            break
        fi
        _respawns=$((_respawns + 1))
        echo "plasmashell이 사라져 다시 시작합니다 ($_respawns/$_RESPAWN_LIMIT, 메모리 부족으로 추정)" >&2
        _respawn_plasma || { _session_rc=1; break; }
    fi
    sleep 2
done
exit "$_session_rc"
