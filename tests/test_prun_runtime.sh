#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# TEST: prun 런타임 선택
#   - 기본은 proot-distro, PRUN_RUNTIME=chroot-ng일 때만 chroot-ng로 실행
#   - 실행 시 지정한 PRUN_RUNTIME이 config 값보다 우선
#   - chroot-ng 분기는 proot-distro와 같은 신원·바인드·env를 넘긴다
# 생성된 prun을 실제로 실행하고, chroot-ng/proot-distro 대신 인자를 기록하는 가짜 명령으로 검증한다.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"
source "${SCRIPT_DIR}/mocks.sh"

DOMAIN_DIR="${SCRIPT_DIR}/../domain"
_BASH="${BASH:-$(command -v bash)}"

_setup_runtime() {
    local sb="$1" tool rootfs
    setup_fs_sandbox "$sb"
    mock_pkg_adapter
    mock_ui_adapter
    mock_wget
    source "${DOMAIN_DIR}/packages.sh"
    source "${DOMAIN_DIR}/../adapters/output/script_builder_zenity.sh"
    source "${DOMAIN_DIR}/termux_env.sh"
    _setup_prun

    rootfs="${PREFIX}/var/lib/proot-distro/installed-rootfs/archlinux"
    mkdir -p "$rootfs/etc" "$rootfs/home/testuser"
    echo 'testuser:x:10381:982::/home/testuser:/bin/bash' > "$rootfs/etc/passwd"

    # 받은 인자를 한 줄씩 <sandbox>/<tool>.log에 기록하는 가짜 명령
    for tool in chroot-ng proot-distro; do
        printf '#!%s\nprintf "%%s\\n" "$@" > "%s/%s.log"\n' "$_BASH" "$sb" "$tool" > "${PREFIX}/bin/$tool"
        chmod +x "${PREFIX}/bin/$tool"
    done
    # 기기에 설치된 실제 termux-xfce-hostinfo가 PATH로 잡혀 데몬을 띄우지 않게 막는다
    printf '#!%s\nexit 1\n' "$_BASH" > "${PREFIX}/bin/termux-xfce-hostinfo"
    chmod +x "${PREFIX}/bin/termux-xfce-hostinfo"
}

_run_prun() {
    ( export PATH="${PREFIX}/bin:$PATH"; "$_BASH" "${PREFIX}/bin/prun" "$@" ) 2>&1
}

_assert_log_line() {
    local log="$1" line="$2"
    if ! grep -qxF -- "$line" "$log" 2>/dev/null; then
        echo "[ASSERT] '${log##*/}'에 '${line}' 인자가 없다" >&2
        [ -f "$log" ] && echo "[ASSERT] actual: $(tr '\n' ' ' < "$log")" >&2
        return 1
    fi
}

_assert_not_run() {
    if [ -e "$1" ]; then
        echo "[ASSERT] ${1##*/}가 실행되면 안 된다: $(tr '\n' ' ' < "$1")" >&2
        return 1
    fi
}

describe "prun — 런타임 선택"

_test_default_uses_proot_distro() {
    local sb; sb=$(make_sandbox); _setup_runtime "$sb"
    unset PRUN_RUNTIME
    _run_prun xeyes >/dev/null
    _assert_log_line "$sb/proot-distro.log" "login" && _assert_not_run "$sb/chroot-ng.log"
    local rc=$?; cleanup_sandbox "$sb"; return "$rc"
}
it "PRUN_RUNTIME이 없으면 기존처럼 proot-distro로 실행한다" _test_default_uses_proot_distro

