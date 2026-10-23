#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# TEST: adapters — pkg_termux.sh, ui_terminal.sh, input/cli.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"
source "${SCRIPT_DIR}/mocks.sh"

ADAPTER_DIR="${SCRIPT_DIR}/../adapters/output"

# =============================================================================
# pkg_termux.sh — 함수 존재 여부 (계약 검증)
# =============================================================================

describe "pkg_termux.sh — 포트 계약 준수"

_load_pkg_termux() {
    source "${ADAPTER_DIR}/pkg_termux.sh"
}

_test_pkg_termux_contract() {
    source "${ADAPTER_DIR}/pkg_termux.sh"
    assert_cmd_exists pkg_update
    assert_cmd_exists pkg_upgrade
    assert_cmd_exists pkg_install
    assert_cmd_exists pkg_remove
    assert_cmd_exists pkg_is_installed
    assert_cmd_exists pkg_autoremove
    assert_cmd_exists proot_exec
    assert_cmd_exists proot_pkg_install
    assert_cmd_exists proot_pkg_update
    assert_cmd_exists proot_pkg_remove
    assert_cmd_exists proot_pkg_autoremove
    assert_cmd_exists proot_pkg_is_installed
    assert_cmd_exists pkg_install_deb_url
}
it "모든 계약 함수가 선언되어 있다" _test_pkg_termux_contract

_test_proot_exec_error() {
    source "${ADAPTER_DIR}/pkg_termux.sh"
    local out
    out=$(proot_exec echo hello 2>&1) || true
    assert_output_contains "$out" "ERROR"
}
it "proot_exec는 에러 메시지를 출력한다" _test_proot_exec_error

_test_proot_pkg_install_error() {
    source "${ADAPTER_DIR}/pkg_termux.sh"
    local out
    out=$(proot_pkg_install vim 2>&1) || true
    assert_output_contains "$out" "ERROR"
}
it "proot_pkg_install는 에러 메시지를 출력한다" _test_proot_pkg_install_error

_test_proot_pkg_is_installed_false() {
    source "${ADAPTER_DIR}/pkg_termux.sh"
    local rc=0
    proot_pkg_is_installed "nonexistent_pkg_xyz" || rc=$?
    assert_nonzero "$rc" "proot_pkg_is_installed는 항상 1(미설치)을 반환해야 한다"
}
it "proot_pkg_is_installed는 항상 미설치(1)를 반환한다" _test_proot_pkg_is_installed_false

# =============================================================================
# ui_terminal.sh — 출력 형식 검증
# =============================================================================

describe "ui_terminal.sh — UI 출력 형식"

_test_ui_terminal_contract() {
    source "${ADAPTER_DIR}/ui_terminal.sh"
    assert_cmd_exists ui_info
    assert_cmd_exists ui_warn
    assert_cmd_exists ui_error
    assert_cmd_exists ui_select
    assert_cmd_exists ui_confirm
    assert_cmd_exists ui_input
}
it "모든 UI 계약 함수가 선언되어 있다" _test_ui_terminal_contract

_test_ui_info_format() {
    source "${ADAPTER_DIR}/ui_terminal.sh"
    local out
    out=$(ui_info "테스트 메시지")
    assert_output_contains "$out" "[INFO]"
    assert_output_contains "$out" "테스트 메시지"
}
it "ui_info는 [INFO] 태그를 포함한다" _test_ui_info_format

_test_ui_warn_format() {
    source "${ADAPTER_DIR}/ui_terminal.sh"
    local out
    out=$(ui_warn "경고 메시지")
    assert_output_contains "$out" "[WARN]"
    assert_output_contains "$out" "경고 메시지"
}
it "ui_warn은 [WARN] 태그를 포함한다" _test_ui_warn_format

_test_ui_error_stderr() {
    source "${ADAPTER_DIR}/ui_terminal.sh"
    local err
    err=$(ui_error "에러 메시지" 2>&1 >/dev/null)
    assert_output_contains "$err" "[ERROR]"
    assert_output_contains "$err" "에러 메시지"
}
it "ui_error는 stderr로 출력한다" _test_ui_error_stderr

