#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# TEST: domain/termux_env.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"
source "${SCRIPT_DIR}/mocks.sh"

DOMAIN_DIR="${SCRIPT_DIR}/../domain"
_REAL_PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

_load_domain() {
    local sandbox="$1"
    setup_fs_sandbox "$sandbox"
    mock_pkg_adapter
    mock_ui_adapter
    mock_wget
    source "${DOMAIN_DIR}/packages.sh"
    # script_builder는 순수 파일 생성기(외부 의존 없음) → 실제 어댑터 로드
    source "${DOMAIN_DIR}/../adapters/output/display_x11.sh"
    source "${DOMAIN_DIR}/../adapters/output/script_builder_zenity.sh"
    source "${DOMAIN_DIR}/termux_env.sh"
}

# =============================================================================
# _setup_termux_properties
# =============================================================================

describe "termux_env — _setup_termux_properties"

_test_props_uncomments_allow_external() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_termux_properties
    assert_file_contains "${HOME}/.termux/termux.properties" "^allow-external-apps = true"
    cleanup_sandbox "$sb"
}
it "allow-external-apps 주석을 해제한다" _test_props_uncomments_allow_external

_test_props_idempotent() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    # 이미 설정된 상태
    echo "allow-external-apps = true" >> "${HOME}/.termux/termux.properties"
    echo "bell-character = ignore" >> "${HOME}/.termux/termux.properties"

    _setup_termux_properties

    # 중복 없이 1번만 존재해야 함
    local count
    count=$(grep -c "^allow-external-apps = true" "${HOME}/.termux/termux.properties")
    assert_eq "1" "$count" "멱등성: allow-external-apps가 1번만 있어야 한다"
    cleanup_sandbox "$sb"
}
it "멱등성 — 이미 설정된 경우 중복 추가하지 않는다" _test_props_idempotent

_test_props_appends_when_no_comment() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    # 주석 라인 없이 빈 properties 파일
    echo "# 임의 설정" > "${HOME}/.termux/termux.properties"

    _setup_termux_properties
    assert_file_contains "${HOME}/.termux/termux.properties" "^allow-external-apps = true"
    assert_file_contains "${HOME}/.termux/termux.properties" "^bell-character = ignore"
    cleanup_sandbox "$sb"
}
it "주석 라인 없으면 직접 추가한다 (폴백)" _test_props_appends_when_no_comment

# =============================================================================
# _setup_aliases
# =============================================================================

describe "termux_env — _setup_aliases"

_test_aliases_written() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_aliases
    assert_file_contains "${PREFIX}/etc/bash.bashrc" "termux-xfce-aliases"
    assert_file_contains "${PREFIX}/etc/bash.bashrc" "alias ll="
    assert_file_contains "${PREFIX}/etc/bash.bashrc" "alias shutdown="
    cleanup_sandbox "$sb"
}
it "bash.bashrc에 alias 블록을 추가한다" _test_aliases_written

_test_aliases_idempotent() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_aliases
    _setup_aliases  # 두 번 호출

    local count
    count=$(grep -c "termux-xfce-aliases" "${PREFIX}/etc/bash.bashrc")
    assert_eq "1" "$count" "멱등성: alias 블록이 1번만 있어야 한다"
    cleanup_sandbox "$sb"
}
it "멱등성 — alias 블록이 중복 추가되지 않는다" _test_aliases_idempotent

# =============================================================================
# _setup_locale
# =============================================================================

describe "termux_env — _setup_locale"

_test_locale_written() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_locale
    assert_file_contains "${PREFIX}/etc/bash.bashrc" "termux-xfce-locale"
    assert_file_contains "${PREFIX}/etc/bash.bashrc" "LANG=ko_KR.UTF-8"
    assert_file_contains "${PREFIX}/etc/bash.bashrc" "XDG_CONFIG_HOME"
    cleanup_sandbox "$sb"
}
it "bash.bashrc에 locale 환경변수를 추가한다" _test_locale_written

_test_locale_idempotent() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_locale
    _setup_locale

    local count
    count=$(grep -c "termux-xfce-locale" "${PREFIX}/etc/bash.bashrc")
    assert_eq "1" "$count" "멱등성: locale 블록이 1번만 있어야 한다"
    cleanup_sandbox "$sb"
}
it "멱등성 — locale 블록이 중복 추가되지 않는다" _test_locale_idempotent

_test_locale_nimf_env_guarded() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_locale
    assert_file_not_contains "${PREFIX}/etc/bash.bashrc" "command -v nimf"
    assert_file_not_contains "${PREFIX}/etc/bash.bashrc" "^export GTK_IM_MODULE=nimf"
    cleanup_sandbox "$sb"
}
it "locale setup leaves input-method selection to its managed profile" _test_locale_nimf_env_guarded

# =============================================================================
# _setup_start_xfce
# =============================================================================

describe "termux_env — _setup_start_xfce"

_test_startxfce_created() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_start_xfce
    assert_file_exists "${HOME}/.shortcuts/startXFCE"
    # 실행 권한 확인
    [ -x "${HOME}/.shortcuts/startXFCE" ]
    cleanup_sandbox "$sb"
}
it "startXFCE 스크립트를 생성한다" _test_startxfce_created

_test_startxfce_has_gpu_detection() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_start_xfce
    assert_file_contains "${HOME}/.shortcuts/startXFCE" "GPU_MODEL"
    assert_file_contains "${HOME}/.shortcuts/startXFCE" "MESA_LOADER_DRIVER_OVERRIDE"
    assert_file_contains "${HOME}/.shortcuts/startXFCE" "kgsl"
    cleanup_sandbox "$sb"
}
it "startXFCE에 GPU 자동 감지 로직이 있다" _test_startxfce_has_gpu_detection

