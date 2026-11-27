"""Run generated X11 startup and stop commands with isolated mock services."""
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile


def stamp(pid):
    return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()[19]


def fake_socket(directory, name):
    # A relative address also works under a long Termux TMPDIR.
    with socket.socket(socket.AF_UNIX) as endpoint:
        original_dir = Path.cwd()
        try:
            os.chdir(directory)
            endpoint.bind(name)
        finally:
            os.chdir(original_dir)


root = Path(sys.argv[1])
case = sys.argv[2]
with tempfile.TemporaryDirectory(prefix='x11-fix.', dir=os.environ.get('TMPDIR')) as tmp:
    base = Path(tmp)
    home, prefix, temp = base / 'home', base / 'usr', base / 'tmp'
    state = home / '.cache/termux-xfce/session'
    for directory in (state, prefix / 'bin', temp / '.X11-unix'):
        directory.mkdir(parents=True, exist_ok=True)
    trace = base / 'trace'
    env = dict(os.environ, HOME=str(home), PREFIX=str(prefix), TMPDIR=str(temp),
               TEST_TRACE=str(trace), TEST_CASE=case)
    server = prefix / 'bin/termux-x11'
    server.write_text(f'#!{sys.executable}\n' + '''import os, pathlib, socket, sys, time
n = sys.argv[1].lstrip(':')
with open(os.environ['TEST_TRACE'], 'a') as f:
    f.write(f'attempt:{n}\\npid:{os.getpid()}\\n')
mode = os.environ['TEST_CASE']
if mode == 'stale' or n != '0': sys.exit(1)
s = socket.socket(socket.AF_UNIX)
os.chdir(os.environ['TMPDIR']+'/.X11-unix')
s.bind('X'+n)
if mode != 'unready':
    pathlib.Path(os.environ['TMPDIR']+'/ready'+n).touch()
if mode == 'dead': sys.exit(0)
while True: time.sleep(.1)
''')
    session = prefix / 'bin/dbus-run-session'
    session.write_text(f'#!{sys.executable}\n' + '''import os, pathlib, sys, time
with open(os.environ['TEST_TRACE'], 'a') as f:
    f.write(f'xfce\\npid:{os.getpid()}\\n')
if os.environ['TEST_CASE'] == 'session-dead':
    print('mock XFCE failure', file=sys.stderr)
    sys.exit(42)
pathlib.Path(os.environ['TMPDIR']+'/wm-ready').touch()
while True: time.sleep(.1)
''')
    for stub in (server, session):
        stub.chmod(0o755)
    build = r'''
source "$1/adapters/output/display_x11.sh"
source "$1/adapters/output/script_builder_zenity.sh"
display_emit_kill_session() {
    display_common_emit_kill_session | sed 's/^_kill_display_session()/_cleanup_recorded_session()/'
    echo '_kill_display_session() { echo cleanup >> "$TEST_TRACE"; _cleanup_recorded_session; }'
}
script_build_start_xfce "$2/start"
script_build_kill_display "$2/stop"
'''
    subprocess.run(['bash', '-c', build, '_', str(root), str(base)],
                   env=env, check=True, capture_output=True, text=True)
    stubs = r'''
pgrep() { return 1; }
am() { :; }
termux-wake-lock() { :; }
termux-wake-unlock() { echo unlock >> "$TEST_TRACE"; }
sleep() { command sleep .25; }
timeout() { shift; "$@"; }
xdotool() {
    # Give the immediately exiting fake server time to finish.
    command sleep .15
    [ -e "$TMPDIR/ready${DISPLAY#:}" ]
}
wmctrl() { [ -e "$TMPDIR/wm-ready" ]; }
pulseaudio() { :; }
pactl() {
    case "$*" in
        'list short modules')
            printf '11\tmodule-native-protocol-tcp\tauth-ip-acl=127.0.0.1 auth-anonymous=1\t0\n'
            printf '12\tmodule-native-protocol-tcp\tlisten=192.0.2.1\t0\n' ;;
        *) printf '%s\n' "$*" >> "$TEST_TRACE" ;;
    esac
}
zenity() {
    echo dialog >> "$TEST_TRACE"
    case "$TEST_CASE" in INT|TERM) builtin kill -s "$TEST_CASE" "$$" ;; esac
    return 0
}
'''
    for name in ('start', 'stop'):
        launcher = base / name
        launcher.write_text(stubs + launcher.read_text())
    fixtures = []
    if case in ('cancel', 'INT', 'TERM', 'ready'):
        # Create an unrelated process, with a stale stamp when testing stop.
        foreign = subprocess.Popen(['sleep', '60'], start_new_session=True)
        fixtures.append(foreign)
        if case == 'ready':
            (state / 'clipboard.pid').write_text(f'{foreign.pid}\tsleep\tgroup\t1\n')
        else:
            for role in ('session', 'display'):
                (state / (role + '.pid')).write_text(f'{foreign.pid}\tsleep\tgroup\t{stamp(foreign.pid)}\n')
            (state / 'display-num').write_text('0\n')
    if case == 'stale':
        for n in (0, 1):
            fake_socket(temp / '.X11-unix', f'X{n}')
    if case == 'ready':
        fake_socket(temp / '.X11-unix', 'X1')
    proc = None
    try:
        with (base / 'output').open('w') as output:
            proc = subprocess.Popen(['bash', str(base / 'start')], env=env,
                                    stdout=output, stderr=output, start_new_session=True)
            rc = proc.wait(timeout=45)
        calls = trace.read_text().splitlines() if trace.exists() else []
        output = (base / 'output').read_text()
        if case in ('cancel', 'INT', 'TERM'):
            assert rc == (0 if case == 'cancel' else 130), (rc, output, calls)
            assert 'dialog' in calls, calls
            assert 'cleanup' not in calls and 'unlock' not in calls, calls
            assert not any(c.startswith('attempt:') for c in calls), calls
            assert foreign.poll() is None
        elif case == 'ready':
            assert rc == 0 and 'Detected DISPLAY=:0' in output, (rc, output, calls)
            assert (state / 'display-num').read_text().split()[0] == '0'
            assert calls.count('cleanup') == 1, calls
            assert 'unload-module 11' in calls and 'unload-module 12' not in calls, calls
            assert ('load-module module-native-protocol-tcp listen=127.0.0.1 '
                    'auth-anonymous=0 auth-ip-acl=127.0.0.1') in calls, calls
            # Simulate PID reuse with an identity that differs from the live process.
            (state / 'clipboard.pid').write_text(f'{foreign.pid}\tsleep\tgroup\t1\n')
            subprocess.run(['bash', str(base / 'stop')], env=env, check=True, timeout=20,
                           capture_output=True, text=True)
            assert not (state / 'session.pid').exists()
            assert not (temp / '.X11-unix/X0').exists()
            assert (temp / '.X11-unix/X1').is_socket()
            assert foreign.poll() is None
        else:
            assert rc != 0, (case, rc, output, calls)
            assert not (state / 'display-num').exists()
            assert calls.count('cleanup') == 2, calls
            if case == 'session-dead':
                assert 'XFCE 세션을 시작하지 못했습니다' in output, output
                assert 'mock XFCE failure' in (state / 'xfce.log').read_text()
            else:
                assert 'Detected DISPLAY=' not in output, output
            if case == 'stale':
                attempts = [c for c in calls if c.startswith('attempt:')]
                assert attempts == ['attempt:2', 'attempt:3'], calls
                assert all((temp / f'.X11-unix/X{n}').is_socket() for n in (0, 1))
    finally:
        # These are PIDs from the fixture executables, which each start a new group.
        for line in trace.read_text().splitlines() if trace.exists() else []:
            if line.startswith('pid:'):
                try:
                    os.killpg(int(line[4:]), signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for fixture in fixtures + ([proc] if proc is not None else []):
            if fixture.poll() is None:
                fixture.terminate()
                fixture.wait(timeout=5)
