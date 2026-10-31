#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Termux XFCE Desktop Installer
# Hexagonal Architecture: Ports & Adapters
#
# 사용법:
#   curl -sL https://raw.githubusercontent.com/yanghoeg/usix-termux/main/install.sh | bash
#   또는
#   bash install.sh [--distro ubuntu|archlinux] [--user <name>] [--display x11|wayland]
#
# 아키텍처:
#   install.sh  → DI(어댑터 선택) → Domain 실행
#   ports/      → 계약 정의 (pkg_manager, ui, display, script_builder)
#   adapters/   → 구현체 (pkg_termux, pkg_ubuntu, pkg_arch, ui_terminal, ui_zenity, display_x11, display_wayland)
#   domain/     → 비즈니스 로직 (termux_env, xfce_env, proot_env, packages)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# 0. 경로 설정
# -----------------------------------------------------------------------------
_installer_source="${BASH_SOURCE[0]:-}"
if [ -n "$_installer_source" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$_installer_source")")" && pwd)"
else
    SCRIPT_DIR=""
fi
unset _installer_source
export SCRIPT_DIR
ARCH=$(uname -m)

# curl로 직접 실행 시 (파일이 없는 경우) 임시 디렉토리에 클론
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/domain" ]; then
    # Git is not part of a fresh Termux bootstrap. Prepare it before cloning or
    # replacing the checkout used by an existing app-installer command.
    if ! command -v git >/dev/null 2>&1; then
        case "${PREFIX:-}" in
            /data/data/com.termux/files/usr) ;;
            *) echo "[ERROR] Git 설치에는 Android Termux 환경이 필요합니다." >&2; exit 1 ;;
        esac
        echo "[INFO] 저장소 복제에 필요한 Git을 설치합니다..."
        # The package adapter is not loaded yet; skip pkg's mirror test here too
        # (see adapters/output/pkg_common_termux.sh).
        if ! TERMUX_PKG_NO_MIRROR_SELECT=1 pkg install -y -o Dpkg::Options::="--force-confold" git ||
           ! command -v git >/dev/null 2>&1; then
            echo "[ERROR] Git을 준비하지 못했습니다. 네트워크와 패키지 저장소를 확인하세요." >&2
            exit 1
        fi
    fi
    echo "[INFO] 저장소를 클론합니다..."
    local_dir="$HOME/.termux-xfce-installer"
    _bootstrap_stage=$(mktemp -d "${local_dir}.new.XXXXXX")
    _bootstrap_backup=""
    _bootstrap_cleanup() {
        local code=$?
        if [ -n "$_bootstrap_backup" ] && { [ -e "$_bootstrap_backup" ] || [ -L "$_bootstrap_backup" ]; } &&
           [ ! -e "$local_dir" ] && [ ! -L "$local_dir" ]; then
            mv -T -- "$_bootstrap_backup" "$local_dir" || \
                echo "[ERROR] 이전 저장소 복원 실패: $_bootstrap_backup" >&2
        fi
        if [ -n "$_bootstrap_stage" ]; then
            rm -rf -- "$_bootstrap_stage" || \
                echo "[WARN] 임시 저장소를 정리하지 못했습니다: $_bootstrap_stage" >&2
        fi
        return "$code"
    }
    trap _bootstrap_cleanup EXIT
    git clone --depth=1 -b "${INSTALL_BRANCH:-main}" \
        https://github.com/yanghoeg/usix-termux.git "$_bootstrap_stage"

    # 서브모듈은 핀이 깨져도(고아 커밋 등) main HEAD로 fallback
    if ! git -C "$_bootstrap_stage" submodule update --init --depth=1 2>/dev/null; then
        echo "[WARN] 서브모듈 핀이 원격에 없습니다 — App-Installer main HEAD로 fallback합니다."
        rm -rf "$_bootstrap_stage/app-installer" "$_bootstrap_stage/.git/modules/app-installer"
        sub_url=$(git -C "$_bootstrap_stage" config --file .gitmodules submodule.app-installer.url)
        git clone --depth=1 "$sub_url" "$_bootstrap_stage/app-installer"
    fi
    if [ -e "$local_dir" ] || [ -L "$local_dir" ]; then
        _bootstrap_backup=$(mktemp -d "${local_dir}.old.XXXXXX")
        rmdir -- "$_bootstrap_backup"
        mv -T -- "$local_dir" "$_bootstrap_backup"
    fi
    mv -T -- "$_bootstrap_stage" "$local_dir"
    _bootstrap_stage=""
    if [ -n "$_bootstrap_backup" ]; then
        rm -rf -- "$_bootstrap_backup" || \
            echo "[WARN] 이전 저장소를 정리하지 못했습니다: $_bootstrap_backup" >&2
    fi
    trap - EXIT
    exec bash "$local_dir/install.sh" "$@"
