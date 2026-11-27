#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# TEST: install.sh — CLI 옵션 조합 매트릭스 (dispatch 검증)
# -----------------------------------------------------------------------------
# install.sh를 모든 CLI 옵션 조합으로 호출하고, 각 조합에서 호출되어야 하는
# domain setup_* 함수의 호출 여부를 트레이스로 검증.
#
# - 실제 설치는 하지 않음 (모든 setup_* 함수는 _INSTALL_HOOK으로 스텁 교체)
# - distro × proot-only × no-proot × config 보존(PROOT_SHELL/DISPLAY_SERVER) 조합 커버
#   (케이스 수 = `bash tests/test_install_matrix.sh`가 출력하는 it 항목 수)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"

REPO_ROOT="${SCRIPT_DIR}/.."
TRACE_FILE=$(mktemp "$(_test_tmp_base)/install_matrix_trace_XXXXXX")
HOOK_FILE=$(mktemp "$(_test_tmp_base)/install_matrix_hook_XXXXXX")

# -----------------------------------------------------------------------------
# 훅 파일: install.sh가 source하는 스텁
#   - 모든 setup_* / proot 함수를 _record로 교체 (TRACE_FILE에 한 줄씩 추가)
#   - 외부 명령(termux-setup-storage 등)도 no-op으로 스텁
# -----------------------------------------------------------------------------
_write_hook_file() {
    cat > "$HOOK_FILE" << 'HOOK_EOF'
# 트레이스 기록 함수
_trace() { printf '%s\n' "$*" >> "${_TRACE_FILE}"; }

# Termux native setup
setup_termux_base()       { _trace "setup_termux_base"; }
setup_xfce_packages()     { _trace "setup_xfce_packages"; }
setup_xfce_theme()        { _trace "setup_xfce_theme"; }
setup_xfce_fonts()        { _trace "setup_xfce_fonts"; }
setup_xfce_wallpaper()    { _trace "setup_xfce_wallpaper"; }
setup_xfce_fancybash()    { _trace "setup_xfce_fancybash $*"; }
setup_xfce_autostart()    { _trace "setup_xfce_autostart"; }
setup_termux_shortcuts()  { _trace "setup_termux_shortcuts"; }
display_setup_apk()       { _trace "display_setup_apk"; }
display_preflight()       { _trace "display_preflight"; }
display_setup_runtime()   { _trace "display_setup_runtime"; }
setup_termux_api_apk()    { _trace "setup_termux_api_apk"; }
setup_termux_float_apk()  { _trace "setup_termux_float_apk"; }
setup_termux_widget()     { _trace "setup_termux_widget"; }
setup_termux_boot_apk()   { _trace "setup_termux_boot_apk"; }

# proot setup
setup_proot_install()         { _trace "setup_proot_install"; }
setup_proot_update()          { _trace "setup_proot_update"; }
setup_proot_user()            { _trace "setup_proot_user"; }
setup_proot_base_packages()   { _trace "setup_proot_base_packages"; }
setup_proot_env()             { _trace "setup_proot_env"; }
setup_proot_timezone()        { _trace "setup_proot_timezone"; }
setup_proot_fancybash()       { _trace "setup_proot_fancybash"; }
setup_proot_cursor_theme()    { _trace "setup_proot_cursor_theme"; }
setup_proot_conky()           { _trace "setup_proot_conky"; }
setup_proot_alias()           { _trace "setup_proot_alias"; }

# 외부 명령 / pkg 어댑터 — install.sh가 호출할 수 있는 것들
termux-setup-storage()    { _trace "termux-setup-storage"; }
termux-reload-settings()  { _trace "termux-reload-settings"; return 0; }
sleep()                   { :; }   # 테스트 가속

# UI는 터미널 어댑터를 그대로 쓰되 ui_info만 조용히
ui_info()  { :; }
ui_warn()  { :; }
ui_error() { echo "ERROR: $*" >&2; }

# readlink (login shell 탐지)에 의해 setup_xfce_fancybash가 호출될지 결정.
# 테스트는 zsh가 login shell이 아닌 상태를 시뮬레이션 → fancybash 호출 발생 정상.
HOOK_EOF
}

