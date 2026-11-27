#!/data/data/com.termux/files/usr/bin/bash
# Shared session state used by the generated start and stop commands.

display_common_emit_kill_session() {
    cat <<'FRAG'
_record_session_pid() {
    local file="$1" pid="$2" expected="$3" scope="$4" stat_line
    local -a fields
    IFS= read -r stat_line 2>/dev/null < "/proc/$pid/stat" || return 1
    IFS=' ' read -ra fields <<< "${stat_line##*) }"
    [ -n "${fields[19]:-}" ] || return 1
    printf '%s\t%s\t%s\t%s\n' "$pid" "$expected" "$scope" "${fields[19]}" > "$file"
}

_session_pidfile_target() {
    local file="$1" pid expected scope start stat_line arg matched=false
    local -a fields argv
    [ -r "$file" ] && IFS=$' \t' read -r pid expected scope start < "$file" || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ "$pid" -gt 1 ] || return 1
    IFS= read -r stat_line 2>/dev/null < "/proc/$pid/stat" || return 1
    IFS=' ' read -ra fields <<< "${stat_line##*) }"
    [ "${fields[0]:-}" != Z ] || return 1
    if [ -n "$start" ]; then
        [ "$start" = "${fields[19]:-}" ] || return 1
        if [ "$scope" = group ] && [ "$pid" = "${fields[2]:-}" ] && [ "$pid" = "${fields[3]:-}" ]; then
            printf '%s\n' "-$pid"
            return 0
        fi
    else
        # Previous releases wrote a PID and a command name.
        [ -n "$expected" ] || return 1
        mapfile -d '' -t argv 2>/dev/null < "/proc/$pid/cmdline" || return 1
        for arg in "${argv[@]}"; do
            case "${arg##*/}" in "$expected"|"$expected "*) matched=true; break ;; esac
        done
        [ "$matched" = true ] || return 1
    fi
    printf '%s\n' "$pid"
}

_kill_pidfile() {
    local file="$1" target retry
    if target=$(_session_pidfile_target "$file"); then
        kill -TERM -- "$target" 2>/dev/null || true
        for retry in 1 2 3; do
            kill -0 -- "$target" 2>/dev/null || break
            sleep 1
        done
        if kill -0 -- "$target" 2>/dev/null &&
           { [[ "$target" == -* ]] || [ "$(_session_pidfile_target "$file")" = "$target" ]; }; then
            kill -KILL -- "$target" 2>/dev/null || true
        fi
    fi
    rm -f -- "$file"
}

_release_session_wake_lock() {
    if [ -f "$SESSION_STATE_DIR/wake-lock" ]; then
        termux-wake-unlock 2>/dev/null || true
        rm -f -- "$SESSION_STATE_DIR/wake-lock"
    fi
}

_kill_display_session() {
    local file display_num socket_id lock_id socket lock
    # The Anland worker has an EXIT handler that reaps its children.
    for file in clipboard anland-worker session compositor bridge wireplumber pipewire display; do
        _kill_pidfile "$SESSION_STATE_DIR/$file.pid"
    done

    if [ -r "$SESSION_STATE_DIR/display-num" ] &&
       read -r display_num socket_id lock_id < "$SESSION_STATE_DIR/display-num" &&
       [[ "$display_num" =~ ^[0-9]+$ ]]; then
        socket="$TMPDIR/.X11-unix/X$display_num"
        lock="$TMPDIR/.X$display_num-lock"
        if [ -n "$socket_id" ] && [ "$(stat -c '%d:%i' "$socket" 2>/dev/null)" = "$socket_id" ]; then
            rm -f -- "$socket"
        fi
        if [ -n "$lock_id" ] && [ "$(stat -c '%d:%i' "$lock" 2>/dev/null)" = "$lock_id" ]; then
            rm -f -- "$lock"
        fi
    fi
    rm -f -- "$SESSION_STATE_DIR/display-num" "$SESSION_STATE_DIR/anland-ready"
    _release_session_wake_lock
}
FRAG
}
