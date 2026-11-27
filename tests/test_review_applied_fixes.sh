#!/data/data/com.termux/files/usr/bin/bash
# Exercise generated startup behavior without touching the installed desktop.
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
source "$SCRIPT_DIR/framework.sh"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

_probe_x11() { python3 "$SCRIPT_DIR/probe_x11_startup.py" "$PROJECT_DIR" "$1"; }
_test_stale() { _probe_x11 stale; }
_test_dead() { _probe_x11 dead; }
_test_unready() { _probe_x11 unready; }
_test_ready() { _probe_x11 ready; }
_test_session_dead() { _probe_x11 session-dead; }
_test_cancel() { _probe_x11 cancel; }
_test_int() { _probe_x11 INT; }
_test_term() { _probe_x11 TERM; }

describe 'X11 review fixes — real generated launcher with mock services'
it 'multiple stale sockets cannot make failed servers look ready' _test_stale
it 'a server that creates a socket and exits is rejected' _test_dead
it 'a live server without an X round trip is rejected' _test_unready
it 'a ready XFCE starts with loopback audio and stops without touching foreign state' _test_ready
it 'XFCE startup failure is reported and its own server is cleaned up' _test_session_dead
it 'closing the duplicate dialog preserves the existing session' _test_cancel
it 'SIGINT at the duplicate dialog preserves the existing session' _test_int
it 'SIGTERM at the duplicate dialog preserves the existing session' _test_term
print_results