_test_startxfce_overwrites_on_update() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    # 구버전 startXFCE
    echo "old_version" > "${HOME}/.shortcuts/startXFCE"

    _setup_start_xfce

    # 새 내용으로 덮어씀 (가드 없음 — 업데이트 보장)
    assert_file_contains "${HOME}/.shortcuts/startXFCE" "_kill_display_session"
    cleanup_sandbox "$sb"
}
it "startXFCE를 항상 최신 버전으로 재생성한다" _test_startxfce_overwrites_on_update

# =============================================================================
# _setup_prun
# =============================================================================

describe "termux_env — _setup_prun"

_test_prun_created() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_prun
    assert_file_exists "${PREFIX}/bin/prun"
    [ -x "${PREFIX}/bin/prun" ]
    cleanup_sandbox "$sb"
}
it "prun 스크립트를 생성한다" _test_prun_created

_test_prun_has_config_source() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_prun
    assert_file_contains "${PREFIX}/bin/prun" "CONFIG"
    assert_file_contains "${PREFIX}/bin/prun" "proot-distro login"
    cleanup_sandbox "$sb"
}
it "prun은 config에서 DISTRO를 읽는다" _test_prun_has_config_source

_test_prun_overwrites_old_version() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    echo "old_version" > "${PREFIX}/bin/prun"
    _setup_prun

    # 최신 내용으로 갱신됨 (가드 없음 — test_prun_ld_preload.sh와 일관)
    assert_file_contains "${PREFIX}/bin/prun" "proot-distro login"
    cleanup_sandbox "$sb"
}
it "prun을 항상 최신 버전으로 재생성한다" _test_prun_overwrites_old_version

# =============================================================================
# _setup_cp2menu
# =============================================================================

describe "termux_env — _setup_cp2menu"

_test_cp2menu_created() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_cp2menu
    assert_file_exists "${PREFIX}/bin/cp2menu"
    assert_file_exists "${PREFIX}/share/applications/cp2menu.desktop"
    cleanup_sandbox "$sb"
}
it "cp2menu 스크립트와 desktop 파일을 생성한다" _test_cp2menu_created

_test_cp2menu_desktop_valid() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_cp2menu
    assert_file_contains "${PREFIX}/share/applications/cp2menu.desktop" "[Desktop Entry]"
    assert_file_contains "${PREFIX}/share/applications/cp2menu.desktop" "Exec=cp2menu"
    cleanup_sandbox "$sb"
}
it "cp2menu.desktop에 필수 필드가 있다" _test_cp2menu_desktop_valid

# =============================================================================
# _setup_kill_display — bin 생성 및 desktop entry
# =============================================================================

describe "termux_env — _setup_kill_display"

_test_kill_display_created() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_kill_display 2>/dev/null || true

    assert_file_exists "${PREFIX}/bin/kill_display_session"
    assert_file_exists "${PREFIX}/share/applications/kill_display_session.desktop"
    cleanup_sandbox "$sb"
}
it "kill_display_session 스크립트와 desktop 파일을 생성한다" _test_kill_display_created

_test_kill_display_always_regenerated() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_kill_display 2>/dev/null || true
    local mtime1; mtime1=$(stat -c %Y "${PREFIX}/bin/kill_display_session")
    sleep 1
    _setup_kill_display 2>/dev/null || true
    local mtime2; mtime2=$(stat -c %Y "${PREFIX}/bin/kill_display_session")

    assert_ne "$mtime1" "$mtime2" "항상 재생성되어야 한다"
    cleanup_sandbox "$sb"
}
it "kill_display_session을 항상 최신 버전으로 재생성한다" _test_kill_display_always_regenerated

# =============================================================================
# _migrate_desktop_to_prun_gui — 기존 prun → prun-gui 마이그레이션
# =============================================================================

describe "termux_env — _migrate_desktop_to_prun_gui"

_test_migrate_prun_to_prun_gui() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    # prun 사용하는 .desktop 파일 생성
    cat > "${PREFIX}/share/applications/testapp.desktop" << 'EOF'
[Desktop Entry]
Name=TestApp
Exec=bash -c "prun testapp --flag </dev/null >/dev/null 2>&1 &"
EOF

    cp "${PREFIX}/share/applications/testapp.desktop" "$HOME/Desktop/testapp.desktop"
    _migrate_desktop_to_prun_gui

    assert_file_contains "$HOME/Desktop/testapp.desktop" 'prun-gui "TestApp" --'
    assert_file_contains "${PREFIX}/share/applications/testapp.desktop" 'prun-gui "TestApp" --'
    cleanup_sandbox "$sb"
}
it "prun 사용 .desktop 파일을 prun-gui로 변환한다" _test_migrate_prun_to_prun_gui

_test_migrate_skips_already_prun_gui() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    # 이미 prun-gui 사용 중인 .desktop
    cat > "${PREFIX}/share/applications/already.desktop" << 'EOF'
[Desktop Entry]
Name=Already
Exec=bash -c "prun-gui Already -- someapp </dev/null >/dev/null 2>&1 &"
EOF

    _migrate_desktop_to_prun_gui

    local count
    count=$(grep -c "prun-gui" "${PREFIX}/share/applications/already.desktop")
    assert_eq "1" "$count" "멱등성: prun-gui가 1번만 있어야 한다"
    cleanup_sandbox "$sb"
}
it "멱등성 — 이미 prun-gui인 파일은 건너뛴다" _test_migrate_skips_already_prun_gui