_test_bound_launcher_uses_its_own_target() {
    local sb; sb=$(make_sandbox); _setup_runtime "$sb"
    printf 'PROOT_DISTRO="ubuntu"\nPROOT_USER="alice"\n' > "$HOME/.config/termux-xfce/config"
    PRUN_DISTRO=archlinux PRUN_USER=testuser _run_prun libreoffice 'one argument' >/dev/null
    local log="$sb/proot-distro.log"
    _assert_log_line "$log" archlinux
    _assert_log_line "$log" testuser
    _assert_log_line "$log" 'one argument'
    if grep -qxF alice "$log"; then return 1; fi
    printf 'PROOT_DISTRO=""\nPROOT_USER=""\n' > "$HOME/.config/termux-xfce/config"
    PRUN_DISTRO=archlinux PRUN_USER=testuser _run_prun xeyes >/dev/null
    _assert_log_line "$log" archlinux
    if PRUN_DISTRO=archlinux _run_prun xeyes >/dev/null; then return 1; fi
    cleanup_sandbox "$sb"
}
it '기본 배포판 변경이나 native 전환 뒤에도 런처가 지정한 컨테이너와 사용자를 쓴다' _test_bound_launcher_uses_its_own_target

_test_env_selects_chroot_ng() {
    local sb; sb=$(make_sandbox); _setup_runtime "$sb"
    PRUN_RUNTIME=chroot-ng _run_prun xeyes -geometry 10x10 >/dev/null
    local log="$sb/chroot-ng.log" rc=0 line
    for line in --shared-proc --fake-id=10381:982 /home/testuser "${PREFIX}:${PREFIX}" \
        "${PREFIX}/tmp:/tmp" /sys:/sys HOME=/home/testuser USER=testuser PULSE_SERVER=127.0.0.1 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/games:/usr/games \
        "${PREFIX}/var/lib/proot-distro/installed-rootfs/archlinux" /usr/bin/env --login \
        'exec "$@"' xeyes -geometry 10x10; do
        _assert_log_line "$log" "$line" || rc=1
    done
    _assert_not_run "$sb/proot-distro.log" || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}
it "PRUN_RUNTIME=chroot-ng이면 proot-distro와 같은 신원·바인드·env로 chroot-ng를 실행한다" _test_env_selects_chroot_ng

_test_config_selects_and_env_overrides() {
    local sb; sb=$(make_sandbox); _setup_runtime "$sb"
    echo 'PRUN_RUNTIME="chroot-ng"' >> "${HOME}/.config/termux-xfce/config"
    unset PRUN_RUNTIME
    _run_prun xeyes >/dev/null
    local rc=0
    _assert_log_line "$sb/chroot-ng.log" xeyes || rc=1
    rm -f "$sb/chroot-ng.log"
    PRUN_RUNTIME=proot _run_prun xeyes >/dev/null
    _assert_log_line "$sb/proot-distro.log" login || rc=1
    _assert_not_run "$sb/chroot-ng.log" || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}
it "config의 PRUN_RUNTIME을 따르되, 실행 시 지정한 값이 우선한다" _test_config_selects_and_env_overrides

_test_noarg_login_shell() {
    local sb; sb=$(make_sandbox); _setup_runtime "$sb"
    PRUN_RUNTIME=chroot-ng _run_prun >/dev/null
    local rc=0
    _assert_log_line "$sb/chroot-ng.log" bash && _assert_log_line "$sb/chroot-ng.log" --login || rc=1
    if grep -qxF -- -c "$sb/chroot-ng.log"; then
        echo "[ASSERT] 인자 없는 prun은 대화형 로그인 셸이어야 한다" >&2; rc=1
    fi
    cleanup_sandbox "$sb"; return "$rc"
}
it "인자 없는 prun은 chroot-ng에서도 로그인 셸을 연다" _test_noarg_login_shell

describe "prun — Android Host Info Bridge 연결"

# 실제 갱신 대신 바인드 원본 파일만 만드는 가짜 termux-xfce-hostinfo
_install_fake_hostinfo() {
    local hi="${PREFIX}/tmp/termux-xfce-hostinfo"
    printf '#!%s\nmkdir -p "%s/dmi" && : > "%s/stat" && : > "%s/cpuinfo"\n' \
        "$_BASH" "$hi" "$hi" "$hi" > "${PREFIX}/bin/termux-xfce-hostinfo"
    chmod +x "${PREFIX}/bin/termux-xfce-hostinfo"
}