fi

# -----------------------------------------------------------------------------
# 1. 종료 트랩
# -----------------------------------------------------------------------------
_on_exit() {
    local code=$?
    if [ "$code" -ne 0 ] && [ "$code" -ne 130 ]; then
        echo ""
        echo "[ERROR] 설치 실패 (exit: ${code}). 위 오류 메시지를 확인하세요." >&2
    fi
}
trap _on_exit EXIT

# -----------------------------------------------------------------------------
# 2. Ports 로드 (계약 정의)
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/ports/pkg_manager.sh"
source "$SCRIPT_DIR/ports/ui.sh"
source "$SCRIPT_DIR/ports/display.sh"
source "$SCRIPT_DIR/ports/script_builder.sh"

# -----------------------------------------------------------------------------
# 3. Output Adapter 선택 — UI
# (DISPLAY, zenity 가용 여부로 자동 선택)
# -----------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && command -v yad &>/dev/null; then
    source "$SCRIPT_DIR/adapters/output/ui_yad.sh"
elif [ -n "${DISPLAY:-}" ] && command -v zenity &>/dev/null; then
    source "$SCRIPT_DIR/adapters/output/ui_zenity.sh"
else
    source "$SCRIPT_DIR/adapters/output/ui_terminal.sh"
fi

# Script Builder 어댑터 — 런타임 스크립트 생성 (zenity 기반)
source "$SCRIPT_DIR/adapters/output/script_builder_zenity.sh"

# -----------------------------------------------------------------------------
# 4. Input Adapter — CLI 인자 파싱
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/adapters/input/cli.sh"
parse_cli_args "$@"

# Check runtime dependencies before prompting or modifying the installation.
# CLI parsing handles --help even when the submodule has not been initialized.
# A stale checkout can be readable yet lack functions this installer calls, so
# load the helpers in a subshell and require those functions.
if ! (
    source "$SCRIPT_DIR/app-installer/lib/input_method.sh" &&
        source "$SCRIPT_DIR/app-installer/domain/desktop.sh" &&
        declare -F input_method_setup desktop_migrate_proot_launcher desktop_import_proot
) >/dev/null 2>&1; then
    echo "[ERROR] app-installer 서브모듈이 없거나 이 설치기와 버전이 맞지 않습니다: git submodule update --init --recursive" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# 5. Input Adapter — 빠진 값 대화형으로 채우기
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/adapters/input/interactive.sh"
resolve_interactive_inputs

# 실제 패키지 변경 전에 Termux 환경인지 확인한다. 테스트 훅은 호스트에서
# dispatch를 검증해야 하므로 명시적으로 설정된 경우에만 예외로 둔다.
if [ -z "${_INSTALL_HOOK:-}" ]; then
    case "${PREFIX:-}" in
        /data/data/com.termux/files/usr) ;;
        *)
            echo "[ERROR] 이 설치기는 Android Termux 환경에서만 실행할 수 있습니다." >&2
            echo "[ERROR] 현재 PREFIX: ${PREFIX:-<unset>}" >&2
            exit 1
            ;;
    esac
fi

# -----------------------------------------------------------------------------
# 6. Output Adapter 선택 — Display Server
# DISPLAY_SERVER는 CLI/환경변수/대화형에서 설정 (기본: x11) — 설치 시 하나 고정
# wayland는 Anland + KWin 기반 실험적 세션이며 x11이 기본이다.
# -----------------------------------------------------------------------------
case "${DISPLAY_SERVER}" in
    x11)
        source "$SCRIPT_DIR/adapters/output/display_x11.sh"
        ;;
    wayland)
        source "$SCRIPT_DIR/adapters/output/display_wayland.sh"
        ;;
    *)
        echo "[ERROR] 지원하지 않는 display server: ${DISPLAY_SERVER}" >&2
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# 7. Output Adapter 선택 — Package Manager
# Termux native는 항상 pkg_termux.sh,
# proot 어댑터는 distro에 따라 추가 로드
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/adapters/output/pkg_termux.sh"

case "${PROOT_DISTRO:-}" in
    ubuntu)
        source "$SCRIPT_DIR/adapters/output/pkg_ubuntu.sh"
        ;;
    archlinux)
        source "$SCRIPT_DIR/adapters/output/pkg_arch.sh"
        ;;
    "")
        # native only — proot_exec 함수는 pkg_termux.sh의 stub 사용
        ;;
    *)
        echo "[ERROR] 지원하지 않는 distro: ${PROOT_DISTRO}" >&2
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# 8. Domain 로드
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/domain/packages.sh"
source "$SCRIPT_DIR/domain/termux_env.sh"
source "$SCRIPT_DIR/domain/xfce_env.sh"
source "$SCRIPT_DIR/domain/locale_ko.sh"
source "$SCRIPT_DIR/domain/proot_env.sh"