# -----------------------------------------------------------------------------
# install.sh를 격리된 HOME/PREFIX에서 실행
# -----------------------------------------------------------------------------
_run_install() {
    local sandbox
    sandbox=$(mktemp -d "$(_test_tmp_base)/install_matrix_XXXXXX")
    > "$TRACE_FILE"

    # install.sh가 자체적으로 sandbox HOME에 .config 디렉토리 생성하므로 별도 셋업 불필요
    HOME="$sandbox/home" \
    PREFIX="$sandbox/usr" \
    _TRACE_FILE="$TRACE_FILE" \
    _INSTALL_HOOK="$HOOK_FILE" \
        bash "$REPO_ROOT/install.sh" "$@" >/dev/null 2>&1
    local rc=$?
    # sandbox는 트레이스만 남기면 되니 즉시 정리
    rm -rf "$sandbox"
    return $rc
}

_assert_traced() {
    local fn="$1"
    if ! grep -qx -- "$fn" "$TRACE_FILE" && ! grep -q "^${fn} " "$TRACE_FILE"; then
        echo "[ASSERT] expected call '$fn' not in trace" >&2
        echo "[ASSERT] trace was:" >&2
        sed 's/^/    /' "$TRACE_FILE" >&2
        return 1
    fi
}

_assert_not_traced() {
    local fn="$1"
    if grep -qx -- "$fn" "$TRACE_FILE" || grep -q "^${fn} " "$TRACE_FILE"; then
        echo "[ASSERT] unexpected call '$fn' in trace" >&2
        sed 's/^/    /' "$TRACE_FILE" >&2
        return 1
    fi
}

# 사전 준비
_write_hook_file

# =============================================================================
# 매트릭스 1: --no-proot (Termux native만)
# =============================================================================

describe "matrix — Termux native만 (--no-proot)"

_test_minimal_native() {
    _run_install --no-proot
    _assert_traced "setup_termux_base"
    _assert_traced "setup_xfce_packages"
    _assert_traced "setup_xfce_autostart"
    _assert_traced "setup_termux_shortcuts"
    _assert_traced "display_setup_apk"
    _assert_traced "setup_termux_api_apk"
    _assert_traced "setup_termux_float_apk"
    _assert_not_traced "setup_proot_install"
}
it "최소 native (no-proot) — companion APK 포함, proot 없음" _test_minimal_native