_test_hostinfo_binds_chroot_ng() {
    local sb; sb=$(make_sandbox); _setup_runtime "$sb"; _install_fake_hostinfo
    PRUN_RUNTIME=chroot-ng _run_prun htop >/dev/null
    local hi="${PREFIX}/tmp/termux-xfce-hostinfo" rc=0 line
    for line in "$hi/stat:/proc/stat" "$hi/cpuinfo:/proc/cpuinfo" "$hi/dmi:/sys/class/dmi/id" \
        "$hi/net:/sys/class/net" "$hi/proc_net:/proc/net"; do
        _assert_log_line "$sb/chroot-ng.log" "$line" || rc=1
    done
    cleanup_sandbox "$sb"; return "$rc"
}
it "chroot-ng에는 /proc/stat·cpuinfo·DMI를 바인드하고, 막힌 /sys/class/net·/proc/net은 netstats 카운터 디렉터리로 가린다" _test_hostinfo_binds_chroot_ng

_test_hostinfo_binds_proot() {
    local sb; sb=$(make_sandbox); _setup_runtime "$sb"; _install_fake_hostinfo
    unset PRUN_RUNTIME
    _run_prun htop >/dev/null
    local hi="${PREFIX}/tmp/termux-xfce-hostinfo" rc=0
    _assert_log_line "$sb/proot-distro.log" --bind || rc=1
    _assert_log_line "$sb/proot-distro.log" "$hi/cpuinfo:/proc/cpuinfo" || rc=1
    # /proc/net/dev 파일 바인드는 self/net 링크 때문에 적용되지 않아 디렉터리째 가린다
    _assert_log_line "$sb/proot-distro.log" "$hi/proc_net:/proc/net" || rc=1
    # /proc/stat은 proot-distro sysdata로 공급한다 — 겹치는 바인드는 실행마다 경고를 낸다
    if grep -qF -- ':/proc/stat' "$sb/proot-distro.log"; then
        echo "[ASSERT] proot-distro에 /proc/stat 바인드를 넘기면 안 된다" >&2; rc=1
    fi
    cleanup_sandbox "$sb"; return "$rc"
}
it "proot에는 기기 정보와 /proc/net(네트워크 카운터)을 바인드하고 /proc/stat은 sysdata로 맡긴다" _test_hostinfo_binds_proot

describe "prun — chroot-ng 실행 전 검사"

_test_missing_binary_fails() {
    local sb; sb=$(make_sandbox); _setup_runtime "$sb"
    rm -f "${PREFIX}/bin/chroot-ng"
    local out rc=0
    out=$(PRUN_RUNTIME=chroot-ng _run_prun xeyes) || rc=$?
    assert_nonzero "$rc" "chroot-ng가 없으면 실패해야 한다" &&
        assert_output_contains "$out" "App Installer" &&
        _assert_not_run "$sb/proot-distro.log"
    rc=$?; cleanup_sandbox "$sb"; return "$rc"
}
it "chroot-ng가 설치되지 않았으면 proot로 조용히 넘어가지 않고 안내와 함께 실패한다" _test_missing_binary_fails

_test_unknown_user_fails() {
    local sb; sb=$(make_sandbox); _setup_runtime "$sb"
    sed -i 's/^PROOT_USER=.*/PROOT_USER="ghost"/' "${HOME}/.config/termux-xfce/config"
    local rc=0
    PRUN_RUNTIME=chroot-ng _run_prun xeyes >/dev/null || rc=$?
    assert_nonzero "$rc" "rootfs에 없는 사용자는 실패해야 한다" && _assert_not_run "$sb/chroot-ng.log"
    rc=$?; cleanup_sandbox "$sb"; return "$rc"
}
it "rootfs /etc/passwd에 없는 사용자면 실행하지 않는다" _test_unknown_user_fails

print_results