_test_migrate_skips_non_proot() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    # prun을 사용하지 않는 native .desktop
    cat > "${PREFIX}/share/applications/native.desktop" << 'EOF'
[Desktop Entry]
Name=NativeApp
Exec=firefox
EOF

    _migrate_desktop_to_prun_gui

    assert_file_contains "${PREFIX}/share/applications/native.desktop" "^Exec=firefox"
    cleanup_sandbox "$sb"
}
it "prun 미사용 .desktop 파일은 건드리지 않는다" _test_migrate_skips_non_proot

_test_migrate_uses_name_field() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    cat > "${PREFIX}/share/applications/named.desktop" << 'EOF'
[Desktop Entry]
Name=LibreOffice Writer
Exec=bash -c "prun libreoffice --writer </dev/null >/dev/null 2>&1 &"
EOF

    _migrate_desktop_to_prun_gui

    assert_file_contains "${PREFIX}/share/applications/named.desktop" 'prun-gui "LibreOffice Writer" --'
    cleanup_sandbox "$sb"
}
it "Name= 필드를 prun-gui 앱 이름으로 사용한다" _test_migrate_uses_name_field

_test_migrate_no_name_field_does_not_abort() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    # Name= 필드가 없는 .desktop — grep -m1 '^Name=' 이 매치 없어 exit 1 반환 →
    # pipefail 하에서 전체 마이그레이션이 중단되면 안 됨 (기본값 "App"으로 처리)
    cat > "${PREFIX}/share/applications/noname.desktop" << 'EOF'
[Desktop Entry]
Exec=bash -c "prun noname </dev/null >/dev/null 2>&1 &"
EOF

    _migrate_desktop_to_prun_gui

    assert_file_contains "${PREFIX}/share/applications/noname.desktop" 'prun-gui "App" --'
    cleanup_sandbox "$sb"
}
it "Name= 없는 .desktop도 중단 없이 'App' 기본값으로 마이그레이션된다" _test_migrate_no_name_field_does_not_abort

# =============================================================================
# _append_to_rc — RC 파일 멱등 추가 유틸
# =============================================================================

describe "termux_env — _append_to_rc"

_test_append_to_rc_adds_content() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _append_to_rc "# test-marker" "# test-marker\nexport FOO=bar" "${PREFIX}/etc/bash.bashrc"
    assert_file_contains "${PREFIX}/etc/bash.bashrc" "test-marker"
    cleanup_sandbox "$sb"
}
it "마커가 없으면 내용을 추가한다" _test_append_to_rc_adds_content

_test_append_to_rc_idempotent() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _append_to_rc "# test-marker" "# test-marker\nexport FOO=bar" "${PREFIX}/etc/bash.bashrc"
    _append_to_rc "# test-marker" "# test-marker\nexport FOO=bar" "${PREFIX}/etc/bash.bashrc"

    local count
    count=$(grep -c "test-marker" "${PREFIX}/etc/bash.bashrc")
    assert_eq "1" "$count"
    cleanup_sandbox "$sb"
}
it "멱등성 — 마커가 이미 있으면 중복 추가하지 않는다" _test_append_to_rc_idempotent

_test_append_to_rc_returns_zero_when_file_absent() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    local missing="${sb}/does_not_exist.rc"

    # 존재하지 않는 파일 — silent return 0 (set -e 트립 안됨)
    set -e
    _append_to_rc "# m" "# m\nexport X=1" "$missing"
    local rc=$?
    set +e

    assert_eq "0" "$rc"
    [ ! -f "$missing" ]  # 파일이 새로 생성되어서도 안됨
    cleanup_sandbox "$sb"
}
it "파일이 없으면 0 반환 + 새로 생성하지 않는다" _test_append_to_rc_returns_zero_when_file_absent

# =============================================================================
# _rc_targets — zsh 존재 여부에 따른 RC 파일 목록
# =============================================================================

describe "termux_env — _rc_targets"

_test_rc_targets_returns_bashrc_only_when_no_zshrc() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    rm -f "$HOME/.zshrc"

    local out; out=$(_rc_targets)
    [[ "$out" == *"bash.bashrc"* ]]
    [[ "$out" != *".zshrc"* ]]
    cleanup_sandbox "$sb"
}
it ".zshrc가 없으면 bash.bashrc만 반환" _test_rc_targets_returns_bashrc_only_when_no_zshrc

_test_rc_targets_includes_zshrc_when_zsh_present() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    touch "$HOME/.zshrc"
    # zsh가 PATH에 있는 것처럼 mock
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "zsh" ]; then return 0; fi
        builtin command "$@"
    }

    local out; out=$(_rc_targets)
    [[ "$out" == *"bash.bashrc"* ]]
    [[ "$out" == *".zshrc"* ]]
    cleanup_sandbox "$sb"
}
it "zsh + .zshrc 둘 다 있으면 양쪽 모두 반환" _test_rc_targets_includes_zshrc_when_zsh_present

# =============================================================================
# _setup_xdg_runtime — XDG_RUNTIME_DIR mode 700
# =============================================================================

describe "termux_env — _setup_xdg_runtime"

_test_xdg_runtime_written() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_xdg_runtime
    assert_file_contains "${PREFIX}/etc/bash.bashrc" "termux-xfce-xdg-runtime"
    assert_file_contains "${PREFIX}/etc/bash.bashrc" "XDG_RUNTIME_DIR"
    assert_file_contains "${PREFIX}/etc/bash.bashrc" "chmod 700"
    cleanup_sandbox "$sb"
}
it "bash.bashrc에 XDG_RUNTIME_DIR 블록을 추가한다" _test_xdg_runtime_written