_test_fancybash_failure_does_not_abort_install() {
    # setup_xfce_fancybash가 실패해도 install.sh 전체가 rc 0으로 끝나야 함
    # (fancybash 호출은 readlink "$HOME/.termux/shell"이 */zsh로 안 끝날 때만 발생하므로
    #  샌드박스 HOME에는 해당 심볼릭 링크가 없다 — _run_install의 sandbox HOME이 그 조건 충족)
    cat > "$HOOK_FILE" << 'HOOK_EOF'
_trace() { printf '%s\n' "$*" >> "${_TRACE_FILE}"; }
setup_termux_base()       { _trace "setup_termux_base"; }
setup_xfce_packages()     { _trace "setup_xfce_packages"; }
setup_xfce_theme()        { _trace "setup_xfce_theme"; }
setup_xfce_fonts()        { _trace "setup_xfce_fonts"; }
setup_xfce_wallpaper()    { _trace "setup_xfce_wallpaper"; }
setup_xfce_fancybash()    { _trace "setup_xfce_fancybash $*"; return 1; }
setup_xfce_autostart()    { _trace "setup_xfce_autostart"; }
setup_termux_shortcuts()  { _trace "setup_termux_shortcuts"; }
display_setup_apk()       { _trace "display_setup_apk"; }
display_preflight()       { _trace "display_preflight"; }
display_setup_runtime()   { _trace "display_setup_runtime"; }
setup_termux_api_apk()    { _trace "setup_termux_api_apk"; }
setup_termux_float_apk()  { _trace "setup_termux_float_apk"; }
setup_termux_widget()     { _trace "setup_termux_widget"; }
setup_termux_boot_apk()   { _trace "setup_termux_boot_apk"; }
setup_proot_install()         { _trace "setup_proot_install"; }
setup_proot_update()          { _trace "setup_proot_update"; }
setup_proot_user()            { _trace "setup_proot_user"; }
setup_proot_base_packages()   { _trace "setup_proot_base_packages"; }
setup_proot_env()             { _trace "setup_proot_env"; }
setup_proot_timezone()        { _trace "setup_proot_timezone"; }
setup_proot_fancybash()       { _trace "setup_proot_fancybash"; }
setup_proot_cursor_theme()    { _trace "setup_proot_cursor_theme"; }
setup_proot_conky()           { _trace "setup_proot_conky"; }
setup_proot_alias()           { _trace "setup_proot_alias"; }
termux-setup-storage()    { _trace "termux-setup-storage"; }
termux-reload-settings()  { _trace "termux-reload-settings"; return 0; }
sleep()                   { :; }
ui_info()  { :; }
ui_warn()  { :; }
ui_error() { echo "ERROR: $*" >&2; }
HOOK_EOF

    local rc=0
    _run_install --no-proot || rc=$?

    # 훅 파일을 원래 상태로 복원 — 이후 테스트에 영향 없게
    _write_hook_file

    assert_zero "$rc" "setup_xfce_fancybash 실패해도 install.sh는 rc 0으로 끝나야 함"
}
it "setup_xfce_fancybash 실패해도 install.sh 전체는 중단되지 않는다" _test_fancybash_failure_does_not_abort_install

# =============================================================================
# 매트릭스 2: --proot-only (proot만, native 생략)
# =============================================================================

describe "matrix — proot-only (--proot-only)"

_test_proot_only_ubuntu() {
    _run_install --proot-only --distro ubuntu --user testuser
    _assert_not_traced "setup_termux_base"
    _assert_not_traced "setup_xfce_packages"
    _assert_not_traced "display_setup_apk"
    _assert_not_traced "setup_termux_api_apk"
    _assert_not_traced "setup_termux_float_apk"
    _assert_traced "setup_proot_install"
    _assert_traced "setup_proot_user"
    _assert_traced "setup_proot_alias"
}
it "Ubuntu proot-only — native+companion APK 모두 생략, proot만 실행" _test_proot_only_ubuntu

_test_proot_only_archlinux() {
    _run_install --proot-only --distro archlinux --user testuser
    _assert_not_traced "setup_termux_base"
    _assert_traced "setup_proot_install"
    _assert_traced "setup_proot_alias"
}
it "Arch proot-only — native 모두 생략, proot만 실행" _test_proot_only_archlinux

# =============================================================================
# 매트릭스 3: 풀 설치 (native + proot)
# =============================================================================

describe "matrix — 풀 설치 (native + proot)"

_test_full_ubuntu() {
    _run_install --distro ubuntu --user testuser
    _assert_traced "setup_termux_base"
    _assert_traced "setup_proot_install"
    _assert_traced "setup_proot_base_packages"
    _assert_traced "setup_proot_alias"
    _assert_traced "display_setup_apk"
}
it "Ubuntu 풀 — native + proot 모두 실행" _test_full_ubuntu

_test_full_arch() {
    _run_install --distro archlinux --user testuser
    _assert_traced "setup_termux_base"
    _assert_traced "setup_proot_install"
    _assert_traced "setup_proot_alias"
}
it "Arch 풀 — native + proot 모두 실행" _test_full_arch

# =============================================================================
# 매트릭스 4: 환경변수 기반 (CLI 인자 대신)
# =============================================================================

describe "matrix — 환경변수 기반 호출"