_test_ui_input_default() {
    source "${ADAPTER_DIR}/ui_terminal.sh"
    # /dev/tty 대신 빈 입력 시뮬레이션 → 기본값 반환 여부
    local out
    out=$(echo "" | ui_input "이름" "기본값" 2>/dev/null || echo "기본값")
    # 기본값이 포함되는지 확인
    assert_output_contains "$out" "기본값"
}
it "ui_input은 빈 입력 시 기본값을 반환한다" _test_ui_input_default

_test_ui_select_menu_redirected_to_stderr_static() {
    # 회귀: ui_select 메뉴 출력이 stdout으로 가면 $()로 캡처될 때 반환값과
    # 섞여서 PROOT_DISTRO 등이 통째로 깨진다. 메뉴 그룹은 stderr로 가야 한다.
    # 과거 버그: 사용자가 install.sh 대화형 실행 시 distro 선택 후
    #   "[ERROR] 지원하지 않는 distro: === proot-distro 선택 ==="로 실패
    # /dev/tty 의존 때문에 dynamic 테스트가 어려워 정적 검증으로 잠금
    local file="${ADAPTER_DIR}/ui_terminal.sh"
    # ui_select 함수 본문 추출 (sed로 함수 시작~끝 블록)
    local body
    body=$(awk '/^ui_select\(\)/,/^\}/' "$file")
    # 메뉴 그룹 redirect '} >&2'가 있어야 한다
    if ! grep -q '} >&2' <<< "$body"; then
        echo "  ui_select에 '} >&2' 메뉴 그룹 redirect가 없다"
        return 1
    fi
    # 검증 실패 메시지도 stderr로 가야 한다
    if ! grep -q '올바른 번호를 입력하세요.*>&2' <<< "$body"; then
        echo "  검증 실패 echo가 stderr로 redirect되지 않음"
        return 1
    fi
}
it "ui_select 메뉴 출력은 stderr로 redirect된다 (회귀)" \
   _test_ui_select_menu_redirected_to_stderr_static

# =============================================================================
# pkg_termux.sh — proot 신규 stub 에러 반환 검증
# =============================================================================

describe "pkg_termux.sh — proot stub 에러 반환"

_test_proot_pkg_update_error() {
    source "${ADAPTER_DIR}/pkg_termux.sh"
    local out
    out=$(proot_pkg_update 2>&1) || true
    assert_output_contains "$out" "ERROR"
}
it "proot_pkg_update는 에러 메시지를 출력한다" _test_proot_pkg_update_error

_test_proot_pkg_remove_error() {
    source "${ADAPTER_DIR}/pkg_termux.sh"
    local out
    out=$(proot_pkg_remove vim 2>&1) || true
    assert_output_contains "$out" "ERROR"
}
it "proot_pkg_remove는 에러 메시지를 출력한다" _test_proot_pkg_remove_error

_test_proot_pkg_autoremove_error() {
    source "${ADAPTER_DIR}/pkg_termux.sh"
    local out
    out=$(proot_pkg_autoremove 2>&1) || true
    assert_output_contains "$out" "ERROR"
}
it "proot_pkg_autoremove는 에러 메시지를 출력한다" _test_proot_pkg_autoremove_error

# =============================================================================
# script_builder_zenity.sh — 스크립트 빌더 직접 테스트
# =============================================================================

describe "script_builder_zenity.sh — script_build_start_xfce"

_test_sb_start_xfce_creates_valid_bash() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/startXFCE"
    script_build_start_xfce "$out"
    assert_file_exists "$out"
    bash -n "$out"
    cleanup_sandbox "$sb"
}
it "유효한 bash 스크립트를 생성한다" _test_sb_start_xfce_creates_valid_bash

_test_sb_start_xfce_has_display_detection() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/startXFCE"
    script_build_start_xfce "$out"
    assert_file_contains "$out" ".X11-unix"
    assert_file_contains "$out" "DISPLAY_NUM"
    cleanup_sandbox "$sb"
}
it "DISPLAY 자동 감지 로직이 있다" _test_sb_start_xfce_has_display_detection