_test_xdg_runtime_idempotent() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_xdg_runtime
    _setup_xdg_runtime

    local count
    count=$(grep -c "termux-xfce-xdg-runtime" "${PREFIX}/etc/bash.bashrc")
    assert_eq "1" "$count"
    cleanup_sandbox "$sb"
}
it "멱등성 — XDG_RUNTIME_DIR 블록이 중복 추가되지 않는다" _test_xdg_runtime_idempotent

_test_xdg_runtime_removes_old_tmpdir_line() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    # 구버전 라인 삽입 (마이그레이션 대상)
    echo 'export XDG_RUNTIME_DIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"' >> "${PREFIX}/etc/bash.bashrc"

    _setup_xdg_runtime

    assert_file_not_contains "${PREFIX}/etc/bash.bashrc" 'XDG_RUNTIME_DIR="${TMPDIR'
    assert_file_contains "${PREFIX}/etc/bash.bashrc" "termux-xfce-xdg-runtime"
    cleanup_sandbox "$sb"
}
it "구버전 TMPDIR 기반 XDG_RUNTIME_DIR 라인을 제거한다" _test_xdg_runtime_removes_old_tmpdir_line

# =============================================================================
# _setup_zsh_p10k — zsh/p10k/plugins 설치 + ~/.zshrc 관리
# =============================================================================

describe "termux_env — _setup_zsh_p10k"

_test_zsh_p10k_clone_failure_skips_chsh() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "zsh" ]; then echo "/usr/bin/zsh"; return 0; fi
        builtin command "$@"
    }
    local chsh_log="${sb}/chsh.log"
    chsh() { echo "chsh $*" >> "$chsh_log"; }
    _GIT_FAIL=1
    git() {
        [ "${_GIT_FAIL:-0}" = "1" ] && return 1
        mkdir -p "${@: -1}"
    }

    local rc=0
    _setup_zsh_p10k || rc=$?
    assert_eq "0" "$rc"
    [ ! -s "$chsh_log" ]
    [ ! -f "$HOME/.zshrc" ]
    cleanup_sandbox "$sb"
}
it "p10k clone 실패 시 chsh를 건너뛰고 rc 0" _test_zsh_p10k_clone_failure_skips_chsh

_test_zsh_p10k_fresh_creates_zshrc_then_chsh() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "zsh" ]; then echo "/usr/bin/zsh"; return 0; fi
        builtin command "$@"
    }
    local chsh_log="${sb}/chsh.log"
    chsh() { echo "chsh $*" >> "$chsh_log"; }
    git() {
        [ "${_GIT_FAIL:-0}" = "1" ] && return 1
        mkdir -p "${@: -1}"
    }
    rm -f "$HOME/.zshrc"

    _setup_zsh_p10k
    assert_file_contains "$HOME/.zshrc" "powerlevel10k.zsh-theme"
    [ -s "$chsh_log" ]
    cleanup_sandbox "$sb"
}
it "신규: .zshrc 생성 후 chsh" _test_zsh_p10k_fresh_creates_zshrc_then_chsh

_test_zsh_p10k_existing_zshrc_gets_p10k_block() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "zsh" ]; then echo "/usr/bin/zsh"; return 0; fi
        builtin command "$@"
    }
    local chsh_log="${sb}/chsh.log"
    chsh() { echo "chsh $*" >> "$chsh_log"; }
    git() {
        [ "${_GIT_FAIL:-0}" = "1" ] && return 1
        mkdir -p "${@: -1}"
    }
    echo "# my zshrc" > "$HOME/.zshrc"

    _setup_zsh_p10k
    assert_file_contains "$HOME/.zshrc" "# my zshrc"
    assert_file_contains "$HOME/.zshrc" "# termux-xfce-p10k"
    assert_file_contains "$HOME/.zshrc" "powerlevel10k.zsh-theme"
    assert_file_not_contains "$HOME/.zshrc" "HISTFILE"
    [ -s "$chsh_log" ]
    cleanup_sandbox "$sb"
}
it "기존 .zshrc 보존 + p10k 블록 추가" _test_zsh_p10k_existing_zshrc_gets_p10k_block

_test_zsh_p10k_idempotent_on_existing_zshrc() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "zsh" ]; then echo "/usr/bin/zsh"; return 0; fi
        builtin command "$@"
    }
    chsh() { :; }
    git() {
        [ "${_GIT_FAIL:-0}" = "1" ] && return 1
        mkdir -p "${@: -1}"
    }
    echo "# my zshrc" > "$HOME/.zshrc"

    _setup_zsh_p10k
    _setup_zsh_p10k

    local count
    count=$(grep -c "# termux-xfce-p10k" "$HOME/.zshrc")
    assert_eq "1" "$count"
    cleanup_sandbox "$sb"
}
it "기존 .zshrc에 재실행해도 p10k 블록은 1회" _test_zsh_p10k_idempotent_on_existing_zshrc

_test_zsh_p10k_plugin_failure_continues() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "zsh" ]; then echo "/usr/bin/zsh"; return 0; fi
        builtin command "$@"
    }
    local chsh_log="${sb}/chsh.log"
    chsh() { echo "chsh $*" >> "$chsh_log"; }
    git() {
        local last="${@: -1}"
        if [[ "$last" == *"plugins/"* ]]; then return 1; fi
        mkdir -p "$last"
    }
    rm -f "$HOME/.zshrc"

    local rc=0
    _setup_zsh_p10k || rc=$?
    assert_eq "0" "$rc"
    assert_file_exists "$HOME/.zshrc"
    [ -s "$chsh_log" ]
    cleanup_sandbox "$sb"
}
it "플러그인 clone 실패는 경고 후 계속" _test_zsh_p10k_plugin_failure_continues