_test_env_vars_no_proot() {
    SKIP_PROOT=true _run_install
    _assert_traced "setup_termux_base"
    _assert_not_traced "setup_proot_install"
}
it "SKIP_PROOT=true — proot 생략" _test_env_vars_no_proot

_test_env_vars_full() {
    DISTRO=ubuntu USERNAME=testuser _run_install
    _assert_traced "setup_termux_base"
    _assert_traced "setup_proot_install"
}
it "DISTRO=ubuntu USERNAME=testuser — 풀 설치" _test_env_vars_full

# =============================================================================
# 매트릭스 5: --help / 잘못된 인자
# =============================================================================

describe "matrix — CLI 인자 검증"

_test_help_exits_zero() {
    local rc=0
    HOME="$(mktemp -d)" PREFIX="$(mktemp -d)" \
        bash "$REPO_ROOT/install.sh" --help >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[ASSERT] --help should exit 0, got $rc" >&2
        return 1
    fi
}
it "--help는 exit 0으로 종료" _test_help_exits_zero

_test_unknown_arg_exits_nonzero() {
    # set -e 트립 방지: 비정상 종료를 기대하므로 || rc=$? 로 캡처
    local rc=0
    HOME="$(mktemp -d)" PREFIX="$(mktemp -d)" \
        bash "$REPO_ROOT/install.sh" --not-a-real-flag >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[ASSERT] unknown flag should exit non-zero, got 0" >&2
        return 1
    fi
}
it "알 수 없는 인자는 non-zero exit" _test_unknown_arg_exits_nonzero

_test_invalid_distro_exits_nonzero() {
    local rc=0
    _INSTALL_HOOK="$HOOK_FILE" _TRACE_FILE="$TRACE_FILE" \
    HOME="$(mktemp -d)" PREFIX="$(mktemp -d)" \
        bash "$REPO_ROOT/install.sh" --distro freebsd --user testuser \
        >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[ASSERT] invalid distro should exit non-zero, got 0" >&2
        return 1
    fi
}
it "지원하지 않는 distro는 non-zero exit" _test_invalid_distro_exits_nonzero

_test_invalid_username_exits_nonzero() {
    local rc=0
    _run_install --distro ubuntu --user 'bad;name' || rc=$?
    assert_nonzero "$rc" "위험한 문자가 포함된 사용자 이름을 거부해야 함"
}
it "잘못된 사용자 이름은 non-zero exit" _test_invalid_username_exits_nonzero

_test_conflicting_modes_exit_nonzero() {
    local rc=0
    _run_install --no-proot --proot-only || rc=$?
    assert_nonzero "$rc" "--no-proot와 --proot-only를 함께 허용하면 안 됨"
}
it "--no-proot와 --proot-only 충돌은 non-zero exit" _test_conflicting_modes_exit_nonzero

_test_no_proot_with_distro_exits_nonzero() {
    local rc=0
    _run_install --no-proot --distro ubuntu || rc=$?
    assert_nonzero "$rc" "--no-proot와 distro 지정을 함께 허용하면 안 됨"
}
it "--no-proot와 --distro 충돌은 non-zero exit" _test_no_proot_with_distro_exits_nonzero

_test_invalid_shell_exits_nonzero() {
    local rc=0
    PROOT_SHELL=fish _run_install --distro ubuntu --user testuser || rc=$?
    assert_nonzero "$rc" "지원하지 않는 proot shell을 거부해야 함"
}
it "지원하지 않는 PROOT_SHELL은 non-zero exit" _test_invalid_shell_exits_nonzero

# =============================================================================
# 매트릭스 6: config 파일 생성 검증
# =============================================================================

describe "matrix — config 파일 생성"

