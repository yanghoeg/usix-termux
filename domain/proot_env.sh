#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# DOMAIN: proot_env.sh
# -----------------------------------------------------------------------------
# proot-distro 환경 구성 도메인 로직
# - Ubuntu / Arch Linux 공통 로직
# - distro별 차이는 어댑터(pkg_ubuntu.sh / pkg_arch.sh)가 흡수
# - 기존 proot.sh + ubuntu_etc.sh 통합
# 환경변수: PROOT_DISTRO, PROOT_USER 필요
# =============================================================================

# -----------------------------------------------------------------------------
# proot-distro rootfs 경로 해석 (호출 시점 lazy — 레이아웃 자동 판별)
#   신규:   $PREFIX/var/lib/proot-distro/containers/<distro>/rootfs   (Python proot-distro)
#   레거시: $PREFIX/var/lib/proot-distro/installed-rootfs/<distro>    (구 bash proot-distro)
# 이미 설치된 경우 실제 존재하는 경로를 우선하고, 미설치(신규 설치 직전)에는
# proot-distro 구현으로 판별한다: Python 모듈이 있으면 신규, 없으면 레거시.
# 테스트/특수 환경은 PROOT_ROOTFS_BASE로 베이스 디렉토리를 override할 수 있다.
# -----------------------------------------------------------------------------
_proot_rootfs() {
    local base="${PROOT_ROOTFS_BASE:-$PREFIX/var/lib/proot-distro}"
    local new="${base}/containers/${PROOT_DISTRO}/rootfs"
    local legacy="${base}/installed-rootfs/${PROOT_DISTRO}"

    if [ -d "$new" ]; then
        printf '%s' "$new"
    elif [ -d "$legacy" ]; then
        printf '%s' "$legacy"
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import proot_distro' 2>/dev/null; then
        printf '%s' "$new"
    else
        printf '%s' "$legacy"
    fi
}

# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------

setup_proot_install() {
    ui_info "${PROOT_DISTRO} proot-distro 설치"

    # 의존성 보강: --proot-only 모드는 setup_termux_base를 건너뛰므로
    # proot-distro 패키지가 없을 수 있다. 도메인이 자기 런타임 의존성을 보장.
    if ! command -v proot-distro >/dev/null 2>&1; then
        ui_info "proot-distro 패키지가 없어 먼저 설치합니다 (PKGS_TERMUX_PROOT)"
        pkg_update
        for _p in "${PKGS_TERMUX_PROOT[@]}"; do
            if pkg_is_installed "$_p"; then
                ui_info "  ${_p} — 이미 설치됨"
            else
                ui_info "  ${_p} 설치 중..."
                pkg_install "$_p"
            fi
        done
        unset _p
    fi

    # 이미 설치된 경우 건너뜀
    [ -d "$(_proot_rootfs)" ] && {
        ui_warn "${PROOT_DISTRO}가 이미 설치되어 있습니다. 건너뜁니다."
        return 0
    }
    proot_install "$PROOT_DISTRO"
}

setup_proot_update() {
    ui_info "${PROOT_DISTRO} 패키지 업데이트"
    # 사용자 생성 전 단계이므로 root로 실행
    proot_pkg_update_root
}

setup_proot_user() {
    local username="$PROOT_USER"
    ui_info "${PROOT_DISTRO} 사용자 생성: ${username}"

    local home_dir="$(_proot_rootfs)/home/${username}"
    [ -d "$home_dir" ] && {
        ui_warn "사용자 ${username}이 이미 존재합니다. 건너뜁니다."
        return 0
    }

    # 사용자 생성 전이므로 root로 실행
    proot_exec_root groupadd storage  2>/dev/null || true
    proot_exec_root groupadd wheel    2>/dev/null || true
    proot_exec_root useradd -m -g users -G wheel,audio,video,storage -s /bin/bash "$username"

    _setup_proot_sudoers "$username"

    # sudo가 base에 없을 수 있음 → 사용자 생성 직후 root로 설치
    # 이후 proot_exec sudo ... 이 작동하려면 sudo 바이너리가 필요
    proot_pkg_install_root sudo 2>/dev/null || true
}