# =============================================================================
# _setup_prun_gui — prun-gui 스크립트 생성
# =============================================================================

describe "termux_env — _setup_prun_gui"

_test_prun_gui_created() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_prun_gui
    assert_file_exists "${PREFIX}/bin/prun-gui"
    [ -x "${PREFIX}/bin/prun-gui" ]
    assert_file_contains "${PREFIX}/bin/prun-gui" "notify-send"
    assert_file_contains "${PREFIX}/bin/prun-gui" "exec prun"
    cleanup_sandbox "$sb"
}
it "prun-gui 스크립트를 생성한다" _test_prun_gui_created

_test_prun_gui_syntax_valid() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_prun_gui
    bash -n "${PREFIX}/bin/prun-gui"
    cleanup_sandbox "$sb"
}
it "prun-gui 스크립트의 bash 문법 오류가 없다" _test_prun_gui_syntax_valid

# =============================================================================
# _setup_app_installer — bin + desktop + 바탕화면 아이콘
# =============================================================================

describe "termux_env — _setup_app_installer"

_test_app_installer_created() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    export SCRIPT_DIR="${_REAL_PROJECT_DIR}"

    _setup_app_installer
    assert_file_exists "${PREFIX}/bin/app-installer"
    assert_file_exists "${PREFIX}/share/applications/app-installer.desktop"
    assert_file_exists "${HOME}/Desktop/App-Installer.desktop"
    [ -x "${PREFIX}/bin/app-installer" ]
    cleanup_sandbox "$sb"
}
it "app-installer bin, desktop, 바탕화면 아이콘을 생성한다" _test_app_installer_created

_test_app_installer_always_regenerated() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    export SCRIPT_DIR="${_REAL_PROJECT_DIR}"

    _setup_app_installer
    local mtime1; mtime1=$(stat -c %Y "${PREFIX}/bin/app-installer")
    sleep 1
    _setup_app_installer
    local mtime2; mtime2=$(stat -c %Y "${PREFIX}/bin/app-installer")

    assert_ne "$mtime1" "$mtime2" "bin은 항상 재생성되어야 한다 (SCRIPT_DIR 변경 반영)"
    cleanup_sandbox "$sb"
}
it "app-installer bin을 항상 최신 버전으로 재생성한다" _test_app_installer_always_regenerated

# =============================================================================
# _install_base_packages — 패키지 설치 루프
# =============================================================================

describe "termux_env — _install_base_packages"

_test_base_pkgs_installs_missing() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    reset_mock_calls
    MOCK_INSTALLED_PKGS=""

    _install_base_packages 2>/dev/null || true
    assert_was_called "pkg_install"
    assert_was_called "pkg_install zenity"
    cleanup_sandbox "$sb"
}
it "미설치 패키지에 대해 pkg_install을 호출한다" _test_base_pkgs_installs_missing

_test_base_pkgs_skips_installed() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    reset_mock_calls
    # XFCE도 이미 설치된 상태 (Stage 6→Stage 7 같은 idempotent 재실행 시뮬레이션)
    MOCK_INSTALLED_PKGS="${PKGS_TERMUX_BASE[*]} ${PKGS_TERMUX_CLI[*]} ${PKGS_TERMUX_PROOT[*]} dbus xfce4-session"

    _install_base_packages 2>/dev/null || true
    # XFCE 존재 시 dbus 제거 안 함 → cascade 제거 차단 → 모든 pkg가 skip
    local install_count=0
    for call in "${MOCK_CALLS[@]:-}"; do
        [[ "$call" == pkg_install* ]] && ((install_count++))
    done
    [ "$install_count" -eq 0 ]
    cleanup_sandbox "$sb"
}
it "멱등성 — 이미 설치된 패키지는 건너뛴다 (XFCE 있으면 dbus도 보존)" _test_base_pkgs_skips_installed

_test_base_pkgs_dbus_preserved_without_xfce() {
    # XFCE가 없어도 사용자가 설치한 다른 앱이 dbus에 의존할 수 있다.
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    reset_mock_calls
    MOCK_INSTALLED_PKGS="dbus fcitx5"

    _install_base_packages 2>/dev/null || true
    assert_not_called "pkg_remove dbus"
    assert_not_called "pkg_install dbus"
    cleanup_sandbox "$sb"
}
it "XFCE 첫 설치에서도 기존 dbus와 의존 앱을 보존한다" _test_base_pkgs_dbus_preserved_without_xfce

_test_base_pkgs_dbus_preserved_when_xfce_installed() {
    # 회귀: Stage 7 같은 멱등 재실행에서 dbus 제거 → 64개 cascade 제거 방지
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    reset_mock_calls
    MOCK_INSTALLED_PKGS="dbus xfce4-session fcitx5"

    _install_base_packages 2>/dev/null || true
    assert_not_called "pkg_remove dbus"
    cleanup_sandbox "$sb"
}
it "XFCE 설치된 idempotent 재실행에서는 dbus를 보존한다 (cascade 제거 차단)" _test_base_pkgs_dbus_preserved_when_xfce_installed

_test_base_pkgs_preserves_running_dbus_files() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    reset_mock_calls
    MOCK_INSTALLED_PKGS="dbus"
    mkdir -p "$HOME/.dbus/session-bus" "$PREFIX/tmp"
    printf 'active socket\n' > "$PREFIX/tmp/dbus-existing"
    printf 'active address\n' > "$HOME/.dbus/session-bus/existing"

    _install_base_packages 2>/dev/null || true
    assert_file_contains "$PREFIX/tmp/dbus-existing" '^active socket$'
    assert_file_contains "$HOME/.dbus/session-bus/existing" '^active address$'
    [ ! -e "$HOME/.config/termux-xfce/.dbus-reset-done" ]
    cleanup_sandbox "$sb"
}
it "기본 패키지 설치는 실행 중인 DBus 세션 파일을 건드리지 않는다" _test_base_pkgs_preserves_running_dbus_files