_test_config_file_records_distro() {
    local sandbox; sandbox=$(mktemp -d)
    HOME="$sandbox/home" PREFIX="$sandbox/usr" \
    _TRACE_FILE="$TRACE_FILE" _INSTALL_HOOK="$HOOK_FILE" \
        bash "$REPO_ROOT/install.sh" --distro ubuntu --user lideok \
        >/dev/null 2>&1

    local cfg="$sandbox/home/.config/termux-xfce/config"
    assert_file_exists "$cfg"
    assert_file_contains "$cfg" 'PROOT_DISTRO="ubuntu"'
    assert_file_contains "$cfg" 'PROOT_USER="lideok"'
    local mode
    mode=$(stat -c '%a' "$cfg")
    assert_eq "600" "$mode" "config는 사용자만 읽고 쓸 수 있어야 함"
    rm -rf "$sandbox"
}
it "config 파일에 distro/user가 기록되고 권한은 600" _test_config_file_records_distro

_test_failed_proot_setup_leaves_previous_config() {
    local sb cfg hook rc=0
    sb=$(make_sandbox)
    cfg="$sb/home/.config/termux-xfce/config"
    mkdir -p "${cfg%/*}"
    printf 'PROOT_DISTRO="ubuntu"\nPROOT_USER="alice"\nPROOT_SHELL="zsh"\n' > "$cfg"
    cp "$cfg" "$sb/original"
    hook="$sb/hook.sh"
    cp "$HOOK_FILE" "$hook"
    printf '\nsetup_proot_update() { return 42; }\n' >> "$hook"
    HOME="$sb/home" PREFIX="$sb/usr" _TRACE_FILE="$TRACE_FILE" _INSTALL_HOOK="$hook" \
        bash "$REPO_ROOT/install.sh" --proot-only --distro archlinux --user bob \
        > "$sb/output" 2>&1 || rc=$?
    assert_eq 42 "$rc"
    cmp "$sb/original" "$cfg"
    cleanup_sandbox "$sb"
}
it "proot 구성이 실패하면 이전 배포판 설정을 유지한다" _test_failed_proot_setup_leaves_previous_config

_test_config_file_no_distro_when_no_proot() {
    local sandbox; sandbox=$(mktemp -d)
    mkdir -p "$sandbox/home/.config/termux-xfce"
    printf 'PROOT_DISTRO="ubuntu"\nPROOT_USER="testuser"\n' > "$sandbox/home/.config/termux-xfce/config"
    HOME="$sandbox/home" PREFIX="$sandbox/usr" \
    _TRACE_FILE="$TRACE_FILE" _INSTALL_HOOK="$HOOK_FILE" \
        bash "$REPO_ROOT/install.sh" --no-proot \
        >/dev/null 2>&1

    local cfg="$sandbox/home/.config/termux-xfce/config"
    assert_file_exists "$cfg"
    assert_file_contains "$cfg" 'PROOT_DISTRO=""'
    rm -rf "$sandbox"
}
it "no-proot clears an earlier distro selection" _test_config_file_no_distro_when_no_proot

_test_config_preserves_proot_shell_zsh() {
    local sandbox; sandbox=$(mktemp -d)
    mkdir -p "$sandbox/home/.config/termux-xfce"
    cat > "$sandbox/home/.config/termux-xfce/config" << 'EOF'
PROOT_DISTRO="ubuntu"
PROOT_USER="lideok"
INSTALL_ARCH="aarch64"
DISPLAY_SERVER="x11"
PROOT_SHELL="zsh"
EOF

    HOME="$sandbox/home" PREFIX="$sandbox/usr" \
    _TRACE_FILE="$TRACE_FILE" _INSTALL_HOOK="$HOOK_FILE" \
        bash "$REPO_ROOT/install.sh" --proot-only --distro ubuntu --user lideok \
        >/dev/null 2>&1

    local cfg="$sandbox/home/.config/termux-xfce/config"
    assert_file_contains "$cfg" 'PROOT_SHELL="zsh"'
    rm -rf "$sandbox"
}
it "--proot-only 재실행해도 기존 PROOT_SHELL=zsh가 유지된다 (never reset)" _test_config_preserves_proot_shell_zsh