setup_proot_base_packages() {
    ui_info "${PROOT_DISTRO} 기본 패키지 설치"

    # sudo가 base에 없으면 proot_pkg_install(sudo 기반) 자체가 실패
    # → root로 먼저 설치 후 sudoers ���구성
    proot_pkg_install_root sudo 2>/dev/null || true
    _setup_proot_sudoers "$PROOT_USER"

    # setup_proot_user가 멱등성으로 건너뛴 경우도 있으므로 여기서 항상 보장
    proot_pkg_update || true  # proot systemd hook 오류 무시

    # 패키지 목록 선택은 도메인 지식 (distro별 패키지명이 다름)
    case "$PROOT_DISTRO" in
        ubuntu)
            local -a _pkgs=("${PKGS_PROOT_UBUNTU_BASE[@]}" "${PKGS_PROOT_UBUNTU_DESKTOP[@]}")
            local _total=${#_pkgs[@]} _i=0
            for p in "${_pkgs[@]}"; do
                ((++_i))
                if proot_pkg_is_installed "$p"; then
                    ui_info "  (${_i}/${_total}) ${p} — 이미 설치됨"
                else
                    ui_info "  (${_i}/${_total}) ${p} 설치 중..."
                    # 개별 패키지의 apt 설치 실패로 나머지 base 패키지 설치가
                    # 전부 중단되지 않도록 경고 후 계속 진행 (archlinux 분기와 동일 패턴)
                    proot_pkg_install "$p" || \
                        echo "[WARN] $p: apt 설치 오류 (계속 진행)" >&2
                fi
            done
            ;;
        archlinux)
            local -a _pkgs=("${PKGS_PROOT_ARCH_BASE[@]}" "${PKGS_PROOT_ARCH_DESKTOP[@]}")
            local _total=${#_pkgs[@]} _i=0
            for p in "${_pkgs[@]}"; do
                ((++_i))
                if proot_pkg_is_installed "$p"; then
                    ui_info "  (${_i}/${_total}) ${p} — 이미 설치됨"
                else
                    ui_info "  (${_i}/${_total}) ${p} 설치 중..."
                    # proot 내부 systemd/udev hook 실패(exit 1)는 패키지 설치 자체와 무관 → 무시
                    proot_pkg_install "$p" || \
                        echo "[WARN] $p: pacman hook 오류 (패키지는 설치됨)" >&2
                fi
            done
            ;;
    esac
}