_test_base_pkgs_dbus_preserved_across_retries() {
    # 설치가 XFCE 패키지를 설치하기 전에 중단된 경우도 두 실행 모두 안전해야 한다.
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    reset_mock_calls
    MOCK_INSTALLED_PKGS="dbus"   # dbus만 잔존 (xfce4-session 없음)

    _install_base_packages
    assert_not_called "pkg_remove dbus"
    reset_mock_calls
    MOCK_INSTALLED_PKGS="dbus"   # 여전히 xfce4-session 없음

    _install_base_packages
    assert_not_called "pkg_remove dbus"
    cleanup_sandbox "$sb"
}
it "XFCE 설치 전 중단 후 재실행에서도 기존 dbus를 보존한다" _test_base_pkgs_dbus_preserved_across_retries

# =============================================================================
# setup_termux_shortcuts — composition 함수 검증
# =============================================================================

describe "termux_env — setup_termux_shortcuts (composition)"

_test_shortcuts_creates_all() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    export SCRIPT_DIR="${_REAL_PROJECT_DIR}"

    setup_termux_shortcuts 2>/dev/null || true

    assert_file_exists "${HOME}/.shortcuts/startXFCE"
    assert_file_exists "${PREFIX}/bin/prun"
    assert_file_exists "${PREFIX}/bin/prun-gui"
    assert_file_exists "${PREFIX}/bin/cp2menu"
    assert_file_exists "${PREFIX}/bin/kill_display_session"
    assert_file_exists "${PREFIX}/bin/app-installer"
    assert_file_exists "${PREFIX}/bin/screenshot"
    cleanup_sandbox "$sb"
}
it "모든 유틸리티 스크립트를 생성한다" _test_shortcuts_creates_all

# =============================================================================
# 회귀: set -e + ((i++)) 폭탄 (i=0 시작 카운터)
# i++는 *증가 전* 값을 종료코드로 반환하므로 i=0이면 exit 1 → set -e가 첫
# 반복에서 스크립트를 즉시 죽인다. 기존 테스트들은 모두 `|| true`로 가려져
# 있어 이 버그를 잡지 못했음. 새 테스트는 `|| true` 없이 호출하여 함수가
# 끝까지 실행되는지를 직접 검증한다.
# =============================================================================

describe "termux_env — set -e safe counter (regression)"

_test_install_base_packages_completes_under_set_e() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    reset_mock_calls
    MOCK_INSTALLED_PKGS=""
    export PROOT_DISTRO="archlinux" SKIP_PROOT=false

    # || true 없이 직접 호출 — set -e 하에서 첫 반복부터 끝까지 가야 함
    _install_base_packages

    # 모든 패키지에 대해 pkg_install이 호출되었는지 (루프가 끝까지 돌았다는 증거)
    local total=$((${#PKGS_TERMUX_BASE[@]} + ${#PKGS_TERMUX_CLI[@]} + ${#PKGS_TERMUX_PROOT[@]}))
    local install_count=0
    for call in "${MOCK_CALLS[@]:-}"; do
        [[ "$call" == pkg_install* ]] && install_count=$((install_count + 1))
    done
    [ "$install_count" -eq "$total" ]
    cleanup_sandbox "$sb"
}
it "_install_base_packages가 set -e 하에서 끝까지 실행된다" _test_install_base_packages_completes_under_set_e

# =============================================================================
# display_setup_apk — 아키텍처 분기 + 멱등성 + 폴백
# =============================================================================

describe "display_x11 — display_setup_apk"

# Termux 출처(TERMUX_APK_RELEASE)와 일반판 Termux:X11 설치 여부를 고정한 채 실행
_run_apk_setup() {
    local release="$1" regular="$2"
    _termux_x11_regular_installed() { [ "$regular" = yes ]; }
    TERMUX_APK_RELEASE="$release" display_setup_apk
}

_test_x11_apk_github_uses_shared_uid() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    termux-open() { _record_call "termux-open $*"; }
    reset_mock_calls

    _run_apk_setup GITHUB no

    assert_was_called "wget"
    assert_was_called "termux-x11-universal-sharedUid-debug.apk"
    cleanup_sandbox "$sb"
}
it "GitHub판 Termux는 큰 코어를 쓰게 하는 sharedUid universal APK를 받는다" _test_x11_apk_github_uses_shared_uid

_test_x11_apk_fdroid_uses_regular() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    termux-open() { :; }
    reset_mock_calls

    _run_apk_setup F_DROID no

    assert_was_called "termux-x11-universal-debug.apk"
    assert_not_called "sharedUid"
    cleanup_sandbox "$sb"
}
it "F-Droid판 Termux는 서명이 달라 일반 universal APK를 받는다" _test_x11_apk_fdroid_uses_regular

_test_x11_apk_github_with_regular_installed_updates_regular() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    termux-open() { :; }
    reset_mock_calls

    _run_apk_setup GITHUB yes

    # 일반판 위에는 sharedUid 판을 덮어 설치할 수 없으므로 일반판을 갱신하고 전환 방법을 알린다
    assert_was_called "termux-x11-universal-debug.apk"
    assert_not_called "sharedUid-debug.apk"
    assert_output_contains "${UI_OUTPUT[*]:-}" "sharedUid"
    cleanup_sandbox "$sb"
}
it "일반판이 설치돼 있으면 일반판을 갱신하고 sharedUid 판 전환 방법을 안내한다" _test_x11_apk_github_with_regular_installed_updates_regular