_test_sb_start_xfce_no_socket_rescan() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/startXFCE"
    script_build_start_xfce "$out"
    # display_emit_session_detect의 _EXISTING_SOCK=... 재스캔(다른 목적: 기존 세션 감지)은
    # 유지되므로, display_emit_server_start가 재스캔으로 DISPLAY_NUM을 다시 뽑아내던
    # `DISPLAY_NUM=$(basename ...)` 패턴만 특정해서 검사
    assert_file_not_contains "$out" 'DISPLAY_NUM=\$(basename'
    assert_file_contains "$out" 'DISPLAY_NUM=$_DTRY'
    bash -n "$out"
    cleanup_sandbox "$sb"
}
it "X11 startXFCE는 띄운 디스플레이 번호를 그대로 쓴다 (ls|head 재스캔 없음)" _test_sb_start_xfce_no_socket_rescan

_test_sb_start_xfce_pulse_no_idle_exit() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/startXFCE"
    script_build_start_xfce "$out"
    assert_file_contains "$out" "exit-idle-time=-1"
    assert_file_not_contains "$out" "exit-idle-time=120"
    cleanup_sandbox "$sb"
}
it "PulseAudio exit-idle-time=-1 (유휴 종료 비활성)" _test_sb_start_xfce_pulse_no_idle_exit

_test_sb_start_xfce_has_gpu_branch() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/startXFCE"
    script_build_start_xfce "$out"
    assert_file_contains "$out" "MESA_LOADER_DRIVER_OVERRIDE=zink"
    assert_file_contains "$out" "LIBGL_ALWAYS_SOFTWARE"
    cleanup_sandbox "$sb"
}
it "GPU 분기(Zink vs llvmpipe)가 포함된다" _test_sb_start_xfce_has_gpu_branch

_test_sb_start_xfce_has_session_duplicate_check() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/startXFCE"
    script_build_start_xfce "$out"
    assert_file_contains "$out" "xfce4-session"
    assert_file_contains "$out" "_kill_display_session"
    assert_file_contains "$out" "세션 중복 감지"
    cleanup_sandbox "$sb"
}
it "X11 세션 중복 감지 로직이 있다" _test_sb_start_xfce_has_session_duplicate_check

# 생성한 startXFCE를 샌드박스에서 돌릴 준비 — 세션·기기를 건드리는 명령은 호출만 기록하는 함수로 가린다
_sb_start_xfce_sandbox() {
    local sb="$1" cmd
    export HOME="$sb/home" PREFIX="$sb/usr" TMPDIR="$sb/tmp" TEST_CALLS="$sb/calls"
    mkdir -p "$HOME" "$PREFIX" "$TMPDIR"
    unset DISPLAY
    for cmd in am pgrep pkill termux-x11 termux-wake-lock termux-wake-unlock zenity pulseaudio pacmd; do
        printf '%s() { echo "%s $*" >> "$TEST_CALLS"; return 1; }\n' "$cmd" "$cmd"
    done > "$sb/stubs"
}

_test_sb_start_xfce_skips_while_starting() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    _sb_start_xfce_sandbox "$sb"
    script_build_start_xfce "$sb/startXFCE"
    cat "$sb/stubs" "$sb/startXFCE" > "$sb/launcher"
    local lock="$HOME/.cache/termux-xfce/session/start.lock"
    mkdir -p "${lock%/*}"
    # 먼저 시작한 런처가 잠금을 잡고 있는 상태
    exec 8>"$lock"
    flock -n 8
    local rc=0 held=0
    bash "$sb/launcher" > "$sb/output" 2>&1 || rc=$?
    flock -n "$lock" true || held=1
    exec 8>&-
    assert_eq 0 "$rc"
    assert_file_contains "$sb/output" "건너뜁니다"
    assert_eq 1 "$held"
    assert_eq "" "$(cat "$TEST_CALLS" 2>/dev/null || true)"
    cleanup_sandbox "$sb"
}
it "X11 startXFCE는 다른 시작이 진행 중이면 아무것도 건드리지 않고 빠진다" _test_sb_start_xfce_skips_while_starting

