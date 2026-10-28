"""Run generated X11 startup code with isolated Android/X server substitutes."""
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile


root = Path(sys.argv[1])
case = sys.argv[2]
with tempfile.TemporaryDirectory(prefix="x11-fix.", dir=os.environ.get("TMPDIR")) as tmp:
    base = Path(tmp)
    home, prefix, temp = base / "home", base / "usr", base / "tmp"
    for directory in (home, prefix / "bin", temp / ".X11-unix"):
        directory.mkdir(parents=True, exist_ok=True)
    trace = base / "trace"
    env = dict(os.environ, HOME=str(home), PREFIX=str(prefix), TMPDIR=str(temp),
               TEST_TRACE=str(trace), TEST_CASE=case, TEST_PYTHON=sys.executable,
               TEST_SERVER_STUB=str(base / "server.py"))
    (base / "server.py").write_text('''import os, pathlib, socket, sys, time
n = sys.argv[1].lstrip(':')
with open(os.environ['TEST_TRACE'], 'a') as f: f.write('attempt:'+n+'\\n')
mode = os.environ['TEST_CASE']
if mode == 'stale' or n != '0': sys.exit(1)
s = socket.socket(socket.AF_UNIX)
s.bind(os.environ['TMPDIR']+'/.X11-unix/X'+n)
if mode in ('ready', 'dead'):
    pathlib.Path(os.environ['TMPDIR']+'/ready'+n).touch()
if mode == 'dead': sys.exit(0)
while True: time.sleep(.1)
''')
    build = r'''
source "$1/adapters/output/display_x11.sh"
source "$1/adapters/output/script_builder_zenity.sh"
display_emit_kill_session() {
    cat <<'MOCK'
_kill_display_session() { echo cleanup >> "$TEST_TRACE"; }
MOCK
}
script_build_start_xfce "$2"
'''
    subprocess.run(["bash", "-c", build, "_", str(root), str(base / "generated")],
                   env=env, check=True, capture_output=True, text=True)
    generated = (base / "generated").read_text().split("_PA_PRELOAD=", 1)[0]
    stubs = r'''
pgrep() {
    case "$TEST_CASE" in
        cancel|INT|TERM)
            if [ "$*" = '-x xfce4-session' ]; then
                echo 111
                return 0
            elif [ "$1" = -f ] && printf '%s\n' 'termux-x11 com.termux.x11 :0' | command grep -Eq "$2"; then
                echo 222
                return 0
            fi ;;
    esac
    return 1
}
am() { :; }
termux-wake-lock() { :; }
termux-wake-unlock() { echo unlock >> "$TEST_TRACE"; }
sleep() { command sleep .5; }
timeout() { shift; "$@"; }
xdotool() {
    # Give a server that immediately exits time to be reaped before the final
    # PID check, rather than making this a scheduling race.
    command sleep .1
    [ -e "$TMPDIR/ready${DISPLAY#:}" ]
}
termux-x11() { exec "$TEST_PYTHON" "$TEST_SERVER_STUB" "$@"; }
zenity() {
    echo dialog >> "$TEST_TRACE"
    case "$TEST_CASE" in INT|TERM) builtin kill -s "$TEST_CASE" "$$" ;; esac
    return 0
}
'''
    (base / "launcher").write_text(stubs + generated)
    if case == "stale":
        for n in (0, 1):
            stale = socket.socket(socket.AF_UNIX)
            stale.bind(str(temp / ".X11-unix" / f"X{n}"))
            stale.close()
    proc = None
    try:
        with (base / "output").open("w") as output:
            proc = subprocess.Popen(["bash", str(base / "launcher")], env=env,
                                    stdout=output, stderr=output, start_new_session=True)
            rc = proc.wait(timeout=30)
        calls = trace.read_text().splitlines() if trace.exists() else []
        output = (base / "output").read_text()
        state = home / ".cache/termux-xfce/session"
        if case in ("cancel", "INT", "TERM"):
            assert rc == (0 if case == "cancel" else 130), (rc, output, calls)
            assert "dialog" in calls, calls
            assert "cleanup" not in calls and "unlock" not in calls, calls
            assert not any(c.startswith("attempt:") for c in calls), calls
        elif case == "ready":
            assert rc == 0 and "Detected DISPLAY=:0" in output, (rc, output, calls)
            assert (state / "display-num").read_text().strip() == "0"
            # Startup owns the session once; a successful exit does not clean it.
            assert calls.count("cleanup") == 1, calls
        else:
            assert rc != 0, (case, rc, output, calls)
            assert "Detected DISPLAY=" not in output, output
            assert not (state / "display-num").exists()
            assert calls.count("cleanup") == (3 if case == "stale" else 2), calls
            if case == "stale":
                assert [c for c in calls if c.startswith("attempt:")] == [
                    "attempt:0", "attempt:1", "attempt:2", "attempt:3"], calls
    finally:
        if proc is not None:
            # This group contains only the fixture launcher and its fake server.
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            if proc.poll() is None:
                proc.wait(timeout=5)