_test_x11_apk_idempotent_when_present() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    # 이미 다운로드된 상태
    printf 'PKmock\n' > "$HOME/storage/downloads/termux-x11-universal-debug.apk"
    termux-open() { _record_call "termux-open $*"; }
    reset_mock_calls

    _run_apk_setup F_DROID no

    assert_not_called "wget"
    assert_was_called "termux-open"
    cleanup_sandbox "$sb"
}
it "APK가 이미 있으면 wget 건너뛰고 termux-open만 호출" _test_x11_apk_idempotent_when_present

_test_x11_apk_replaces_invalid_existing_file() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    printf 'broken\n' > "$HOME/storage/downloads/termux-x11-universal-debug.apk"
    termux-open() { _record_call "termux-open $*"; }
    reset_mock_calls

    _run_apk_setup F_DROID no

    assert_was_called "wget"
    assert_output_contains "$(head -c 2 "$HOME/storage/downloads/termux-x11-universal-debug.apk")" "PK"
    cleanup_sandbox "$sb"
}
it "손상된 기존 APK는 다시 다운로드한다" _test_x11_apk_replaces_invalid_existing_file

_test_x11_apk_falls_back_to_home_when_no_storage() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    # storage/downloads 없음 → HOME으로 폴백
    [ ! -d "$HOME/storage/downloads" ]
    termux-open() { _record_call "termux-open $*"; }
    reset_mock_calls

    _run_apk_setup F_DROID no

    # HOME에 검증된 APK가 생성되어야 함
    assert_file_exists "$HOME/termux-x11-universal-debug.apk"
    cleanup_sandbox "$sb"
}
it "storage/downloads 없을 때 HOME으로 폴백" _test_x11_apk_falls_back_to_home_when_no_storage

# =============================================================================
# setup_termux_widget — 사전 조건 + 디렉터리 생성
# =============================================================================

describe "termux_env — setup_termux_widget"

_test_widget_creates_shortcuts_dir() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    rm -rf "$HOME/.shortcuts"
    termux-open() { :; }

    setup_termux_widget

    assert_dir_exists "$HOME/.shortcuts"
    cleanup_sandbox "$sb"
}
it ".shortcuts 디렉터리가 없으면 생성한다" _test_widget_creates_shortcuts_dir

_test_widget_warns_when_startxfce_missing() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads" "$HOME/.shortcuts"
    # startXFCE 단축키 부재
    termux-open() { :; }
    reset_ui_output

    setup_termux_widget

    assert_ui_contains "startXFCE 단축키가 없습니다"
    cleanup_sandbox "$sb"
}
it "startXFCE 단축키 누락 시 경고 출력" _test_widget_warns_when_startxfce_missing

_test_widget_no_warn_when_startxfce_present() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads" "$HOME/.shortcuts"
    touch "$HOME/.shortcuts/startXFCE"
    termux-open() { :; }
    reset_ui_output

    setup_termux_widget

    # startXFCE 경고가 없어야 함
    for msg in "${UI_OUTPUT[@]:-}"; do
        if [[ "$msg" == *"startXFCE 단축키가 없습니다"* ]]; then
            echo "[ASSERT] unexpected startXFCE warning: $msg" >&2
            return 1
        fi
    done
    cleanup_sandbox "$sb"
}
it "startXFCE 단축키 존재 시 경고 안나옴" _test_widget_no_warn_when_startxfce_present

# =============================================================================
# setup_termux_boot_apk — Termux:Boot APK + 부팅 스크립트
# =============================================================================

describe "termux_env — setup_termux_boot_apk"

_test_boot_creates_boot_script() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    termux-open() { :; }

    setup_termux_boot_apk

    assert_dir_exists "$HOME/.termux/boot"
    assert_file_exists "$HOME/.termux/boot/start-services"
    assert_file_contains "$HOME/.termux/boot/start-services" "start-services.sh"
    cleanup_sandbox "$sb"
}
it "부팅 스크립트 ~/.termux/boot/start-services 를 생성한다" _test_boot_creates_boot_script

_test_boot_script_is_executable() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    termux-open() { :; }

    setup_termux_boot_apk

    [ -x "$HOME/.termux/boot/start-services" ] || {
        echo "[ASSERT] 부팅 스크립트에 실행 권한 없음" >&2; return 1
    }
    cleanup_sandbox "$sb"
}
it "부팅 스크립트에 실행 권한이 있다" _test_boot_script_is_executable

_test_boot_script_preserves_user_edits() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads" "$HOME/.termux/boot"
    printf '%s\n' '# user customised' > "$HOME/.termux/boot/start-services"
    termux-open() { :; }

    setup_termux_boot_apk

    assert_file_contains "$HOME/.termux/boot/start-services" "user customised"
    cleanup_sandbox "$sb"
}
it "기존 부팅 스크립트를 덮어쓰지 않는다 (멱등)" _test_boot_script_preserves_user_edits

_test_boot_downloads_apk() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    termux-open() { :; }
    reset_mock_calls

    setup_termux_boot_apk

    assert_was_called "termux-boot.apk"
    cleanup_sandbox "$sb"
}
it "Termux:Boot APK를 내려받는다" _test_boot_downloads_apk

_test_termux_services_in_base_packages() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    grep -qx "termux-services" <<< "$(printf '%s\n' "${PKGS_TERMUX_BASE[@]}")" || {
        echo "[ASSERT] termux-services가 PKGS_TERMUX_BASE에 없음" >&2; return 1
    }
    cleanup_sandbox "$sb"
}
it "termux-services가 기본 패키지에 포함된다" _test_termux_services_in_base_packages