setup_proot_env() {
    ui_info "${PROOT_DISTRO} 환경변수 설정"
    local rootfs; rootfs="$(_proot_rootfs)"
    local bashrc="${rootfs}/home/${PROOT_USER}/.bashrc"
    local profile_d="${rootfs}/etc/profile.d"
    local envfile="${profile_d}/termux-xfce-env.sh"

    # Login shells read this profile even for noninteractive GUI commands.
    # GPU overrides are owned exclusively by App Installer's gpu-accel.sh.
    mkdir -p "$profile_d"
    cat > "$envfile" << 'EOF'
# Termux XFCE container environment (generated).
export DISPLAY=${DISPLAY:-:0.0}
export XDG_RUNTIME_DIR=/run/user/$(id -u)
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
EOF

    # 2) 삭제 범위는 설치기가 생성한 줄로 한정한다. code()가 없는 구버전도
    #    사용자 프롬프트와 conda 설정을 보존한다.
    if [ -f "$bashrc" ] && grep -q '^# termux-xfce-proot-env$' "$bashrc"; then
        local cleaned target
        # 완성된 사본을 rename으로 교체한다 — 쓰기 실패가 원본을 자르지 않고,
        # 심볼릭 링크로 관리되는 .bashrc는 링크 대상이 갱신된다.
        target=$(readlink -f -- "$bashrc") || return 1
        cleaned=$(mktemp "${target}.XXXXXX") || return 1
        awk '
            /^# termux-xfce-proot-env$/ { managed=1; next }
            /^# termux-xfce-proot-env-end$/ { managed=0; next }
            managed && (/^$/ || /^# aliases$/ || /^# Termux Turnip Vulkan ICD/ ||
                /^export (DISPLAY|LD_PRELOAD|XDG_RUNTIME_DIR|MESA_[A-Z_]+|TU_DEBUG|ZINK_DESCRIPTORS|vblank_mode|VK_ICD_FILENAMES|VK_DRIVER_FILES)=/ ||
                /^mkdir -p "\$XDG_RUNTIME_DIR" 2>\/dev\/null$/ ||
                /^\[ -f \/etc\/profile.d\/termux-xfce-env.sh \]/ ||
                /^alias (hud|ls|ll|shutdown|cat|python|pip|start)=/ ||
                /^command -v (eza|bat) .*alias (ls|cat)=/) { next }
            managed && /^code\(\) \{/ { managed=0; next }
            { managed=0; print }
        ' "$target" > "$cleaned" || { rm -f "$cleaned"; return 1; }
        chmod --reference="$target" "$cleaned" && mv -f -- "$cleaned" "$target" || {
            rm -f -- "$cleaned"
            return 1
        }
    fi

    cat >> "$bashrc" << 'EOF'

# termux-xfce-proot-env
[ -f /etc/profile.d/termux-xfce-env.sh ] && . /etc/profile.d/termux-xfce-env.sh
# aliases
alias hud='GALLIUM_HUD=fps '
command -v eza >/dev/null 2>&1 && alias ls='eza -lF --icons'
alias ll='ls -alhF'
alias shutdown='kill -9 -1'
command -v bat >/dev/null 2>&1 && alias cat='bat'
alias start='echo "Termux에서 실행하세요."'
code() { nohup dbus-run-session /usr/bin/code --no-sandbox "$@" >/dev/null 2>&1 & disown; }
# termux-xfce-proot-env-end
EOF
}

setup_proot_timezone() {
    ui_info "${PROOT_DISTRO} 시간대 설정"
    local tz
    tz=$(getprop persist.sys.timezone 2>/dev/null || echo "Asia/Seoul")
    tz="${tz:-Asia/Seoul}"

    # /etc/localtime는 root 소유 → proot_exec_root 사용
    proot_exec_root rm -f /etc/localtime
    proot_exec_root ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
}

setup_proot_fancybash() {
    local username="$PROOT_USER"
    ui_info "${PROOT_DISTRO} 프롬프트 설정"

    local dst="$(_proot_rootfs)/home/${username}/.fancybash.sh"
    if [ -f "$dst" ]; then
        _migrate_proot_fancybash_prompt "$dst" || return 1
        return 0
    fi
    _generate_proot_fancybash "$dst" || return 1

    local bashrc="$(_proot_rootfs)/home/${username}/.bashrc"
    grep -q "source.*\.fancybash\.sh" "$bashrc" 2>/dev/null || \
        echo "source ~/.fancybash.sh" >> "$bashrc"
}

setup_proot_cursor_theme() {
    ui_info "${PROOT_DISTRO} 커서 테마(dist-dark) 적용"
    local src="$PREFIX/share/icons/dist-dark"
    local dst="$(_proot_rootfs)/usr/share/icons/dist-dark"

    [ -d "$dst" ] && return 0

    # 의존성 보강: --proot-only 모드는 setup_xfce_theme를 건너뛰므로 dist-dark가 없을 수 있다.
    # _install_fluent_cursor가 로드돼 있으면 자동 다운로드 (xfce_env.sh와 함께 source된 경우).
    if [ ! -d "$src" ] && declare -F _install_fluent_cursor >/dev/null 2>&1; then
        ui_info "  dist-dark 미존재 → _install_fluent_cursor 자동 호출"
        _install_fluent_cursor || true
    fi

    # 여전히 없으면 cosmetic 실패이므로 경고 후 skip (set -e에서 distro 전체 중단 방지)
    [ -d "$src" ] || {
        ui_warn "dist-dark 커서 테마를 준비하지 못했습니다 — 커서 테마 적용을 건너뜁니다."
        return 0
    }

    mkdir -p "$(dirname "$dst")"
    cp -r "$src" "$dst"

    local xresources="$(_proot_rootfs)/home/${PROOT_USER}/.Xresources"
    grep -q "Xcursor.theme" "$xresources" 2>/dev/null || \
        echo "Xcursor.theme: dist-dark" >> "$xresources"
}

setup_proot_conky() {
    ui_info "${PROOT_DISTRO} Conky 설정 복사"
    local username="$PROOT_USER"
    local config_dst="$(_proot_rootfs)/home/${username}/.config"

    if [ ! -d "${config_dst}/conky" ]; then
        mkdir -p "$config_dst"

        # install.sh:28-35이 curl-pipe 실행을 git clone으로 재시작하므로 SCRIPT_DIR은 항상 존재
        # (과거엔 conky.tar.gz wget 폴백이 있었으나 해당 아티팩트 미발행 → 제거)
        local conky_src="${SCRIPT_DIR}/tar/conky/.config"
        if [ -d "$conky_src" ]; then
            cp -rn "$conky_src/." "$config_dst/"
        else
            ui_warn "conky 소스 디렉토리를 찾을 수 없습니다: ${conky_src}"
        fi

        # 이모지 폰트 복사
        local emoji_src="$HOME/.fonts/NotoColorEmoji-Regular.ttf"
        local emoji_dst="$(_proot_rootfs)/home/${username}/.fonts/"
        mkdir -p "$emoji_dst"
        [ -f "$emoji_src" ] && cp "$emoji_src" "$emoji_dst"
    fi

    # *.sh 실행권한 보정 (항상 실행 — git index가 100755로 반영되기 전 구버전 설치본 커버)
    find "${config_dst}/conky" -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

    # 구버전 Alterf.conf의 `backend = "glx";` 제거 (conky가 인식 못해 경고 유발)
    local alterf="${config_dst}/conky/Alterf/Alterf.conf"
    if [ -f "$alterf" ] && grep -q '^\s*backend\s*=' "$alterf" 2>/dev/null; then
        sed -i '/^\s*backend\s*=/d' "$alterf"
    fi
}

# proot 제거 (테스트용 distro 정리)
# 사용법: PROOT_DISTRO=ubuntu PROOT_USER=<username> bash -c 'source domain/proot_env.sh && teardown_proot'
teardown_proot() {
    local distro="${PROOT_DISTRO:?PROOT_DISTRO 필요}"
    local user="${PROOT_USER:-}"

    ui_info "${distro} proot 제거 중..."

    # rootfs 제거
    proot_remove "$distro"

    # bash.bashrc alias 제거
    local bashrc="$PREFIX/etc/bash.bashrc"
    sed -i "/alias ${distro}=/d" "$bashrc" 2>/dev/null || true

    # ~/.zshrc alias 제거
    if [ -f "$HOME/.zshrc" ]; then
        sed -i "/alias ${distro}=/d" "$HOME/.zshrc" 2>/dev/null || true
    fi

    # 설정 파일에서 distro 항목 제거
    local cfg="$HOME/.config/termux-xfce/config"
    if [ -f "$cfg" ] && grep -q "^PROOT_DISTRO=\"${distro}\"" "$cfg"; then
        sed -i "s/^PROOT_DISTRO=\"${distro}\"/PROOT_DISTRO=\"\"/" "$cfg"
        sed -i "s/^PROOT_USER=\"${user}\"/PROOT_USER=\"\"/" "$cfg"
    fi

    ui_info "${distro} 제거 완료."
}

setup_proot_alias() {
    local distro="$PROOT_DISTRO"
    local user="$PROOT_USER"
    [ -z "$distro" ] && return 0

    # PROOT_SHELL: alias 사용 시점에 서브셸에서 config를 읽어 인터랙티브 셸 결정
    # (bash|zsh, 기본 bash). 설치 후 사용자가 config의 PROOT_SHELL을 바꾸면 즉시 반영되고,
    # 서브셸이라 config의 다른 변수는 사용자 셸로 새지 않는다.
    local _proot_alias="alias ${distro}='proot-distro login ${distro} --user ${user} --shared-tmp -- env -u LD_PRELOAD \"\$(. \"\$HOME/.config/termux-xfce/config\" 2>/dev/null; echo \"\${PROOT_SHELL:-bash}\")\" --login'"
    # Shapes written by earlier installers, refreshed like the current one.
    local _legacy_aliases="alias ${distro}='proot-distro login ${distro} --user @user@ --shared-tmp'
alias ${distro}='proot-distro login ${distro} --user @user@ --shared-tmp -- env -u LD_PRELOAD \${PROOT_SHELL:-bash} --login'"

    local rc target staged
    for rc in "$PREFIX/etc/bash.bashrc" "$HOME/.zshrc"; do
        if [ ! -f "$rc" ]; then
            [ "$rc" != "$HOME/.zshrc" ] || continue
            : > "$rc" || return 1
        fi
        target=$(readlink -f -- "$rc") || return 1
        staged=$(mktemp "${target}.XXXXXX") || return 1
        # The installer writes its alias at column 0 in one of the shapes above;
        # refresh it in place for the configured user. Any other active alias for
        # this distro (indented in a guard, or after `cond &&`) is the user's own
        # and suppresses the managed one.
        PROOT_ALIAS="$_proot_alias" PROOT_LEGACY_ALIASES="$_legacy_aliases" awk -v distro="$distro" '
            function shape(line) {
                sub(/ --user [^[:space:]]+ /, " --user @user@ ", line)
                return line
            }
            BEGIN {
                current = ENVIRON["PROOT_ALIAS"]
                managed[shape(current)] = 1
                n = split(ENVIRON["PROOT_LEGACY_ALIASES"], legacy, "\n")
                for (i = 1; i <= n; i++) managed[legacy[i]] = 1
                defines = "(^|[^[:alnum:]_-])alias[[:space:]]+" distro "="
            }
            (shape($0) in managed) { if (!refreshed) print current; refreshed = 1; next }
            $0 !~ /^[[:space:]]*#/ && $0 ~ defines { custom = 1 }
            { print }
            END { if (!refreshed && !custom) print current }
        ' "$target" > "$staged" || { rm -f "$staged"; return 1; }
        if cmp -s "$staged" "$target"; then
            rm -f -- "$staged"
            continue
        fi
        chmod --reference="$target" "$staged" && mv -f -- "$staged" "$target" || {
            rm -f -- "$staged"
            return 1
        }
    done
}

# -----------------------------------------------------------------------------
# Private
# -----------------------------------------------------------------------------

# Older generated prompts inserted branch names directly into PS1. Bash expands
# command substitutions in PS1, so a valid branch name such as $(command) would
# execute when the prompt was drawn. Keep the helper call literal until Bash
# expands the prompt; its output is then displayed without another evaluation.
# Refresh only the exact generated fragment, preserving custom prompt content.
_migrate_proot_fancybash_prompt() {
    local dst="$1" target staged
    grep -qx '# Auto-generated by Termux XFCE installer' "$dst" || return 0
    grep -Fq '\w${R}$(__git_branch)' "$dst" || return 0
    target=$(readlink -f -- "$dst") || return 1
    staged=$(mktemp "${target}.XXXXXX") || return 1
    sed '/^    PS1=/s/[$]{R}[$](__git_branch)/${R}\\$(__git_branch)/' \
        "$target" > "$staged" || { rm -f -- "$staged"; return 1; }
    chmod --reference="$target" "$staged" && mv -f -- "$staged" "$target" || {
        rm -f -- "$staged"
        return 1
    }
}

_generate_proot_fancybash() {
    local dst="$1"
    local icon_hex color
    case "$PROOT_DISTRO" in
        archlinux) icon_hex='\uf303'; color='75'  ;;   #  Arch blue
        ubuntu)    icon_hex='\uf31b'; color='208' ;;   #  Ubuntu orange
        *)         icon_hex='\uf17c'; color='34'  ;;   #  Linux tux
    esac

    local icon_char git_icon
    printf -v icon_char "$icon_hex"
    printf -v git_icon '\ue0a0'

    cat > "$dst" << FANCYBASH