_test_config_preserves_prun_runtime() {
    local sandbox; sandbox=$(mktemp -d)
    mkdir -p "$sandbox/home/.config/termux-xfce"
    cat > "$sandbox/home/.config/termux-xfce/config" << 'EOF'
PROOT_DISTRO="ubuntu"
PROOT_USER="lideok"
PRUN_RUNTIME="chroot-ng"
EOF

    HOME="$sandbox/home" PREFIX="$sandbox/usr" \
    _TRACE_FILE="$TRACE_FILE" _INSTALL_HOOK="$HOOK_FILE" \
        bash "$REPO_ROOT/install.sh" --proot-only --distro ubuntu --user lideok \
        >/dev/null 2>&1

    local cfg="$sandbox/home/.config/termux-xfce/config"
    assert_file_contains "$cfg" 'PRUN_RUNTIME="chroot-ng"'
    rm -rf "$sandbox"
}
it "재실행해도 사용자가 켠 PRUN_RUNTIME=chroot-ng가 유지된다" _test_config_preserves_prun_runtime

_test_config_omits_unset_prun_runtime() {
    local sandbox; sandbox=$(mktemp -d)
    HOME="$sandbox/home" PREFIX="$sandbox/usr" \
    _TRACE_FILE="$TRACE_FILE" _INSTALL_HOOK="$HOOK_FILE" \
        bash "$REPO_ROOT/install.sh" --distro ubuntu --user lideok \
        >/dev/null 2>&1

    local cfg="$sandbox/home/.config/termux-xfce/config"
    assert_file_exists "$cfg" && assert_file_not_contains "$cfg" 'PRUN_RUNTIME'
    local rc=$?; rm -rf "$sandbox"; return "$rc"
}
it "PRUN_RUNTIME을 켠 적이 없으면 config에 기록하지 않는다 (기본 proot)" _test_config_omits_unset_prun_runtime

_test_config_merge_tolerates_missing_keys() {
    local sandbox; sandbox=$(mktemp -d)
    mkdir -p "$sandbox/home/.config/termux-xfce"
    cat > "$sandbox/home/.config/termux-xfce/config" << 'EOF'
DISPLAY_SERVER="x11"
EOF

    local rc=0
    HOME="$sandbox/home" PREFIX="$sandbox/usr" \
    _TRACE_FILE="$TRACE_FILE" _INSTALL_HOOK="$HOOK_FILE" \
        bash "$REPO_ROOT/install.sh" --proot-only --distro ubuntu --user testuser \
        >/dev/null 2>&1 || rc=$?

    assert_zero "$rc" "구버전 config(키 누락) 병합은 크래시 없이 rc 0이어야 함"
    local cfg="$sandbox/home/.config/termux-xfce/config"
    assert_file_contains "$cfg" 'PROOT_SHELL="bash"'
    rm -rf "$sandbox"
}
it "구버전 config(키 누락)로 재실행해도 크래시 없이 병합된다" _test_config_merge_tolerates_missing_keys

_test_config_records_explicit_proot_shell() {
    local sandbox; sandbox=$(mktemp -d)

    local rc=0
    HOME="$sandbox/home" PREFIX="$sandbox/usr" \
    _TRACE_FILE="$TRACE_FILE" _INSTALL_HOOK="$HOOK_FILE" \
    PROOT_SHELL=zsh \
        bash "$REPO_ROOT/install.sh" --distro ubuntu --user testuser \
        >/dev/null 2>&1 || rc=$?

    assert_zero "$rc" "PROOT_SHELL=zsh 신규 설치는 rc 0이어야 함"
    local cfg="$sandbox/home/.config/termux-xfce/config"
    assert_file_contains "$cfg" 'PROOT_SHELL="zsh"'
    rm -rf "$sandbox"
}
it "PROOT_SHELL=zsh 신규 설치는 config에 zsh를 기록한다" _test_config_records_explicit_proot_shell

