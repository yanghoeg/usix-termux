#!/data/data/com.termux/files/usr/bin/bash
# Check the generated launcher's startup lock without running desktop services.
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
source "$SCRIPT_DIR/framework.sh"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_DIR/adapters/output/script_builder_zenity.sh"

_test_startup_lock() {
    local backend="$1" sb worker
    sb=$(make_sandbox)
    _DISPLAY_LOCK_SB="$sb"
    trap 'if [ -r "$_DISPLAY_LOCK_SB/worker.pid" ]; then read -r _worker < "$_DISPLAY_LOCK_SB/worker.pid"; kill "$_worker" 2>/dev/null || true; fi; cleanup_sandbox "$_DISPLAY_LOCK_SB"' EXIT
    export HOME="$sb/home" PREFIX="$sb/usr" TMPDIR="$sb/tmp"
    export DISPLAY_LOCK_BACKEND="$backend" DISPLAY_LOCK_WORKER="$sb/worker.pid"
    mkdir -p "$HOME" "$PREFIX/bin" "$TMPDIR"

    # The worker holds the exact descriptor inherited by a real desktop. Only
    # the adapter's service calls are replaced; the generated EXIT trap is real.
    display_emit_kill_session() { echo '_kill_display_session() { :; }'; }
    display_emit_session_detect() { echo '_DISPLAY_SERVER=$DISPLAY_LOCK_BACKEND'; }
    display_emit_server_start() {
        cat <<'MOCK'
exec 9>"$SESSION_STATE_DIR/startup.lock"
flock -n 9 || exit 1
command sleep 60 >/dev/null 2>&1 &
printf '%s\n' "$!" > "$DISPLAY_LOCK_WORKER"
XDISPLAY=""
MOCK
    }
    display_emit_clipboard_sync() { :; }
    display_emit_session_launch() { :; }
    script_build_start_xfce "$sb/full-launcher"
    # Stop before audio/input/GPU setup so no installed device service is used.
    awk '/^_PA_PRELOAD=/{exit} {print}' "$sb/full-launcher" > "$sb/launcher"
    bash "$sb/launcher"
    read -r worker < "$DISPLAY_LOCK_WORKER"
    kill -0 "$worker"
    # Exiting startup must release the lock even though the worker stays alive,
    # allowing a later invocation to recover a desktop whose shell has failed.
    flock -n "$HOME/.cache/termux-xfce/session/startup.lock" true
}
_test_wayland_lock() { _test_startup_lock wayland; }
_test_x11_lock() { _test_startup_lock x11; }

describe 'Display startup lock lifetime'
it 'Wayland releases its startup lock while its session worker remains alive' _test_wayland_lock
it 'X11 continues to release its startup lock while its server remains alive' _test_x11_lock
print_results