_pkg_manager_check
_display_check

# 테스트 훅: 모든 source 이후, 실제 설치 전에 setup_* 함수를 스텁으로 교체할 수 있는 지점
# (테스트 매트릭스가 dispatch 로직만 검증하고 실제 설치 수행은 안 하기 위함)
if [ -n "${_INSTALL_HOOK:-}" ] && [ -f "${_INSTALL_HOOK}" ]; then
    source "${_INSTALL_HOOK}"
fi

# -----------------------------------------------------------------------------
# 9. 아키텍처 확인
# -----------------------------------------------------------------------------
if [[ "$ARCH" != "aarch64" ]]; then
    ui_warn "이 스크립트는 aarch64(arm64) 기기에 최적화되어 있습니다. 현재: $ARCH"
fi

if [ "${PROOT_ONLY:-false}" != true ]; then
    display_preflight
fi

# -----------------------------------------------------------------------------
# 10. 설치 설정 저장 (prun, cp2menu가 읽음)
# -----------------------------------------------------------------------------
# 기존 설정 병합: 재실행(예: --proot-only)이 사용자가 이미 바꿔둔 값
# (PROOT_SHELL=zsh 등)을 조용히 되돌리지 않도록, 기존 파일을 메인 셸에
# source하지 않고 grep/cut으로만 읽어 병합한다.
_cfg_file="$HOME/.config/termux-xfce/config"
mkdir -p "$HOME/.config/termux-xfce"