# fancybash — proot prompt (${PROOT_DISTRO})
# Auto-generated by Termux XFCE installer

__git_branch() {
    local b
    b=\$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
    [ -n "\$b" ] && printf ' \001\033[38;5;203m\002${git_icon} %s\001\033[0m\002' "\$b"
}

PROMPT_COMMAND='__proot_ps1'
__proot_ps1() {
    local ec=\$?
    local R='\[\e[0m\]'
    local B='\[\e[1m\]'
    local C='\[\e[38;5;${color}m\]'
    local G='\[\e[38;5;114m\]'
    local D='\[\e[38;5;244m\]'
    local A='\[\e[38;5;75m\]'
    local E='\[\e[38;5;203m\]'

    local p="\${C}❯\${R}"
    [ \$ec -ne 0 ] && p="\${E}❯\${R}"

    PS1="\${B}\${C}${icon_char} \${R}\${G}\u\${D}@\${C}${PROOT_DISTRO}\${R} \${B}\${A}\w\${R}\\\$(__git_branch) \${p} "
}
FANCYBASH
}

_setup_proot_sudoers() {
    local username="$1"
    local sudoers="$(_proot_rootfs)/etc/sudoers"
    local sudoers_d="$(_proot_rootfs)/etc/sudoers.d"

    if [ ! -f "$sudoers" ]; then
        # sudo 미설치(Arch 기본): sudoers.d에 미리 작성 → sudo 설치 후 활성화
        mkdir -p "$sudoers_d"
        echo "${username} ALL=(ALL) NOPASSWD:ALL" > "${sudoers_d}/${username}"
        chmod 440 "${sudoers_d}/${username}"
        return 0
    fi

    # /etc/sudoers 존재: wheel 그룹 NOPASSWD 활성화 + 유저 직접 추가
    chmod u+rw "$sudoers"

    # Arch: "# %wheel ALL=(ALL:ALL) NOPASSWD: ALL" 주석 해제
    sed -i 's/^#[[:space:]]*%wheel[[:space:]]*ALL=(ALL:ALL)[[:space:]]*NOPASSWD:/%wheel ALL=(ALL:ALL) NOPASSWD:/' "$sudoers"
    # Ubuntu: "# %wheel ALL=(ALL) NOPASSWD:ALL"
    sed -i 's/^#[[:space:]]*%wheel[[:space:]]*ALL=(ALL)[[:space:]]*NOPASSWD:/%wheel ALL=(ALL) NOPASSWD:/' "$sudoers"

    # 유저 직접 항목 (wheel 그룹 설정 없을 때 폴백)
    awk -v user="$username" '$1 == user && $2 ~ /^ALL=/ { found=1 } END { exit !found }' "$sudoers" || \
        echo "${username} ALL=(ALL) NOPASSWD:ALL" >> "$sudoers"

    chmod 440 "$sudoers"
}
