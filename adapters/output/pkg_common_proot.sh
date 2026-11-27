#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# ADAPTER (공통): pkg_common_proot.sh
# -----------------------------------------------------------------------------
# proot-distro 공통 구현 — pkg_ubuntu.sh, pkg_arch.sh가 source하는 공통 코드
# Termux native 패키지 관리 + proot 라이프사이클/실행 함수 제공
# =============================================================================

# Termux native 패키지 관리 (공통)
_PROOT_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_PROOT_COMMON_DIR/pkg_common_termux.sh"

# -----------------------------------------------------------------------------
# proot-distro 라이프사이클
# -----------------------------------------------------------------------------

proot_install() {
    if [ "$1" = archlinux ] && [ "$(uname -m)" = aarch64 ] &&
       command -v python3 >/dev/null 2>&1 &&
       python3 -c 'import proot_distro' 2>/dev/null; then
        _proot_install_arch_arm64
        return $?
    fi

    # proot-distro 버그 우회: 내부에서 `TERMUX_LDPRELOAD="${LD_PRELOAD-}"`로
    # LD_PRELOAD를 캡처한 뒤, run_proot_cmd 마지막에
    #   [ -n "$TERMUX_LDPRELOAD" ] && export LD_PRELOAD="$TERMUX_LDPRELOAD"
    # 를 실행. LD_PRELOAD가 unset이면 함수 exit 1 → distro_setup(set -e) 실패.
    # Termux 일반 세션은 자동 설정되지만 외부 spawn 셸(Claude Code 등)에선 미설정.
    if [ -z "${LD_PRELOAD-}" ] && [ -e "${PREFIX}/lib/libtermux-exec.so" ]; then
        LD_PRELOAD="${PREFIX}/lib/libtermux-exec.so" proot-distro install "$1"
    else
        proot-distro install "$1"
    fi
}

_proot_install_arch_arm64() (
    # The v5 installer resolves a bare "archlinux" to the amd64 OCI image.
    # Use the ARM64 rootfs and checksum from Termux's v4.34.2 Arch plug-in.
    local stage archive
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        pkg_install curl || return 1
    fi
    stage=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/arch-rootfs.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    source "$_PROOT_COMMON_DIR/../../app-installer/lib/fetch.sh" || return 1
    archive="$stage/archlinux-aarch64.tar.xz"
    fetch_verified \
        "https://github.com/termux/proot-distro/releases/download/v4.29.0/archlinux-aarch64-pd-v4.29.0.tar.xz" \
        "$archive" "08d74365213e647c558e561b0a2a7afb6fa3dfe345a1994c62ccac5af1a1cdc6" || return 1
    proot-distro install --name archlinux "$archive"
)

proot_remove() {
    proot-distro remove "$1" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# proot 실행
# -----------------------------------------------------------------------------

proot_exec() {
    : "${PROOT_DISTRO:?PROOT_DISTRO 환경변수가 설정되지 않았습니다}"
    : "${PROOT_USER:?PROOT_USER 환경변수가 설정되지 않았습니다}"
    proot-distro login "$PROOT_DISTRO" \
        --user "$PROOT_USER" \
        --shared-tmp \
        -- env DISPLAY="${DISPLAY:-:0.0}" "$@"
}

# root 권한 실행 — 사용자 생성 전/패키지 업데이트 등 root 필요 작업용
proot_exec_root() {
    : "${PROOT_DISTRO:?PROOT_DISTRO 환경변수가 설정되지 않았습니다}"
    proot-distro login "$PROOT_DISTRO" \
        --shared-tmp \
        -- env DISPLAY="${DISPLAY:-:0.0}" "$@"
}