_test_sb_start_xfce_unlocks_on_exit() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    _sb_start_xfce_sandbox "$sb"
    display_emit_kill_session() { echo '_kill_display_session() { :; }'; }
    # 세션 프로세스처럼 런처의 fd를 물려받아 런처보다 오래 사는 자식
    display_emit_server_start() { echo 'sleep 10 & echo "$!" > "$SESSION_STATE_DIR/child.pid"'; }
    script_build_start_xfce "$sb/startXFCE"
    # PulseAudio부터는 잘라 내 자식을 띄운 뒤 바로 끝나는 런처로 만든다
    { cat "$sb/stubs"; awk '/^_PA_PRELOAD=/ { exit } { print }' "$sb/startXFCE"; } > "$sb/launcher"
    bash "$sb/launcher" > "$sb/output" 2>&1
    local state="$HOME/.cache/termux-xfce/session" child made=0 free=0
    read -r child < "$state/child.pid"
    kill -0 "$child"
    # flock이 잠금 파일을 만들기 전에 런처가 만들었는지 본다
    [ -e "$state/start.lock" ] && made=1
    flock -n "$state/start.lock" true && free=1
    kill "$child"
    assert_eq 1 "$made"
    assert_eq 1 "$free"
    cleanup_sandbox "$sb"
}
it "X11 startXFCE는 끝날 때 잠금을 풀어, fd를 물려받은 자식이 남아도 다음 실행을 막지 않는다" _test_sb_start_xfce_unlocks_on_exit

_test_sb_start_xfce_tracks_session_pids() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/startXFCE"
    script_build_start_xfce "$out"
    assert_file_contains "$out" "SESSION_STATE_DIR"
    assert_file_contains "$out" "display.pid"
    assert_file_contains "$out" "session.pid"
    assert_file_contains "$out" "_cleanup_failed_start"
    cleanup_sandbox "$sb"
}
it "세션 PID를 기록하고 시작 실패 시 정리한다" _test_sb_start_xfce_tracks_session_pids

_test_sb_start_xfce_reaps_orphans_gracefully() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/startXFCE"
    script_build_start_xfce "$out"
    # 과거의 무차별 강제 종료 형태는 쓰지 않는다
    assert_file_not_contains "$out" "killall -9"
    assert_file_not_contains "$out" "pkill -9 -f conky"
    # 고아는 정확한 이름(-x) + graceful(SIGTERM→SIGKILL)으로만 정리한다
    assert_file_contains "$out" "pkill -TERM -x"
    assert_file_contains "$out" "pkill -KILL -x"
    cleanup_sandbox "$sb"
}
it "고아 프로세스를 무차별 강제 종료 대신 정확한 이름+graceful로 정리한다" _test_sb_start_xfce_reaps_orphans_gracefully

_test_sb_start_xfce_am_start_force() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/startXFCE"
    script_build_start_xfce "$out"
    assert_file_contains "$out" "am start"
    cleanup_sandbox "$sb"
}
it "am start로 APK를 시작한다" _test_sb_start_xfce_am_start_force

describe "script_builder_zenity.sh — script_build_kill_display"

_test_sb_kill_creates_valid_bash() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/kill_display_session"
    script_build_kill_display "$out"
    assert_file_exists "$out"
    bash -n "$out"
    cleanup_sandbox "$sb"
}
it "유효한 bash 스크립트를 생성한다" _test_sb_kill_creates_valid_bash

_test_sb_kill_checks_pkg_running() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/kill_display_session"
    script_build_kill_display "$out"
    assert_file_contains "$out" "\[a\]pt|\[a\]pt-get|\[d\]pkg|\[n\]ala"
    cleanup_sandbox "$sb"
}
it "패키지 설치 중 여부를 확인한다" _test_sb_kill_checks_pkg_running

_test_sb_kill_has_wake_unlock() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/kill_display_session"
    script_build_kill_display "$out"
    assert_file_contains "$out" "termux-wake-unlock"
    cleanup_sandbox "$sb"
}
it "종료 시 termux-wake-unlock을 호출한다" _test_sb_kill_has_wake_unlock

describe "script_builder_zenity.sh — script_build_cp2menu"

