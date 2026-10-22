"""Exercise actual runtime scripts with mock Android/compositor processes only."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
prefix = Path(os.environ['PREFIX'])
base = prefix.parent
bin_dir = prefix / 'bin'
stub = bin_dir / 'mock-anland-tool'
# Termux has no /usr/bin, so name the running interpreter instead of using env.
stub.write_text(f'#!{sys.executable}\n' + r'''
import json, os, pathlib, signal, socket, subprocess, sys, time
name = pathlib.Path(sys.argv[0]).name
if name == 'dbus-run-session':
    args = sys.argv[1:]
    if args[0] == '--': args = args[1:]
    os.execvp(args[0], args)
with open(os.environ['ANLAND_TEST_TRACE'], 'a') as f:
    f.write(json.dumps({'name': name, 'pid': os.getpid(), 'argv': sys.argv[1:],
        'DISPLAY': os.getenv('DISPLAY'), 'WAYLAND_DISPLAY': os.getenv('WAYLAND_DISPLAY'),
        'ANLAND_SOCKET': os.getenv('ANLAND_SOCKET'),
        'MESA': os.getenv('MESA_LOADER_DRIVER_OVERRIDE'),
        'GDK': os.getenv('GDK_BACKEND'),
        'DEADLINE': os.getenv('ANLAND_STARTUP_DEADLINE')})+'\n')
if name in ('am', 'termux-wake-unlock', 'dbus-update-activation-environment'):
    sys.exit(0)
if os.getenv('ANLAND_TEST_FAIL') == name:
    sys.exit(7)
sock = None
if name == 'anland':
    path = pathlib.Path(sys.argv[sys.argv.index('--socket')+1])
elif name == 'pipewire':
    path = pathlib.Path(os.environ['PIPEWIRE_RUNTIME_DIR']) / 'pipewire-0'
elif name == 'startplasma-wayland':
    path = pathlib.Path(os.environ['XDG_RUNTIME_DIR']) / 'wayland-0'
else:
    path = None
if path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(str(path)); sock.listen()
child = None
stopping = False
def stop(*_):
    global stopping
    stopping = True
    if child: child.terminate()
signal.signal(signal.SIGTERM, stop)
if name == 'startplasma-wayland':
    # Real startplasma-wayland starts KWin, which starts plasmashell with the
    # compositor's own DISPLAY/WAYLAND_DISPLAY, and keeps running when that shell
    # dies — which is exactly why the supervisor has to respawn it.
    env = dict(os.environ, DISPLAY=':91', WAYLAND_DISPLAY=path.name)
    subprocess.Popen([str(pathlib.Path(sys.argv[0]).parent / 'plasmashell')], env=env)
    while not stopping: time.sleep(0.05)
    if sock: sock.close(); path.unlink(missing_ok=True)
    sys.exit(0)
while not stopping: time.sleep(0.05)
if sock: sock.close(); path.unlink(missing_ok=True)
''')
stub.chmod(0o755)
for name in ('dbus-run-session', 'anland', 'anland-compatible', 'am', 'pipewire',
             'wireplumber', 'startplasma-wayland', 'plasmashell',
             'termux-wake-unlock', 'dbus-update-activation-environment'):
    (bin_dir / name).symlink_to(stub)
shutil.copyfile(root / 'runtime' / 'anland-session.sh', bin_dir / 'termux-xfce-anland-session')

def alive(pid):
    try: os.kill(pid, 0)
    except ProcessLookupError: return False
    return True

_case_seq = 0

def run_case(failure, variant):
    # AF_UNIX paths cap at 108 bytes and Termux's TMPDIR prefix is long, so the
    # per-case directory stays short rather than naming the case.
    global _case_seq
    _case_seq += 1
    case = base / f'c{_case_seq}'
    state = case / 'state'
    runtime = socket_base / f'r{_case_seq}'
    temp = socket_base / f't{_case_seq}'
    for d in (state, runtime, temp): d.mkdir(parents=True)
    (Path(os.environ['HOME']) / '.config/termux-xfce/anland-variant').write_text(variant+'\n')
    trace = case / 'trace.jsonl'
    def read_rows():
        return [json.loads(line) for line in trace.read_text().splitlines()]
    def wait_rows(pred, secs):
        # Poll the trace until pred(rows) holds or the deadline passes; the caller
        # asserts on the returned rows so a timeout reports what was seen.
        deadline = time.monotonic()+secs
        while True:
            rows = read_rows()
            if pred(rows) or time.monotonic() >= deadline: return rows
            time.sleep(.1)
    env = dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],
               SESSION_STATE_DIR=str(state), XDG_RUNTIME_DIR=str(runtime), TMPDIR=str(temp),
               ANLAND_TEST_TRACE=str(trace), ANLAND_TEST_FAIL=failure,
               DISPLAY=':0', WAYLAND_DISPLAY='wrong-parent', WLR_BACKENDS='x11',
               MESA_LOADER_DRIVER_OVERRIDE='zink', GDK_BACKEND='x11')
    env.pop('ANLAND_STARTUP_DEADLINE', None)
    if failure == 'plasmashell':
        # Exercise the launcher's deadline propagation without spending 90s on a
        # shell that is deliberately unable to start. Ignoring this deadline
        # would make the wait below time out and fail the test.
        env['ANLAND_STARTUP_DEADLINE'] = str(int(time.time()) + 15)
    with (case / 'log').open('w') as log:
        proc = subprocess.Popen(['bash', str(bin_dir/'termux-xfce-anland-session')], env=env,
                                stdout=log, stderr=log)
        try:
            # Android process discovery and interpreter startup can exceed 12s
            # under concurrent test load. Healthy starts get the supervisor's
            # full initialization budget, and still finish as soon as ready.
            deadline = time.monotonic()+(120 if not failure else 12)
            while time.monotonic() < deadline:
                if proc.poll() is not None or (state/'anland-ready').exists(): break
                time.sleep(.05)
            rows = read_rows()
            if failure:
                assert proc.wait(timeout=35 if failure == 'plasmashell' else 120) != 0, (failure, (case/'log').read_text())
                assert not (state/'anland-ready').exists()
            else:
                assert (state/'anland-ready').exists(), (case/'log').read_text()
                # The marker carries the socket name KWin actually picked.
                assert (state/'anland-ready').read_text().strip() == 'wayland-0', (case/'log').read_text()
                # anland-ready is written as soon as the supervisor sees the plasmashell
                # process; the mock may not have appended its trace row yet.
                rows = wait_rows(lambda rows: any(r['name']=='plasmashell' for r in rows), 20)
                assert any(r['name']=='plasmashell' for r in rows), (case/'log').read_text()
                plasma = next(r for r in rows if r['name']=='startplasma-wayland')
                assert plasma['DISPLAY'] is None and plasma['WAYLAND_DISPLAY'] is None
                assert plasma['MESA']=='kgsl' and plasma['GDK']=='wayland,x11'
                shell = next(r for r in rows if r['name']=='plasmashell')
                assert shell['DISPLAY']==':91' and shell['WAYLAND_DISPLAY']=='wayland-0'
                assert any(r['name']=='anland-compatible' for r in rows) == (variant=='compatible')
                assert any(r['name']=='am' and 'com.anland.termux/.MainActivity' in r['argv'] for r in rows)
                # The low-memory killer takes plasmashell in practice; the
                # supervisor must bring it back instead of leaving a black screen.
                os.kill(shell['pid'], signal.SIGKILL)
                def respawned(rows):
                    shells = [r for r in rows if r['name']=='plasmashell']
                    return len(shells) > 1 and alive(shells[-1]['pid'])
                rows = wait_rows(respawned, 20)
                shells = [r for r in rows if r['name']=='plasmashell']
                assert len(shells) > 1, ('shell not respawned', (case/'log').read_text())
                assert shells[-1]['WAYLAND_DISPLAY']=='wayland-0', shells[-1]
                os.kill(plasma['pid'], signal.SIGTERM)
                # Cleanup runs process discovery and two Python Android stubs;
                # their startup alone can exceed 8s on a busy Android device.
                proc.wait(timeout=30)
            # The startup deadline is the supervisor's; no session process inherits it.
            # Checked last so the plasmashell rows, whose environ is persisted to
            # plasma.env and replayed on respawn, are covered too.
            assert all(r['DEADLINE'] is None for r in rows), rows
            deadline = time.monotonic()+3
            while time.monotonic()<deadline and any(alive(r['pid']) for r in rows): time.sleep(.05)
            assert not any(alive(r['pid']) for r in rows), ('child leaked', rows)
            assert not (state/'anland-ready').exists()
            assert not (temp/'anland/display_daemon.sock').exists()
            print(f'PASS runtime: {variant}, {failure or "normal shutdown"}')
        finally:
            if proc.poll() is None: proc.terminate()
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait()
            if trace.exists():
                for row in map(json.loads, trace.read_text().splitlines()):
                    try: os.kill(row['pid'], signal.SIGTERM)
                    except ProcessLookupError: pass

# Keep socket paths independent of a caller's deeply nested TMPDIR/sandbox.
socket_parent = '/data/data/com.termux/files/usr/tmp'
if not Path(socket_parent).is_dir():
    socket_parent = '/tmp'
with tempfile.TemporaryDirectory(prefix='a.', dir=socket_parent) as socket_dir:
    socket_base = Path(socket_dir)
    run_case('', 'compatible')
    run_case('', 'standard')
    run_case('anland', 'compatible')
    run_case('anland-compatible', 'compatible')
    run_case('startplasma-wayland', 'compatible')
    run_case('plasmashell', 'compatible')