_test_config_explicit_shell_overrides_existing() {
    local sandbox; sandbox=$(mktemp -d)
    mkdir -p "$sandbox/home/.config/termux-xfce"
    cat > "$sandbox/home/.config/termux-xfce/config" << 'EOF'
PROOT_DISTRO="ubuntu"
PROOT_USER="lideok"
INSTALL_ARCH="aarch64"
DISPLAY_SERVER="x11"
PROOT_SHELL="bash"
EOF

    local rc=0
    HOME="$sandbox/home" PREFIX="$sandbox/usr" \
    _TRACE_FILE="$TRACE_FILE" _INSTALL_HOOK="$HOOK_FILE" \
    PROOT_SHELL=zsh \
        bash "$REPO_ROOT/install.sh" --proot-only --distro ubuntu --user testuser \
        >/dev/null 2>&1 || rc=$?

    assert_zero "$rc" "PROOT_SHELL=zsh로 기존 config 덮어쓰기는 rc 0이어야 함"
    local cfg="$sandbox/home/.config/termux-xfce/config"
    assert_file_contains "$cfg" 'PROOT_SHELL="zsh"'
    rm -rf "$sandbox"
}
it "PROOT_SHELL=zsh는 기존 config의 값을 덮어쓴다" _test_config_explicit_shell_overrides_existing

_test_config_preserves_display_server_on_proot_only() {
    local sandbox; sandbox=$(mktemp -d)
    mkdir -p "$sandbox/home/.config/termux-xfce"
    cat > "$sandbox/home/.config/termux-xfce/config" << 'EOF'
PROOT_DISTRO="ubuntu"
PROOT_USER="lideok"
INSTALL_ARCH="aarch64"
DISPLAY_SERVER="wayland"
PROOT_SHELL="bash"
EOF

    # --display 미지정 → 이번 실행값은 기본 x11로 계산되지만, PROOT_ONLY=true이므로
    # 기존 wayland를 유지해야 한다.
    HOME="$sandbox/home" PREFIX="$sandbox/usr" \
    _TRACE_FILE="$TRACE_FILE" _INSTALL_HOOK="$HOOK_FILE" \
        bash "$REPO_ROOT/install.sh" --proot-only --distro ubuntu --user lideok \
        >/dev/null 2>&1

    local cfg="$sandbox/home/.config/termux-xfce/config"
    assert_file_contains "$cfg" 'DISPLAY_SERVER="wayland"'
    rm -rf "$sandbox"
}
it "--proot-only 재실행은 기존 DISPLAY_SERVER를 유지한다" _test_config_preserves_display_server_on_proot_only

# =============================================================================
# Anland install dispatch
# =============================================================================
_test_wayland_dispatch() {
    _write_hook_file
    _run_install --no-proot --display wayland
    _assert_traced display_preflight
    _assert_traced display_setup_runtime
    _assert_traced display_setup_apk
    local checks
    checks=$(awk '/display_preflight|setup_xfce_packages|display_setup_runtime|setup_termux_shortcuts|display_setup_apk/' "$TRACE_FILE")
    assert_eq $'display_preflight\nsetup_xfce_packages\ndisplay_setup_runtime\nsetup_termux_shortcuts\ndisplay_setup_apk' "$checks"
}
it 'Wayland validates hardware and installs runtime before generating the launcher' _test_wayland_dispatch

_test_wayland_preflight_rejects() {
    _write_hook_file
    echo 'display_preflight() { _trace "display_preflight"; return 1; }' >> "$HOOK_FILE"
    local rc=0
    _run_install --no-proot --display wayland || rc=$?
    assert_nonzero "$rc"
    _assert_not_traced setup_termux_base
    _assert_not_traced display_setup_runtime
    _assert_not_traced display_setup_apk
}
it 'a rejected Wayland device does not start package installation' _test_wayland_preflight_rejects

# =============================================================================
# 정리
# =============================================================================
rm -f "$HOOK_FILE" "$TRACE_FILE"

print_results