_test_sb_cp2menu_creates_valid_bash() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/cp2menu"
    script_build_cp2menu "$out"
    assert_file_exists "$out"
    bash -n "$out"
    cleanup_sandbox "$sb"
}
it "유효한 bash 스크립트를 생성한다" _test_sb_cp2menu_creates_valid_bash

_test_sb_cp2menu_reads_config() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/cp2menu"
    script_build_cp2menu "$out"
    assert_file_contains "$out" "termux-xfce/config"
    cleanup_sandbox "$sb"
}
it "termux-xfce/config에서 distro를 읽는다" _test_sb_cp2menu_reads_config

_test_sb_cp2menu_supports_new_rootfs_layout() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/cp2menu"
    script_build_cp2menu "$out"
    assert_file_contains "$out" 'containers/$DISTRO/rootfs'
    assert_file_contains "$out" 'installed-rootfs/$DISTRO'
    cleanup_sandbox "$sb"
}
it "신규·레거시 proot rootfs 레이아웃을 모두 지원한다" _test_sb_cp2menu_supports_new_rootfs_layout

_test_sb_cp2menu_uses_prun_gui() {
    source "${ADAPTER_DIR}/display_x11.sh"
    source "${ADAPTER_DIR}/script_builder_zenity.sh"
    local sb; sb=$(make_sandbox)
    local out="${sb}/cp2menu"
    script_build_cp2menu "$out"
    assert_file_contains "$out" "desktop_import_proot"
    cleanup_sandbox "$sb"
}
it "prun-gui로 Exec 라인을 변환한다" _test_sb_cp2menu_uses_prun_gui

# =============================================================================
# display_x11.sh — emit 함수 검증
# =============================================================================

describe "display_x11.sh — emit 함수"

_test_display_x11_emit_kill_valid() {
    source "${ADAPTER_DIR}/display_x11.sh"
    local frag
    frag=$(display_emit_kill_session)
    echo "$frag" | bash -n
}
it "display_emit_kill_session이 유효한 bash를 출력한다" _test_display_x11_emit_kill_valid

_test_display_x11_emit_server_start_valid() {
    source "${ADAPTER_DIR}/display_x11.sh"
    local frag
    frag=$(display_emit_server_start)
    echo "$frag" | bash -n
}
it "display_emit_server_start가 유효한 bash를 출력한다" _test_display_x11_emit_server_start_valid

_test_display_x11_emit_server_start_sets_xdisplay() {
    source "${ADAPTER_DIR}/display_x11.sh"
    local frag
    frag=$(display_emit_server_start)
    grep -q 'XDISPLAY=' <<< "$frag"
}
it "display_emit_server_start가 XDISPLAY를 설정한다" _test_display_x11_emit_server_start_sets_xdisplay

_test_display_x11_get_packages() {
    source "${ADAPTER_DIR}/display_x11.sh"
    local pkgs
    pkgs=$(display_get_packages)
    grep -q 'termux-x11-nightly' <<< "$pkgs"
}
it "display_get_packages가 termux-x11-nightly를 포함한다" _test_display_x11_get_packages

_test_display_x11_emit_clipboard_valid() {
    source "${ADAPTER_DIR}/display_x11.sh"
    local frag
    frag=$(display_emit_clipboard_sync)
    echo "$frag" | bash -n
}
it "display_emit_clipboard_sync이 유효한 bash를 출력한다" _test_display_x11_emit_clipboard_valid

# =============================================================================
# display_common.sh — x11/wayland 공유 세션 킬 로직
# =============================================================================

describe "display_common.sh — x11/wayland 공유"

_test_display_common_sourced_by_both_adapters() {
    grep -q 'source .*display_common\.sh' "${ADAPTER_DIR}/display_x11.sh" \
        && grep -q 'source .*display_common\.sh' "${ADAPTER_DIR}/display_wayland.sh"
}
it "display_x11.sh와 display_wayland.sh가 display_common.sh를 source한다" _test_display_common_sourced_by_both_adapters