_existing_proot_shell=""
_existing_display_server=""
_existing_proot_distro=""
_existing_proot_user=""
_existing_prun_runtime=""
if [ -f "$_cfg_file" ]; then
    _existing_proot_shell=$(grep -m1 '^PROOT_SHELL=' "$_cfg_file" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
    _existing_display_server=$(grep -m1 '^DISPLAY_SERVER=' "$_cfg_file" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
    _existing_proot_distro=$(grep -m1 '^PROOT_DISTRO=' "$_cfg_file" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
    _existing_proot_user=$(grep -m1 '^PROOT_USER=' "$_cfg_file" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
    _existing_prun_runtime=$(grep -m1 '^PRUN_RUNTIME=' "$_cfg_file" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
fi

# PROOT_SHELL: 이번 실행에 명시된 값 > 기존 config 값 > bash
_cfg_proot_shell="${PROOT_SHELL:-${_existing_proot_shell:-bash}}"

# DISPLAY_SERVER: --proot-only 재실행이면서 기존 값이 있으면 유지, 아니면 이번 실행 값
if [ "${PROOT_ONLY:-false}" = "true" ] && [ -n "$_existing_display_server" ]; then
    _cfg_display_server="$_existing_display_server"
else
    _cfg_display_server="${DISPLAY_SERVER}"
fi

# native-only를 명시하면 선택을 비운다. 그 외에는 이번 값 또는 기존 값을 사용한다.
if [ "${SKIP_PROOT:-false}" = true ]; then
    if [ -n "$_existing_proot_distro" ]; then
        ui_warn "native 전용으로 전환합니다. 기존 컨테이너는 유지되며 prun 대상 선택은 해제됩니다."
    fi
    _cfg_proot_distro=""
    _cfg_proot_user=""
else
    _cfg_proot_distro="${PROOT_DISTRO:-$_existing_proot_distro}"
    _cfg_proot_user="${PROOT_USER:-$_existing_proot_user}"
fi

# Stage beside the destination so an interrupted write or failed rename leaves
# the saved installation usable. Follow an existing symlink without replacing it.
_cfg_target="$_cfg_file"
if [ -L "$_cfg_target" ]; then
    _cfg_target=$(readlink -f -- "$_cfg_target")
fi
_cfg_staged=$(mktemp "${_cfg_target}.XXXXXX")
cat > "$_cfg_staged" << EOF || { rm -f -- "$_cfg_staged"; exit 1; }
# Termux XFCE 설치 설정 — 자동 생성 ($(date '+%Y-%m-%d'))
PROOT_DISTRO="${_cfg_proot_distro}"
PROOT_USER="${_cfg_proot_user}"
INSTALL_ARCH="$ARCH"
DISPLAY_SERVER="${_cfg_display_server}"
# proot 인터랙티브 셸: bash(기본) 또는 zsh (proot에 zsh 설치 후 변경 가능)
PROOT_SHELL="${_cfg_proot_shell}"
EOF
# PRUN_RUNTIME은 사용자가 직접 켜는 값이라 기존 값이 있을 때만 보존한다.
if [ -n "$_existing_prun_runtime" ]; then
    printf '# prun 런타임: proot(기본) 또는 chroot-ng (App Installer에서 설치)\nPRUN_RUNTIME="%s"\n' \
        "$_existing_prun_runtime" >> "$_cfg_staged" || { rm -f -- "$_cfg_staged"; exit 1; }
fi
chmod 600 "$_cfg_staged" && mv -fT -- "$_cfg_staged" "$_cfg_target" || {
    rm -f -- "$_cfg_staged"
    exit 1
}
unset _cfg_target _cfg_staged

# -----------------------------------------------------------------------------
# 11. Storage 권한
# -----------------------------------------------------------------------------
if [ "${PROOT_ONLY:-false}" != "true" ] && [ ! -d "$HOME/storage" ]; then
    ui_info "저장소 접근 권한을 요청합니다..."
    termux-setup-storage
    sleep 2
fi

# -----------------------------------------------------------------------------
# 12. 실행 — Termux Native
# --proot-only 플래그 사용 시 생략 (추가 distro 설치 시 중복 방지)
# -----------------------------------------------------------------------------
# 단계 카운터 — 선택 옵션에 따라 총 단계 수 계산
_step=0
if [ "${PROOT_ONLY:-false}" = true ]; then
    _total=1
else
    _total=5  # base + xfce + shortcuts + display-apk + companion-apks
    [ "${SKIP_PROOT:-false}" != true ] && [ -n "${PROOT_DISTRO:-}" ] && _total=$((_total + 1))
fi
_step_msg() { _step=$((_step + 1)); ui_info "=== [${_step}/${_total}] $1 ==="; }

if [ "${PROOT_ONLY:-false}" != "true" ]; then
    _step_msg "Termux 기본 환경 설정"
    setup_termux_base

    _step_msg "XFCE 데스크탑 설치"
    setup_xfce_packages
    display_setup_runtime
    ui_info "  테마 설치..."
    setup_xfce_theme
    ui_info "  폰트 설치..."
    setup_xfce_fonts
    ui_info "  배경화면..."
    setup_xfce_wallpaper
    # zsh가 기본 쉘이면 fancybash 건너뜀 (p10k가 대체)
    _login_shell=$(readlink "$HOME/.termux/shell" 2>/dev/null || echo "")
    if [[ "$_login_shell" != */zsh ]]; then
        _termux_user=$(id -un 2>/dev/null || printf 'termux')
        setup_xfce_fancybash "$_termux_user" || ui_warn "fancybash 설정 실패 — 건너뜁니다"
        unset _termux_user
    fi
    unset _login_shell
    ui_info "  자동시작 설정..."
    setup_xfce_autostart

    _step_msg "유틸리티 설정 (shortcuts, prun, cp2menu)"
    setup_termux_shortcuts

else
    ui_info "[--proot-only] Termux native 설정 생략 — proot 환경만 구성합니다."
fi

# -----------------------------------------------------------------------------
# 13. 실행 — proot (선택)
# -----------------------------------------------------------------------------
if [ "${SKIP_PROOT:-false}" != "true" ] && [ -n "${PROOT_DISTRO:-}" ]; then
    _step_msg "${PROOT_DISTRO} proot 환경 구성"

    ui_info "  proot-distro 설치..."
    setup_proot_install
    ui_info "  패키지 업데이트..."
    setup_proot_update
    ui_info "  사용자 생성: ${PROOT_USER}..."
    setup_proot_user
    ui_info "  기본 패키지 설치..."
    setup_proot_base_packages
    ui_info "  환경변수 설정..."
    setup_proot_env
    setup_proot_timezone
    setup_proot_fancybash
    setup_proot_cursor_theme
    ui_info "  Conky 설정..."
    setup_proot_conky
    setup_proot_alias
fi

# -----------------------------------------------------------------------------
# 14. Display Server APK 설치 (proot-only 시 생략)
# -----------------------------------------------------------------------------
if [ "${PROOT_ONLY:-false}" != "true" ]; then
    _step_msg "Display Server 설치"
    display_setup_apk

    _step_msg "Termux 컴패니언 APK 설치 (API, Float, Widget, Boot)"
    setup_termux_api_apk
    setup_termux_float_apk
    setup_termux_widget
    setup_termux_boot_apk
fi

# -----------------------------------------------------------------------------
# 15. 완료
# -----------------------------------------------------------------------------
ui_info "=================================================="
ui_info "설치가 완료되었습니다!"
ui_info ""
ui_info "시작하려면: startXFCE"
if [ -n "${PROOT_DISTRO:-}" ]; then
    ui_info "proot 진입: ${PROOT_DISTRO} (또는 prun <명령>)"
fi
ui_info "앱 설치: app-installer"
ui_info "클립보드 동기화: XFCE 시작 시 자동 실행 (Android↔데스크탑)"
ui_info ""
ui_info "⚠ Termux:API, Termux:Float APK를 설치 화면에서 확인하세요"
ui_info "=================================================="

termux-reload-settings 2>/dev/null || true
