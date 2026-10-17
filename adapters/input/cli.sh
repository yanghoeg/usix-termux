#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# ADAPTER: adapters/input/cli.sh
# -----------------------------------------------------------------------------
# Input Adapter — CLI/환경변수 기반 비대화형 실행
# 사용법:
#   DISTRO=archlinux USERNAME=<username> bash install.sh
#   또는
#   bash install.sh --distro archlinux --user <username>
# =============================================================================

parse_cli_args() {
    local initial_argc=$#
    local scripted=false
    if [ "$initial_argc" -gt 0 ] || [ -n "${DISTRO+x}${USERNAME+x}${SKIP_PROOT+x}${PROOT_ONLY+x}${SKIP_CONKY+x}${DISPLAY_SERVER+x}${PROOT_SHELL+x}" ]; then
        scripted=true
    fi

    # 환경변수 우선, 그 다음 CLI 인자
    export PROOT_DISTRO="${DISTRO:-}"
    export PROOT_USER="${USERNAME:-}"
    export SKIP_PROOT="${SKIP_PROOT:-false}"
    export PROOT_ONLY="${PROOT_ONLY:-false}"
    export SKIP_CONKY="${SKIP_CONKY:-false}"
    export DISPLAY_SERVER="${DISPLAY_SERVER:-}"
    export PROOT_SHELL="${PROOT_SHELL:-}"

    # CLI 인자나 설치용 환경변수를 사용한 경우 디스플레이 선택도 묻지 않고
    # 기본값(x11)을 사용한다. distro/user처럼 설치에 필수인 값은 여전히
    # resolve_interactive_inputs에서 보충한다.
    export INSTALL_NONINTERACTIVE="$scripted"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --distro|-d)
                [[ $# -ge 2 ]] || { echo "[ERROR] $1 옵션에 값이 필요합니다" >&2; exit 1; }
                PROOT_DISTRO="$2"; shift 2 ;;
            --user|-u)
                [[ $# -ge 2 ]] || { echo "[ERROR] $1 옵션에 값이 필요합니다" >&2; exit 1; }
                PROOT_USER="$2"; shift 2 ;;
            --display)
                [[ $# -ge 2 ]] || { echo "[ERROR] $1 옵션에 값이 필요합니다" >&2; exit 1; }
                DISPLAY_SERVER="$2"; shift 2 ;;
            --no-proot)
                SKIP_PROOT=true; shift ;;
            --proot-only)
                PROOT_ONLY=true; shift ;;
            --no-conky)
                SKIP_CONKY=true; shift ;;
            --help|-h)
                _cli_usage; exit 0 ;;
            *)
                echo "[ERROR] 알 수 없는 인자: $1" >&2
                _cli_usage; exit 1 ;;
        esac
    done

    validate_install_inputs false
}

_input_error() {
    echo "[ERROR] $1" >&2
    return 1
}

_validate_bool() {
    local name="$1" value="$2"
    case "$value" in
        true|false) ;;
        *) _input_error "${name} 값은 true 또는 false여야 합니다: ${value}" ;;
    esac
}

# $1=true면 대화형 입력까지 끝난 최종 상태를 검증한다.
validate_install_inputs() {
    local final="${1:-true}"

    _validate_bool "SKIP_PROOT" "${SKIP_PROOT:-false}" || return 1
    _validate_bool "PROOT_ONLY" "${PROOT_ONLY:-false}" || return 1
    _validate_bool "SKIP_CONKY" "${SKIP_CONKY:-false}" || return 1

    case "${PROOT_DISTRO:-}" in
        ""|ubuntu|archlinux) ;;
        *) _input_error "지원하지 않는 distro: ${PROOT_DISTRO}" || return 1 ;;
    esac

    case "${DISPLAY_SERVER:-}" in
        ""|x11|wayland) ;;
        *) _input_error "지원하지 않는 display server: ${DISPLAY_SERVER}" || return 1 ;;
    esac

    case "${PROOT_SHELL:-bash}" in
        bash|zsh) ;;
        *) _input_error "PROOT_SHELL은 bash 또는 zsh만 허용됩니다: ${PROOT_SHELL}" || return 1 ;;
    esac

    if [ -n "${PROOT_USER:-}" ] && [[ ! "${PROOT_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        _input_error "사용자 이름은 영문 소문자/숫자/_/-만 사용할 수 있으며 문자 또는 _로 시작해야 합니다: ${PROOT_USER}" || return 1
    fi

    if [ "${SKIP_PROOT:-false}" = true ] && [ "${PROOT_ONLY:-false}" = true ]; then
        _input_error "--no-proot와 --proot-only는 함께 사용할 수 없습니다." || return 1
    fi

    if [ "${SKIP_PROOT:-false}" = true ]; then
        [ -z "${PROOT_DISTRO:-}" ] || {
            _input_error "--no-proot와 distro 지정은 함께 사용할 수 없습니다." || return 1
        }
        [ -z "${PROOT_USER:-}" ] || {
            _input_error "--no-proot에서는 proot 사용자 이름을 지정할 수 없습니다." || return 1
        }
    fi

    if [ "$final" = true ] && [ "${SKIP_PROOT:-false}" != true ]; then
        [ -n "${PROOT_DISTRO:-}" ] || {
            _input_error "proot 설치에는 distro가 필요합니다." || return 1
        }
        [ -n "${PROOT_USER:-}" ] || {
            _input_error "proot 설치에는 사용자 이름이 필요합니다." || return 1
        }
    fi
}

_cli_usage() {
    cat << 'EOF'
사용법: bash install.sh [옵션]

옵션:
  -u, --user <이름>       proot 사용자 이름 (기본: 대화형 입력)
  -d, --distro <distro>   proot distro: ubuntu | archlinux (기본: 대화형 선택)
      --display <server>  디스플레이 서버/데스크탑: x11(XFCE) | wayland(KDE Plasma)
                          wayland는 현재 실사용 불가 — docs/wayland-anland.md의
                          'Known blockers' 참고 (미지정 시 대화형 선택, 기본: x11)
      --no-proot          Termux native만 설치 (proot 생략)
      --proot-only        proot만 설치 (Termux native 설정 생략, 추가 distro용)
      --no-conky          Conky 자동시작 끄기 (배터리 절약, XFCE 시작 프로그램에서 다시 켤 수 있음)
  -h, --help              이 도움말 출력

환경변수:
  DISTRO=archlinux        --distro 와 동일
  USERNAME=<username>     --user 와 동일
  DISPLAY_SERVER=wayland  --display 와 동일
  SKIP_PROOT=true         --no-proot 와 동일
  PROOT_ONLY=true         --proot-only 와 동일
  SKIP_CONKY=true         --no-conky 와 동일

참고: GPU 가속, 한글 입력기 등 선택적 구성요소는 설치 후 App Installer에서 관리합니다.

예시:
  bash install.sh --user <username> --distro archlinux
  bash install.sh --user <username> --distro ubuntu --display wayland
  bash install.sh --user <username> --distro ubuntu --proot-only
  DISTRO=ubuntu USERNAME=<username> bash install.sh
EOF
}