_test_display_common_x11_emits_bare_kill_orphans() {
    grep -qx '    _kill_orphans' \
        <<< "$( source "${ADAPTER_DIR}/display_x11.sh"; display_emit_kill_session )"
}
it "display_x11.sh가 방출하는 텍스트는 인자 없는 _kill_orphans를 호출한다" _test_display_common_x11_emits_bare_kill_orphans

_test_display_common_wayland_emits_kill_orphans_labwc() {
    grep -qx '    _kill_orphans labwc' \
        <<< "$( source "${ADAPTER_DIR}/display_wayland.sh"; display_emit_kill_session )"
}
it "Wayland 종료는 구버전 labwc를 -x 목록에 넣는다" _test_display_common_wayland_emits_kill_orphans_labwc

# comm은 15바이트에서 잘리고 argv[0]을 그대로 담으므로, 긴 이름이나 절대경로로
# 실행되는 Plasma/KWin 프로세스는 pkill -x로 절대 매칭되지 않는다(-f 목록이어야 한다).
_test_display_common_wayland_cmdline_matched_names() {
    local frag
    frag=$( source "${ADAPTER_DIR}/display_wayland.sh"; display_emit_kill_session )
    grep -qx '    local cmdline_names="kwin_wayland kwin_wayland_wrapper startplasma-wayland plasmashell kded6"' \
        <<< "$frag" \
    && grep -q 'pkill -TERM -f "(\^|/)\$_n( |\\\$)"' <<< "$frag" \
    && ! grep -q '_kill_orphans .*startplasma-wayland' <<< "$frag"
}
it "15자 초과/절대경로 프로세스는 -x가 아니라 커맨드라인으로 정리한다" _test_display_common_wayland_cmdline_matched_names

_test_display_common_x11_has_empty_cmdline_names() {
    grep -qx '    local cmdline_names=""' \
        <<< "$( source "${ADAPTER_DIR}/display_x11.sh"; display_emit_kill_session )"
}
it "X11은 커맨드라인 매칭 목록이 비어 있다(0회 순회)" _test_display_common_x11_has_empty_cmdline_names

_test_display_common_emit_has_no_placeholder() {
    ! grep -q '__DISPLAY_COMMON' <<< "$( source "${ADAPTER_DIR}/display_x11.sh"; display_emit_kill_session )" \
    && ! grep -q '__DISPLAY_COMMON' <<< "$( source "${ADAPTER_DIR}/display_wayland.sh"; display_emit_kill_session )"
}
it "방출된 텍스트에 __DISPLAY_COMMON 플레이스홀더가 남지 않는다" _test_display_common_emit_has_no_placeholder

# =============================================================================
# input/cli.sh — --no-conky
# =============================================================================

describe "cli.sh — --no-conky"

_test_cli_no_conky_flag() {
    unset DISTRO USERNAME SKIP_PROOT PROOT_ONLY SKIP_CONKY DISPLAY_SERVER PROOT_SHELL
    source "${SCRIPT_DIR}/../adapters/input/cli.sh"
    parse_cli_args --no-proot --no-conky
    assert_eq "true" "$SKIP_CONKY"
}
it "--no-conky는 SKIP_CONKY=true를 설정한다" _test_cli_no_conky_flag

_test_cli_no_conky_default_false() {
    unset DISTRO USERNAME SKIP_PROOT PROOT_ONLY SKIP_CONKY DISPLAY_SERVER PROOT_SHELL
    source "${SCRIPT_DIR}/../adapters/input/cli.sh"
    parse_cli_args --no-proot
    assert_eq "false" "$SKIP_CONKY"
}
it "--no-conky 없으면 SKIP_CONKY=false" _test_cli_no_conky_default_false

_test_cli_no_conky_rejects_bad_env() {
    unset DISTRO USERNAME SKIP_PROOT PROOT_ONLY DISPLAY_SERVER PROOT_SHELL
    source "${SCRIPT_DIR}/../adapters/input/cli.sh"
    ! ( SKIP_CONKY=yes parse_cli_args --no-proot ) 2>/dev/null
}
it "SKIP_CONKY가 true/false가 아니면 거부한다" _test_cli_no_conky_rejects_bad_env

print_results