# =============================================================================
# setup_termux_api_apk — APK 다운로드 + 멱등성
# =============================================================================

describe "termux_env — setup_termux_api_apk"

_test_api_apk_downloads() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    termux-open() { _record_call "termux-open $*"; }
    reset_mock_calls

    setup_termux_api_apk

    assert_was_called "wget"
    assert_was_called "termux-api.apk"
    cleanup_sandbox "$sb"
}
it "Termux:API APK를 다운로드한다" _test_api_apk_downloads

_test_api_apk_idempotent() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    printf 'PKmock\n' > "$HOME/storage/downloads/termux-api.apk"
    termux-open() { _record_call "termux-open $*"; }
    reset_mock_calls

    setup_termux_api_apk

    assert_not_called "wget"
    assert_was_called "termux-open"
    cleanup_sandbox "$sb"
}
it "API APK가 이미 있으면 wget 건너뛰고 termux-open만 호출" _test_api_apk_idempotent

# =============================================================================
# setup_termux_float_apk — APK 다운로드 + 멱등성
# =============================================================================

describe "termux_env — setup_termux_float_apk"

_test_float_apk_downloads() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    termux-open() { _record_call "termux-open $*"; }
    reset_mock_calls

    setup_termux_float_apk

    assert_was_called "wget"
    assert_was_called "termux-float.apk"
    cleanup_sandbox "$sb"
}
it "Termux:Float APK를 다운로드한다" _test_float_apk_downloads

_test_float_apk_idempotent() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    mkdir -p "$HOME/storage/downloads"
    printf 'PKmock\n' > "$HOME/storage/downloads/termux-float.apk"
    termux-open() { _record_call "termux-open $*"; }
    reset_mock_calls

    setup_termux_float_apk

    assert_not_called "wget"
    assert_was_called "termux-open"
    cleanup_sandbox "$sb"
}
it "Float APK가 이미 있으면 wget 건너뛰고 termux-open만 호출" _test_float_apk_idempotent

# =============================================================================
# _setup_clipboard_sync — 동기화 스크립트 생성
# =============================================================================

describe "termux_env — _setup_clipboard_sync"

_test_clipboard_sync_creates_script() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_clipboard_sync

    assert_file_exists "$PREFIX/bin/termux-clipboard-sync"
    [ -x "$PREFIX/bin/termux-clipboard-sync" ]
    cleanup_sandbox "$sb"
}
it "termux-clipboard-sync 스크립트를 생성하고 실행 권한을 부여한다" _test_clipboard_sync_creates_script

_test_clipboard_sync_contains_sync_logic() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_clipboard_sync

    local bin="$PREFIX/bin/termux-clipboard-sync"
    grep -q 'termux-clipboard-get' "$bin"
    grep -q 'xclip -selection clipboard' "$bin"
    grep -q 'termux-clipboard-set' "$bin"
    cleanup_sandbox "$sb"
}
it "동기화 스크립트에 양방향 클립보드 로직이 포함된다" _test_clipboard_sync_contains_sync_logic

# =============================================================================
# _setup_screenshot — 세션 인식 스크린샷 래퍼
# =============================================================================

describe "termux_env — _setup_screenshot"

_test_screenshot_creates_executable() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_screenshot

    assert_file_exists "$PREFIX/bin/screenshot"
    [ -x "$PREFIX/bin/screenshot" ]
    bash -n "$PREFIX/bin/screenshot"
    cleanup_sandbox "$sb"
}
it "screenshot 스크립트를 생성하고 실행 권한을 부여한다" _test_screenshot_creates_executable

_test_screenshot_uses_wayland_tool() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"

    _setup_screenshot

    local bin="$PREFIX/bin/screenshot"
    grep -q 'spectacle "$@"' "$bin"
    grep -q 'xfce4-screenshooter' "$bin"
    cleanup_sandbox "$sb"
}
it "Wayland 세션에서는 Spectacle을 실행한다" _test_screenshot_uses_wayland_tool

# =============================================================================
# _setup_termux_repos — 3개 repo + pkg_update
# =============================================================================

describe "termux_env — _setup_termux_repos"

_test_termux_repos_installs_x11_when_absent() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    MOCK_INSTALLED_PKGS=""
    reset_mock_calls

    _setup_termux_repos

    assert_was_called "pkg_install x11-repo"
    assert_not_called "pkg_install tur-repo"
    assert_not_called "pkg_install root-repo"
    assert_was_called "pkg_update"
    cleanup_sandbox "$sb"
}
it "x11-repo 미설치 시 설치 + pkg_update 호출 (tur/root는 app-installer가 온디맨드로 켬)" _test_termux_repos_installs_x11_when_absent

_test_termux_repos_skips_already_installed() {
    local sb; sb=$(make_sandbox)
    _load_domain "$sb"
    MOCK_INSTALLED_PKGS="x11-repo tur-repo root-repo"
    reset_mock_calls

    _setup_termux_repos

    assert_not_called "pkg_install x11-repo"
    assert_not_called "pkg_install tur-repo"
    assert_not_called "pkg_install root-repo"
    # pkg_update는 항상 호출
    assert_was_called "pkg_update"
    cleanup_sandbox "$sb"
}
it "이미 설치된 repo는 건너뛰지만 pkg_update는 호출" _test_termux_repos_skips_already_installed

# (_cleanup_duplicate_fcitx_autostart: 삭제된 함수 — 테스트 제거)

print_results
