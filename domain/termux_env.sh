#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# DOMAIN: termux_env.sh
# -----------------------------------------------------------------------------
# Termux 기본 환경 구성 도메인 로직
# - pkg_install, ui_info 등은 어댑터에서 주입됨 (직접 호출 안 함)
# =============================================================================

# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------

setup_termux_base() {
    ui_info "Termux 기본 환경 설정 시작"

    _setup_termux_properties
    _setup_termux_repos
    pkg_update
    pkg_upgrade
    _install_base_packages
    # zsh+p10k 먼저 설정 (~/.zshrc 생성) → 이후 _setup_aliases 등이 zshrc에도 블록을 반영
    # (과거: _setup_aliases가 먼저 실행되어 clean install 시 zshrc에 alias 블록 누락)
    _setup_zsh_p10k
    _setup_aliases
    _setup_locale
    _setup_input_method
    _setup_xdg_runtime
    _migrate_gpu_rc
}

setup_termux_shortcuts() {
    ui_info "Termux 단축키(startXFCE) 설정"
    _setup_start_xfce
    _setup_kill_display
    _setup_prun
    _setup_hostinfo
    _setup_prun_gui
    _setup_cp2menu
    _setup_app_installer
    _setup_clipboard_sync
    _setup_screenshot
    _setup_conky_autostart
}

termux_download_and_open_apk() {
    local apk_url="$1" apk_filename="$2"
    local dl_dir="$HOME/storage/downloads"
    local apk_path="${dl_dir}/${apk_filename}"
    local apk_tmp="${apk_path}.part.$$"

    if [ ! -d "$dl_dir" ]; then
        dl_dir="$HOME"
        apk_path="${dl_dir}/${apk_filename}"
        apk_tmp="${apk_path}.part.$$"
        ui_warn "storage/downloads 없음 — ${apk_path} 에 저장합니다."
    fi

    # APK는 ZIP 컨테이너이므로 PK magic과 non-empty를 최소 검증한다.
    # 기존 파일도 검증해 중단된 다운로드를 설치 화면으로 넘기지 않는다.
    if [ -s "$apk_path" ] && [ "$(head -c 2 "$apk_path" 2>/dev/null)" = "PK" ]; then
        ui_warn "APK가 이미 다운로드되어 있습니다: ${apk_path}"
    else
        rm -f "$apk_path" "$apk_tmp"
        if ! wget -q "$apk_url" -O "$apk_tmp"; then
            rm -f "$apk_tmp"
            ui_warn "APK 다운로드 실패: ${apk_url}"
            return 0
        fi
        if [ ! -s "$apk_tmp" ] || [ "$(head -c 2 "$apk_tmp" 2>/dev/null)" != "PK" ]; then
            rm -f "$apk_tmp"
            ui_warn "APK 형식 검증 실패: ${apk_url}"
            return 0
        fi
        chmod 600 "$apk_tmp"
        mv "$apk_tmp" "$apk_path"
    fi

    termux-open "$apk_path" 2>/dev/null || \
        ui_warn "APK 자동 열기 실패 — 수동으로 설치하세요: ${apk_path}"
}


# setup_termux_x11_apk: display_x11.sh:display_setup_apk()로 이동됨

setup_termux_api_apk() {
    termux_download_and_open_apk \
        'https://github.com/termux/termux-api/releases/download/v0.53.0/termux-api-app_v0.53.0+github.debug.apk' \
        'termux-api.apk'
}

setup_termux_float_apk() {
    termux_download_and_open_apk \
        'https://github.com/termux/termux-float/releases/download/v0.17.0/termux-float-app_v0.17.0+github.debug.apk' \
        'termux-float.apk'
}

setup_termux_widget() {
    local apk_url='https://github.com/termux/termux-widget/releases/download/v0.15.0/termux-widget-app_v0.15.0+github.debug.apk'
    ui_info "Termux-Widget 설치"

    [ -d "$HOME/.shortcuts" ] || mkdir -p "$HOME/.shortcuts"

    if ! ls "$HOME/.shortcuts/startXFCE" &>/dev/null; then
        ui_warn "startXFCE 단축키가 없습니다. setup_termux_shortcuts 를 먼저 실행하세요."
    fi

    termux_download_and_open_apk "$apk_url" 'termux-widget.apk'
}

# Termux:Boot — 기기 부팅 시 ~/.termux/boot/ 안의 스크립트를 실행하는 애드온.
# APK 설치 후 최소 한 번 앱을 열어야 활성화된다(Android 제약).
setup_termux_boot_apk() {
    ui_info "Termux:Boot 설치 (부팅 시 서비스 자동 기동)"
    termux_download_and_open_apk \
        'https://github.com/termux/termux-boot/releases/download/v0.8.1/termux-boot-app_v0.8.1+github.debug.apk' \
        'termux-boot.apk'
    _setup_termux_boot_script
}

# -----------------------------------------------------------------------------
# Private
# -----------------------------------------------------------------------------

# RC 파일 목록 반환: bash.bashrc + ~/.zshrc (zsh 설치/존재 시)
_rc_targets() {
    echo "$PREFIX/etc/bash.bashrc"
    if command -v zsh &>/dev/null && [ -f "$HOME/.zshrc" ]; then
        echo "$HOME/.zshrc"
    fi
}

# 마커가 없으면 내용을 RC 파일에 추가 (멱등성)
_append_to_rc() {
    local marker="$1"
    local content="$2"
    local file="$3"
    [ -f "$file" ] || return 0  # 파일 없으면 건너뜀 (silent failure 방지)
    grep -qF "$marker" "$file" 2>/dev/null || printf '%s\n' "$content" >> "$file"
}

_setup_termux_properties() {
    local props="$HOME/.termux/termux.properties"
    mkdir -p "$(dirname "$props")"
    [ -f "$props" ] || touch "$props"
    if ! grep -q "^allow-external-apps = true" "$props" 2>/dev/null; then
        sed -i 's/# allow-external-apps = true/allow-external-apps = true/g' "$props"
        # sed 대상 주석이 없었을 경우 직접 추가
        grep -q "^allow-external-apps = true" "$props" 2>/dev/null || \
            echo "allow-external-apps = true" >> "$props"
    fi

    if ! grep -q "^bell-character = ignore" "$props" 2>/dev/null; then
        sed -i 's/# bell-character = ignore/bell-character = ignore/g' "$props"
        grep -q "^bell-character = ignore" "$props" 2>/dev/null || \
            echo "bell-character = ignore" >> "$props"
    fi
}

# ~/.termux/boot/start-services — Termux:Boot이 부팅 직후 실행하는 스크립트.
# termux-services(runit)가 sv-enable로 켜둔 서비스(sshd 등)를 기동한다.
# 멱등: 이미 있으면 건드리지 않는다 (사용자 커스터마이즈 보존).
_setup_termux_boot_script() {
    local boot_dir="$HOME/.termux/boot"
    local script="$boot_dir/start-services"

    mkdir -p "$boot_dir" || return 0
    [ -f "$script" ] && return 0

    cat > "$script" << 'BOOTEOF'
#!/data/data/com.termux/files/usr/bin/sh
# Termux:Boot — 부팅 시 termux-services(runit) 기동
# 서비스 켜기/끄기: sv-enable <서비스> / sv-disable <서비스>
# 상태 확인:      sv status <서비스>

# 활성화된(down 파일이 없는) runit 서비스가 하나라도 있을 때만 wake-lock을 잡는다.
# 활성 서비스가 없으면 락을 잡지 않아 기기가 deep sleep에 들어갈 수 있다(배터리 절약).
for _svc in "$PREFIX/var/service/"*; do
    [ -d "$_svc" ] || continue
    [ -e "$_svc/down" ] && continue
    termux-wake-lock
    break
done

. "$PREFIX/etc/profile.d/start-services.sh"
BOOTEOF
    chmod +x "$script"
}

# x11-repo만 base에서 미리 켠다 (XFCE/firefox/yad 등 termux-main+x11-repo 패키지에 필요).
# tur-repo/root-repo는 켜지 않는다 — 커뮤니티/소규모 저장소라 여기서 미리 켜면 그 저장소
# 장애가 pkg_update를 통해 설치 전체를 깨뜨린다. app-installer가 필요한 앱을 설치할 때
# termux_pkg_enable_repo tur-repo|root-repo로 온디맨드로 켠다.
_setup_termux_repos() {
    pkg_is_installed "x11-repo"  || pkg_install x11-repo
    pkg_update
}

_install_base_packages() {
    local all_pkgs=(
        "${PKGS_TERMUX_BASE[@]}"
        "${PKGS_TERMUX_CLI[@]}"
    )
    if [ "${SKIP_PROOT:-false}" != true ] && [ -n "${PROOT_DISTRO:-}" ]; then
        all_pkgs+=("${PKGS_TERMUX_PROOT[@]}")
    fi

    # 첫 XFCE 설치에서도 기존 dbus 의존 앱이 있을 수 있다. 패키지 제거로 소켓을
    # 리셋하면 의존 앱까지 연쇄 제거하므로, 기존 패키지와 실행 중인 버스는 보존한다.

    local total=${#all_pkgs[@]} i=0
    for p in "${all_pkgs[@]}"; do
        ((++i))
        if pkg_is_installed "$p"; then
            ui_info "  (${i}/${total}) ${p} — 이미 설치됨"
        else
            ui_info "  (${i}/${total}) ${p} 설치 중..."
            pkg_install "$p"
        fi
    done
}

_setup_aliases() {
    local block
    block=$(cat << 'ALIASES'

# termux-xfce-aliases
alias ll='eza -alhgF'
alias ls='eza -lF --icons'
alias cat='bat'
# Zink(OpenGL→Vulkan) 드라이버로 앱 실행: zink glxgears
alias zink='MESA_LOADER_DRIVER_OVERRIDE=zink TU_DEBUG=noconform ZINK_DESCRIPTORS=lazy '
# FPS HUD 오버레이: hud glxgears
alias hud='GALLIUM_HUD=fps '
# proot 앱을 FPS HUD + GPU 가속으로 실행: zrunhud glxgears
alias zrunhud='GALLIUM_HUD=fps MESA_LOADER_DRIVER_OVERRIDE=zink TU_DEBUG=noconform ZINK_DESCRIPTORS=lazy prun '
# GPU 모델 확인
alias gpu-info='cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null || echo "KGSL 미감지 (비-Adreno?)"'
alias shutdown='kill -9 -1'
ALIASES
)

    while IFS= read -r rc; do
        _append_to_rc "# termux-xfce-aliases" "$block" "$rc"
    done < <(_rc_targets)
}

_setup_locale() {
    # 기존 한글 UI 설치에도 수정된 gettext 훅을 배포한다. 새 설치는 선택 항목이다.
    # 기본 설치는 컴파일러를 새로 받지 않고, 갱신에 실패해도 기존 훅으로 계속한다.
    if [ -s "$PREFIX/lib/force_gettext.so" ] && declare -F _build_force_gettext >/dev/null; then
        _build_force_gettext --no-compiler-install ||
            ui_warn "한글 UI 훅을 갱신하지 못해 기존 force_gettext.so를 유지합니다. App Installer의 한글 로케일 업그레이드로 다시 시도할 수 있습니다."
        setup_korean_rc || ui_warn "한글 RC 블록을 갱신하지 못했습니다."
    fi
    local block
    block=$(cat << 'LOCALE'

# termux-xfce-locale
export LANG=ko_KR.UTF-8
export LC_ALL=
export XDG_CONFIG_HOME="$HOME/.config"
# XDG_RUNTIME_DIR은 _setup_xdg_runtime 블록에서 관리 (mode 700 user-private)
LOCALE
)

    while IFS= read -r rc; do
        _append_to_rc "# termux-xfce-locale" "$block" "$rc"
    done < <(_rc_targets)
}

setup_korean_rc() {
    local block
    block=$(cat << 'KOREAN'

# termux-xfce-korean — force_gettext.so 한글 UI 자동 적용
if [ -f "$PREFIX/lib/force_gettext.so" ]; then
    export LANG="ko_KR.UTF-8"
    export LANGUAGE="ko_KR:ko:en_US:en"
    export FORCE_TEXTDOMAINDIR="$PREFIX/share/locale"
    export FALLBACK_DOMAINS="__KOREAN_FALLBACK_DOMAINS__"
    export XDG_DATA_DIRS="$PREFIX/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
    QT_TRANSLATIONS_PATH="$PREFIX/share/qt6/translations:$PREFIX/share/qt/translations${QT_TRANSLATIONS_PATH:+:$QT_TRANSLATIONS_PATH}"
    export QT_TRANSLATIONS_PATH
    export KDE_LANG=ko QT_LOCALE_OVERRIDE=ko_KR
    case "${RUNNING_IN_GLIBC_RUNNER:-false}:${LD_PRELOAD-}:" in true:*|*:"$PREFIX/lib/force_gettext.so":*) ;; *)
        export LD_PRELOAD="$PREFIX/lib/force_gettext.so${LD_PRELOAD:+:$LD_PRELOAD}";; esac
fi
KOREAN
)
    block="${block/__KOREAN_FALLBACK_DOMAINS__/$_KOREAN_FALLBACK_DOMAINS}"
    # A line earlier installers wrote that the current block no longer has.
    # FALLBACK_DOMAINS changed over time, so it is matched by its shape.
    local legacy='    case ":${LD_PRELOAD-}:" in *:"$PREFIX/lib/force_gettext.so":*) ;; *)'

    local rc target staged status
    while IFS= read -r rc; do
        [ -f "$rc" ] || continue
        if ! grep -qF '# termux-xfce-korean' "$rc"; then
            printf '%s\n' "$block" >> "$rc" || return 1
            continue
        fi
        # Replace in place only blocks made entirely of installer lines, so the
        # lines around them keep their order. A block the user edited is left
        # as it is; exit status 3 reports one.
        target=$(readlink -f -- "$rc") || return 1
        staged=$(mktemp "${target}.XXXXXX") || return 1
        status=0
        KOREAN_BLOCK="${block#$'\n'}" KOREAN_LEGACY="$legacy" awk '
            function reject() { printf "%s", held; held = ""; state = 0; unknown = 1 }
            BEGIN {
                n = split(ENVIRON["KOREAN_BLOCK"], current, "\n")
                opener = current[2]
                for (i = 3; i < n; i++) known[current[i]] = 1
                known[ENVIRON["KOREAN_LEGACY"]] = 1
            }
            # 1: after the marker, 2: in the body, 3: in a continued FALLBACK_DOMAINS value
            state == 1 { held = held $0 "\n"; if ($0 == opener) state = 2; else reject(); next }
            state == 3 {
                held = held $0 "\n"
                if ($0 !~ /^[A-Za-z0-9._+ -]*("| \\)$/) reject()
                else if ($0 ~ /"$/) state = 2
                next
            }
            state == 2 {
                held = held $0 "\n"
                if ($0 == "fi") { print ENVIRON["KOREAN_BLOCK"]; held = ""; state = 0; replaced = 1 }
                else if ($0 ~ /^    export FALLBACK_DOMAINS="[A-Za-z0-9._+ -]*("| \\)$/) { if ($0 ~ / \\$/) state = 3 }
                else if (!($0 in known)) reject()
                next
            }
            /^# termux-xfce-korean([[:space:]]|$)/ { held = $0 "\n"; state = 1; next }
            { print }
            END { if (state) reject(); exit (unknown || !replaced) ? 3 : 0 }
        ' "$target" > "$staged" || status=$?
        case "$status" in
            0) ;;
            3) ui_warn "직접 수정된 한글 RC 블록은 그대로 둡니다: $rc" ;;
            *) rm -f -- "$staged"; return 1 ;;
        esac
        if cmp -s "$staged" "$target"; then
            rm -f -- "$staged"
            continue
        fi
        chmod --reference="$target" "$staged" && mv -f -- "$staged" "$target" || {
            rm -f -- "$staged"
            return 1
        }
    done < <(_rc_targets)
}

# XDG runtime dir: mode 700 user-private ($PREFIX/var/run/user/$UID)
# Why: 구버전 _setup_locale가 XDG_RUNTIME_DIR=$TMPDIR(mode 1777, world-writable)을 심어
#      dbus가 "can be written by others" 경고를 띄우며 session bus를 반쯤 고장냄
#      → flameshot/xfdesktop의 DBus 경고도 여기서 파생됨
_setup_xdg_runtime() {
    # 구버전 라인 제거 (마이그레이션)
    while IFS= read -r rc; do
        [ -f "$rc" ] || continue
        sed -i '\#^export XDG_RUNTIME_DIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"$#d' "$rc" 2>/dev/null || true
    done < <(_rc_targets)

    local block
    block=$(cat << 'XDGRT'

# termux-xfce-xdg-runtime
XDG_RUNTIME_DIR="${PREFIX:-/data/data/com.termux/files/usr}/var/run/user/$(id -u)"
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null && chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
fi
export XDG_RUNTIME_DIR
XDGRT
)

    while IFS= read -r rc; do
        _append_to_rc "# termux-xfce-xdg-runtime" "$block" "$rc"
    done < <(_rc_targets)
}

# GPU policy belongs to the session launcher and the optional GPU installers.
# Remove the exact managed block emitted by previous base installs.
_migrate_gpu_rc() {
    local rc
    while IFS= read -r rc; do
        [ -f "$rc" ] || continue
        sed -i '/^# termux-xfce-gpu /,/^fi$/d' "$rc" || return 1
    done < <(_rc_targets)
}

_setup_zsh_p10k() {
    command -v zsh &>/dev/null || return 0

    # Powerlevel10k 설치 — 실패하면 zsh 전환 자체를 건너뜀(chsh/zshrc 변경 없음).
    # set -euo pipefail 하에서 네트워크 실패로 clone이 죽으면 이후 로그인 셸이 이미
    # zsh로 바뀐 채 ~/.zshrc가 없는 상태로 install 전체가 중단되는 걸 방지.
    local p10k_dir="$HOME/powerlevel10k"
    if [ ! -d "$p10k_dir" ]; then
        ui_info "Powerlevel10k 설치 중..."
        if ! git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir"; then
            ui_warn "Powerlevel10k 설치 실패 — zsh 전환을 건너뜁니다"
            return 0
        fi
    fi

    # zsh 플러그인 설치 — 실패해도 계속 진행(zshrc가 [[ -f ... ]] && source 로 방어)
    local plugin_dir="$HOME/.zsh/plugins"
    mkdir -p "$plugin_dir"
    if [ ! -d "$plugin_dir/zsh-autosuggestions" ]; then
        ui_info "zsh-autosuggestions 설치 중..."
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
            "$plugin_dir/zsh-autosuggestions" || ui_warn "zsh-autosuggestions 설치 실패 — 건너뜁니다"
    fi
    if [ ! -d "$plugin_dir/zsh-syntax-highlighting" ]; then
        ui_info "zsh-syntax-highlighting 설치 중..."
        git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
            "$plugin_dir/zsh-syntax-highlighting" || ui_warn "zsh-syntax-highlighting 설치 실패 — 건너뜁니다"
    fi

    # ~/.zshrc: 없으면 신규 생성, 있으면 p10k 블록만 멱등 추가(사용자 커스터마이즈 보존)
    local zshrc="$HOME/.zshrc"
    if [ ! -f "$zshrc" ]; then
        ui_info "$HOME/.zshrc 생성"
        cat > "$zshrc" << 'ZSHRC'
# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# =============================================================================
# 히스토리
# =============================================================================
HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt EXTENDED_HISTORY
setopt SHARE_HISTORY
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_SAVE_NO_DUPS
setopt HIST_REDUCE_BLANKS

# =============================================================================
# 자동 완성
# =============================================================================
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
autoload -U +X bashcompinit && bashcompinit

# =============================================================================
# 플러그인
# =============================================================================
[[ -f ~/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && \
    source ~/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# syntax-highlighting은 반드시 마지막에 로드
[[ -f ~/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && \
    source ~/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# =============================================================================
# Powerlevel10k
# =============================================================================
source ~/powerlevel10k/powerlevel10k.zsh-theme
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# =============================================================================
# 환경변수
# =============================================================================
export EDITOR=nano
export VISUAL=nano
export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"
ZSHRC
    else
        local block
        block=$(cat << 'P10KBLOCK'

# termux-xfce-p10k
[[ -f ~/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && \
    source ~/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ -f ~/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && \
    source ~/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source ~/powerlevel10k/powerlevel10k.zsh-theme
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
P10KBLOCK
)
        _append_to_rc "# termux-xfce-p10k" "$block" "$zshrc"
    fi

    # zsh를 기본 쉘로 설정 — Termux의 chsh는 ~/.termux/shell 심볼릭 링크로 관리됨
    # (일반 Linux의 /etc/passwd 기반 getent는 Termux에선 빈값 반환 → 기존 getent 분기는 사실상 항상 실패)
    # p10k + ~/.zshrc가 준비된 뒤 마지막에 실행 — 실패해도 위 단계는 이미 완료된 상태.
    local zsh_path
    zsh_path=$(command -v zsh)
    local current_shell
    current_shell=$(readlink "$HOME/.termux/shell" 2>/dev/null || echo "")
    if [ "$current_shell" != "$zsh_path" ]; then
        chsh -s zsh 2>/dev/null || true
    fi
}

_setup_input_method() {
    # App Installer owns IME packages and the selected input method. Base setup
    # only imports an existing selection and installs the shared environment hook.
    local helper="${BASH_SOURCE[0]%/*}/../app-installer/lib/input_method.sh"
    if [ ! -r "$helper" ]; then
        ui_error "app-installer 서브모듈이 필요합니다: git submodule update --init"
        return 1
    fi
    source "$helper"
    input_method_setup
}

_setup_start_xfce() {
    # 현재 로드된 display 어댑터 = 설치 시 선택된 서버 → 기본 startXFCE로도 연결
    _build_start_xfce_launcher "${DISPLAY_SERVER:-x11}" default
}

# 특정 디스플레이 서버용 런처 생성.
# 호출 시점에 로드된 display 어댑터(display_emit_*)로 스크립트를 조립하므로,
# install.sh(합성 루트)가 어댑터를 순차 소싱하며 서버별로 호출한다.
_build_start_xfce_launcher() {
    local server="$1" mode="${2:-}"
    local shortcut="$HOME/.shortcuts/startXFCE-${server}"
    mkdir -p "$HOME/.shortcuts"
    script_build_start_xfce "$shortcut"
    chmod +x "$shortcut"
    ln -sf "$shortcut" "$PREFIX/bin/startXFCE-${server}"
    if [ "$mode" = "default" ]; then
        ln -sf "$shortcut" "$HOME/.shortcuts/startXFCE"
        ln -sf "$shortcut" "$PREFIX/bin/startXFCE"
    fi
}

_setup_kill_display() {
    local bin="$PREFIX/bin/kill_display_session"

    mkdir -p "$PREFIX/share/applications"
    script_build_kill_display "$bin"
    chmod +x "$bin"
    cat > "$PREFIX/bin/kill_termux_x11" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec kill_display_session "$@"
EOF
    chmod +x "$PREFIX/bin/kill_termux_x11"
    # The old menu entry duplicates kill_display_session.desktop. A desktop icon
    # is the user's and is migrated by the loop below instead.
    rm -f "$PREFIX/share/applications/kill_termux_x11.desktop"

    cat > "$PREFIX/share/applications/kill_display_session.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Kill Display Session
Exec=kill_display_session
Icon=system-shutdown
Categories=System;
StartupNotify=false
EOF
    local f
    while IFS= read -r -d '' f; do
        if grep -q '^Exec=kill_termux_x11$' "$f"; then
            sed -i -e 's/^Exec=kill_termux_x11$/Exec=kill_display_session/' \
                -e 's/^Name=Kill Termux X11$/Name=Kill Display Session/' \
                -e '/^X-XFCE-Source=.*kill_termux_x11.desktop$/d' "$f" || return 1
        fi
    done < <(find "$HOME/.config/xfce4/panel" "$HOME/Desktop" "$PREFIX/share/applications" \
        -type f -name '*.desktop' -print0 2>/dev/null)
}

_setup_prun() {
    local bin="$PREFIX/bin/prun"

    # PROOT_DISTRO는 설치 시 결정된 값을 config에서 읽음
    cat > "$bin" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
CONFIG="$HOME/.config/termux-xfce/config"
_PRUN_RUNTIME_ENV="${PRUN_RUNTIME:-}"
[ -f "$CONFIG" ] && source "$CONFIG"
# 실행 시 지정한 PRUN_RUNTIME이 config 값보다 우선한다. 기본은 proot(-distro).
PRUN_RUNTIME="${_PRUN_RUNTIME_ENV:-${PRUN_RUNTIME:-proot}}"

_prun_error() {
    echo "[ERROR] $1" >&2
    if [ "${PRUN_GUI:-false}" = true ] && command -v zenity >/dev/null 2>&1; then
        zenity --error --text="$1" 2>/dev/null || true
    fi
    exit 1
}

DISTRO="${PROOT_DISTRO:-}"
if [ -z "$DISTRO" ]; then
    _prun_error "proot 환경이 설정되지 않았습니다. 설치기에 --distro를 지정하세요."
fi
ROOTFS_BASE="$PREFIX/var/lib/proot-distro"
if [ -d "$ROOTFS_BASE/containers/$DISTRO/rootfs" ]; then
    ROOTFS="$ROOTFS_BASE/containers/$DISTRO/rootfs"
else
    ROOTFS="$ROOTFS_BASE/installed-rootfs/$DISTRO"
fi

if [ ! -d "$ROOTFS" ]; then
    _prun_error "proot rootfs를 찾을 수 없습니다: $ROOTFS"
fi

# config에 PROOT_USER 있으면 사용, 없으면 home/ 디렉토리에서 탐색 (alarm 제외)
if [ -n "${PROOT_USER:-}" ]; then
    USER_NAME="$PROOT_USER"
else
    USER_NAME=$(ls "$ROOTFS/home/" 2>/dev/null \
        | grep -v '^alarm$' | head -1)
    USER_NAME="${USER_NAME:-user}"
fi

# LD_PRELOAD 해제: Termux exec 훅이 proot-distro 실행 시 재주입하므로
# unset만으론 부족 → proot 내부 첫 명령을 env -u LD_PRELOAD로 감싼다
unset LD_PRELOAD

# 참고: 호스트 DBUS_SESSION_BUS_ADDRESS를 proot에 전파해도 작동하지 않음
# proot이 getuid()를 위조(예: 10381)하지만 커널 SCM_CREDENTIALS는 실제 UID(10380)를 보고
# → dbus EXTERNAL auth에서 UID 불일치 → 인증 실패
# dbus가 필요한 앱(flameshot 등)은 Termux native로 설치하여 해결

# Inherit the active display, including KWin's dynamically assigned Xwayland.
# A terminal outside a graphical session may still target Termux:X11's default.
export DISPLAY="${DISPLAY:-:0.0}"

# Android Host Info Bridge: 실제 CPU 사용률(/proc/stat)과 기기 정보(DMI·cpuinfo)를 게스트에 공급한다.
# proot는 proot-distro sysdata로 /proc/stat을 받고, 기기 정보만 바인드한다.
# /proc/net은 self/net 심볼릭 링크라 /proc/net/dev 파일 바인드는 적용되지 않는다 — 디렉터리째 가린다
# (원래 안의 파일은 모두 막혀 있다). 네트워크 카운터는 hostinfo_net이 proc_net/dev에 쓴다
HOSTINFO="$PREFIX/tmp/termux-xfce-hostinfo"
HOSTINFO_BINDS=()
if command -v termux-xfce-hostinfo >/dev/null 2>&1 && termux-xfce-hostinfo start >/dev/null 2>&1; then
    HOSTINFO_BINDS=("$HOSTINFO/cpuinfo:/proc/cpuinfo" "$HOSTINFO/dmi:/sys/class/dmi/id"
        "$HOSTINFO/dmi:/sys/devices/virtual/dmi/id" "$HOSTINFO/proc_net:/proc/net")
fi

# PRUN_RUNTIME=chroot-ng: ptrace 없는 chroot-ng(App Installer 'chroot_ng')로 같은 rootfs를 실행한다.
# root 작업(apt/pacman, 사용자 생성)은 계속 proot-distro 몫이다.
if [ "$PRUN_RUNTIME" = chroot-ng ]; then
    CHROOT_NG="$PREFIX/bin/chroot-ng"
    [ -x "$CHROOT_NG" ] || _prun_error "chroot-ng가 없습니다. App Installer에서 'proot 가속 런타임 (chroot-ng)'을 설치하세요."
    # proot-distro --change-id와 같은 신원: rootfs /etc/passwd의 uid:gid와 홈
    read -r GUEST_UID GUEST_GID GUEST_HOME < <(awk -F: -v u="$USER_NAME" \
        '$1 == u { print $3, $4, $6; exit }' "$ROOTFS/etc/passwd" 2>/dev/null)
    [ -n "${GUEST_UID:-}" ] || _prun_error "rootfs에 사용자 ${USER_NAME}이(가) 없습니다."
    # --shared-proc: 실행 간 프로세스를 공유해야 profile.d의 pgrep IME 가드가 동작한다
    # $PREFIX 바인드: proot-distro link2symlink가 남긴 절대경로 링크(.l2s)를 그대로 해석한다
    # 게스트 env는 상속되지 않으므로 proot-distro가 넣던 값을 직접 넘긴다
    CNG=("$CHROOT_NG" --shared-proc --fake-id="$GUEST_UID:$GUEST_GID" -w "$GUEST_HOME"
        -b "$PREFIX:$PREFIX" -b "$PREFIX/tmp:/tmp" -b /sys:/sys
        -E HOME="$GUEST_HOME" -E USER="$USER_NAME" -E LOGNAME="$USER_NAME"
        -E PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/games:/usr/games
        -E DISPLAY="$DISPLAY" -E PULSE_SERVER=127.0.0.1 -E MOZ_FAKE_NO_SANDBOX=1)
    for p in /dev/kgsl-3d0 /dev/dma_heap /sdcard /storage; do
        [ -e "$p" ] && CNG+=(-b "$p:$p")
    done
    for p in "${HOSTINFO_BINDS[@]}"; do CNG+=(-b "$p"); done
    # chroot-ng는 netlink를 에뮬레이션해 인터페이스가 보이는데 Android은 /sys/class/net 통계를 막는다(btop은 그
    # 권한 오류로 죽는다). hostinfo_net이 netstats 서비스 값으로 채우는 디렉터리로 가린다 (proot는 인터페이스가 안 보여 무관)
    [ ${#HOSTINFO_BINDS[@]} -gt 0 ] && CNG+=(-b "$HOSTINFO/stat:/proc/stat" -b "$HOSTINFO/net:/sys/class/net")
    if [ $# -eq 0 ]; then
        exec "${CNG[@]}" "$ROOTFS" /usr/bin/env "${PROOT_SHELL:-bash}" --login
    fi
    exec "${CNG[@]}" "$ROOTFS" /usr/bin/env bash --login -c 'exec "$@"' prun "$@"
fi

PD_BINDS=()
for p in "${HOSTINFO_BINDS[@]}"; do PD_BINDS+=(--bind "$p"); done

# 인자 없으면 PROOT_SHELL(config) 기반 인터랙티브 로그인 셸 실행
if [ $# -eq 0 ]; then
    exec proot-distro login "$DISTRO" --user "$USER_NAME" --shared-tmp "${PD_BINDS[@]}" \
        -- env -u LD_PRELOAD DISPLAY="$DISPLAY" "${PROOT_SHELL:-bash}" --login
else
    exec proot-distro login "$DISTRO" --user "$USER_NAME" --shared-tmp "${PD_BINDS[@]}" \
        -- env -u LD_PRELOAD DISPLAY="$DISPLAY" bash --login -c 'exec "$@"' prun "$@"
fi
EOF

    chmod +x "$bin"
}

# termux-xfce-hostinfo: Android Host Info Bridge
# Android은 앱에 /proc/stat·/proc/schedstat을 막아 게스트 htop/top의 CPU 사용률이 멈춘다
# (proot-distro는 고정 값 파일을 바인드). 코어별 cpuidle 체류 시간으로 실제 값을 만들어
# proot-distro sysdata와 chroot-ng 바인드용 파일을 1초마다 교체하고, 기기 정보(DMI·cpuinfo)를 만든다.
# 막힌 네트워크 통계(/sys/class/net·/proc/net/dev)는 netstats 시스템 서비스 값으로 채운다.
_setup_hostinfo() {
    local bin="$PREFIX/bin/termux-xfce-hostinfo"

    # 실행 중인 데몬이 읽는 inode를 건드리지 않도록 새 파일로 바꿔 넣는다
    cat > "$bin.new" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# 사용: termux-xfce-hostinfo [start|once|build|exec 명령 [인자...]]
#   start  실행 중이 아니면 백그라운드로 띄운다 (prun이 호출, 기본값)
#   once   한 번만 갱신한다 (점검용)
#   build  네이티브 htop용 hostinfo_proc.so 훅과 네트워크 카운터 도우미 hostinfo_net을
#          소스가 바뀌었을 때만 clang으로 빌드한다
#   exec   Termux 네이티브 프로그램(htop·btop 등)에 훅을 붙여 실행한다 (훅이 없고 clang이 있으면 먼저 빌드)
# proot·chroot-ng 게스트도, exec로 띄운 프로그램도 없으면 스스로 종료한다.
# HOSTINFO_DIR / HOSTINFO_CPU_ROOT / HOSTINFO_UPTIME은 테스트용 경로 재지정이다.
OUT="${HOSTINFO_DIR:-$PREFIX/tmp/termux-xfce-hostinfo}"
CPU_ROOT="${HOSTINFO_CPU_ROOT:-/sys/devices/system/cpu}"
UPTIME="${HOSTINFO_UPTIME:-/system/bin/uptime}"   # sysinfo(2) 기반이라 앱에서도 동작
CONTAINERS="$PREFIX/var/lib/proot-distro/containers"
SRC="$PREFIX/libexec/termux-xfce/hostinfo_proc.c"
SHIM="$PREFIX/lib/hostinfo_proc.so"
NETSRC="$PREFIX/libexec/termux-xfce/hostinfo_net.c"
NETBIN="$PREFIX/libexec/termux-xfce/hostinfo_net"
umask 022

declare -A BUSY IDLE LAST LEN
BTIME=0 PREV=0 LOADAVG="0.00 0.00 0.00"

_static_files() {
    local socm hw name
    mkdir -p "$OUT/dmi" "$OUT/net" "$OUT/proc_net" || return 1
    getprop ro.product.manufacturer > "$OUT/dmi/sys_vendor"
    getprop ro.product.model > "$OUT/dmi/product_name"
    getprop ro.board.platform > "$OUT/dmi/board_name"
    socm=$(getprop ro.soc.manufacturer)
    [ "$socm" = QTI ] && socm="Qualcomm Technologies, Inc"
    hw="$socm $(getprop ro.soc.model)"
    # 게스트의 Linux판 fastfetch는 SoC 코드를 이름으로 바꾸지 않는다 — 네이티브 fastfetch가 아는 이름을 쓴다
    name=$(fastfetch --pipe -l none -s CPU --format json 2>/dev/null |
        grep -o '"cpu": *"[^"]*"' | sed 's/^"cpu": *"//; s/"$//')
    [ -n "$name" ] && hw=$name
    # ARM cpuinfo에는 model name이 없어 btop은 /sys/devices 목록을 뒤지다 권한 오류로 죽는다 — 코어마다 넣는다
    { awk -v n="$hw" '{ print } /^processor[ \t]*:/ { print "model name\t: " n }' /proc/cpuinfo
      printf 'Hardware\t: %s\n' "$hw"; } > "$OUT/cpuinfo"
    # 네이티브 btop은 막힌 /proc/filesystems로 실제 디스크 종류를 고른다 — Android 기기 파티션 종류
    printf '\t%s\n' ext4 f2fs erofs vfat exfat > "$OUT/filesystems"
}

_load() {
    local line
    line=$("$UPTIME" 2>/dev/null) || return 0
    line=${line##*load average: }
    LOADAVG=${line//,/}
}

_init() {
    local since
    since=$("$UPTIME" -s 2>/dev/null) && BTIME=$(date -d "$since" +%s 2>/dev/null)
    [ "${BTIME:-0}" -gt 0 ] 2>/dev/null || BTIME=${EPOCHSECONDS}
    _load
}

# 같은 inode에 덮어쓴다: top/vmstat은 /proc/stat fd를 열어 둔 채 되감아 다시 읽으므로
# 파일을 바꿔치기하면 옛 값에 멈춘다. 누적 카운터라 거의 늘기만 하고, 짧아질 때만 잘라 쓴다.
_put() {
    local f="$1" data="$2"
    [ -L "$f" ] && rm -f "$f"
    if [ -n "${LEN[$f]}" ] && [ -f "$f" ] && (( ${#data} >= LEN[$f] )); then
        printf '%s' "$data" 1<> "$f"
    else
        printf '%s' "$data" > "$f"
    fi
    LEN[$f]=${#data}
}

# 코어별 누적 busy/idle(µs)을 갱신하고 /proc/stat·uptime·loadavg를 다시 쓴다.
# 커널은 idle 시간을 idle에서 깰 때 더하므로, 한 구간에서 늘어난 idle은 경과 시간으로 자른다.
_tick() {
    local now w n c t v s d last lines="" tb=0 ti=0 up stat sd
    now=${EPOCHREALTIME/./}
    w=$(( now - PREV ))
    read -r last < "$CPU_ROOT/possible" || last=0
    last=${last##*-}
    for (( n = 0; n <= last; n++ )); do
        c="$CPU_ROOT/cpu$n"
        [ -d "$c" ] || continue
        if [ -r "$c/online" ] && read -r v < "$c/online" && [ "$v" = 0 ]; then
            # 꺼진 코어도 이전 누적값은 전체 cpu 합계에 남긴다. 첫 표본부터 꺼져
            # 있던 코어는 0에서 시작해 나중에 켜질 때 부팅 이후 값이 한꺼번에 더해지지 않게 한다.
            BUSY[$n]=${BUSY[$n]:-0}
            IDLE[$n]=${IDLE[$n]:-0}
            unset 'LAST[$n]'
            continue    # 커널처럼 꺼진 코어는 줄을 뺀다
        fi
        s=0
        for t in "$c"/cpuidle/state*/time; do
            [ -r "$t" ] && read -r v < "$t" && s=$(( s + v ))
        done
        if [ -z "${BUSY[$n]+set}" ]; then
            # 첫 표본은 부팅 이후 누적값으로 시작해, 다시 떠도 카운터가 크게 튀지 않게 한다
            IDLE[$n]=$s
            BUSY[$n]=$(( now - BTIME * 1000000 - s ))
            (( BUSY[$n] < 0 )) && BUSY[$n]=0
        elif [ -n "${LAST[$n]:-}" ]; then
            d=$(( s - LAST[$n] ))
            (( d < 0 )) && d=0
            (( d > w )) && d=$w
            IDLE[$n]=$(( IDLE[$n] + d ))
            BUSY[$n]=$(( BUSY[$n] + w - d ))
        fi
        # 재온라인 첫 표본은 기준만 갱신한다. offline 구간의 idle 증가나
        # cpuidle 카운터 초기화를 현재 한 구간의 사용량으로 계산하지 않는다.
        LAST[$n]=$s
        lines+="cpu$n $(( BUSY[$n] / 10000 )) 0 0 $(( IDLE[$n] / 10000 )) 0 0 0 0 0 0"$'\n'
    done
    for n in "${!BUSY[@]}"; do
        tb=$(( tb + BUSY[$n] / 10000 ))
        ti=$(( ti + IDLE[$n] / 10000 ))
    done
    PREV=$now
    stat="cpu  $tb 0 0 $ti 0 0 0 0 0 0"$'\n'"${lines}intr 0"$'\n'"ctxt 0"$'\n'"btime $BTIME"$'\n'
    stat+="processes 0"$'\n'"procs_running 1"$'\n'"procs_blocked 0"$'\n'"softirq 0 0 0 0 0 0 0 0 0 0 0"$'\n'
    up=$(( now / 10000 - BTIME * 100 ))
    printf -v up '%d.%02d %d.%02d' $(( up / 100 )) $(( up % 100 )) $(( ti / 100 )) $(( ti % 100 ))

    _put "$OUT/stat" "$stat"
    # 네이티브 프로그램은 hostinfo_proc.so 훅이 이 디렉터리의 같은 이름 파일을 대신 연다
    _put "$OUT/uptime" "$up"$'\n'
    _put "$OUT/loadavg" "$LOADAVG 1/1 1"$'\n'
    # proot-distro는 막힌 /proc 항목 대신 sysdata의 같은 이름 파일을 바인드한다
    for sd in "$CONTAINERS"/*/sysdata; do
        [ -d "$sd" ] && [ ! -L "$sd" ] || continue
        _put "$sd/stat" "$stat"
        _put "$sd/uptime" "$up"$'\n'
        _put "$sd/loadavg" "$LOADAVG 1/1 1"$'\n'
    done
}

# exec로 띄운 프로그램은 holders/에 PID를 남긴다 (exec 뒤에도 PID가 그대로다)
_guests_alive() {
    local h
    pgrep -f "^$PREFIX/bin/(proot|chroot-ng)( |$)" >/dev/null 2>&1 && return 0
    for h in "$OUT"/holders/*; do
        [ -e "$h" ] || continue
        [ -d "/proc/${h##*/}" ] && return 0
        rm -f "$h"
    done
    return 1
}

_running() {
    local pid
    read -r pid 2>/dev/null < "$OUT/pid" && kill -0 "$pid" 2>/dev/null &&
        grep -q termux-xfce-hostinfo "/proc/$pid/cmdline" 2>/dev/null
}

# 막힌 네트워크 통계는 hostinfo_net -w가 netstats 서비스 값으로 1초마다 채운다: net/(/sys/class/net 모양)과
# proc_net/dev(/proc/net/dev). 이 데몬이 끝나면 따라 끝나고, 데몬이 뜬 뒤에 빌드됐거나 도중에 끝났으면 다시 띄운다
_net() {
    [ -x "$NETBIN" ] || return 0
    [ -n "${NETPID:-}" ] && kill -0 "$NETPID" 2>/dev/null && return 0
    "$NETBIN" -w "$OUT" &
    NETPID=$!
}

# 기본 설치는 컴파일러를 받지 않으므로 clang이 있을 때만 만든다. 소스 해시가 그대로면 다시 빌드하지 않는다
_build_one() {
    local src="$1" out="$2" hash built
    shift 2
    hash=$(sha256sum "$src" 2>/dev/null) || return 1
    hash=${hash%% *}
    [ -s "$out" ] && [ "$(cat "$out.sha256" 2>/dev/null)" = "$hash" ] && return 0
    command -v clang >/dev/null 2>&1 || return 1
    built=$(mktemp "$out.XXXXXX") || return 1
    if clang -O2 -o "$built" "$src" "$@" && [ -s "$built" ] &&
       chmod 755 "$built" && mv -f "$built" "$out"; then
        printf '%s\n' "$hash" > "$out.sha256"
    else
        rm -f "$built"
        return 1
    fi
}

# 네트워크 도우미는 네트워크 통계만 채우므로 만들지 못해도 훅의 결과만 돌려준다
_build() {
    _build_one "$NETSRC" "$NETBIN"
    _build_one "$SRC" "$SHIM" -shared -fPIC -ldl
}

case "${1:-start}" in
    once)
        _static_files && _init && _tick ;;
    start)
        # btop·htop은 처음 읽은 네트워크 값을 기준으로 삼는다. 파일이 아직 없어 0으로 읽으면 다음 갱신에서
        # 부팅 이후 누적량 전체를 속도로 보므로, 데몬이 떠 있어도 먼저 한 번 쓴다
        [ -x "$NETBIN" ] && mkdir -p "$OUT/net" "$OUT/proc_net" && "$NETBIN" "$OUT"
        _running && exit 0
        _static_files && _init && _tick || exit 1
        nohup "$0" run </dev/null >/dev/null 2>&1 &
        ;;
    run)
        echo $$ > "$OUT/pid"
        _init; _tick; _net
        i=0 idle=0
        while sleep 1; do
            _tick
            (( ++i % 5 )) || _load
            (( i % 10 )) && continue
            # 다른 인스턴스가 이어받았거나 게스트도 exec 프로그램도 20초 넘게 없으면 끝낸다
            read -r pid 2>/dev/null < "$OUT/pid"; [ "$pid" = $$ ] || exit 0
            if _guests_alive; then idle=0; elif (( ++idle >= 2 )); then rm -f "$OUT/pid"; exit 0; fi
            _net
        done
        ;;
    build)
        _build ;;
    exec)
        shift
        [ $# -gt 0 ] || { echo "사용법: termux-xfce-hostinfo exec 명령 [인자...]" >&2; exit 2; }
        # 설치 뒤에 clang이 생겼으면 여기서 처음 한 번 빌드한다(1~2초). 만들 수 없으면 훅 없이 그대로 실행한다
        _build >/dev/null 2>&1
        # 데몬보다 PID를 먼저 남겨 바로 끝나지 않게 한다
        if [ -s "$SHIM" ] && mkdir -p "$OUT/holders" && : > "$OUT/holders/$$" && "$0" start >/dev/null 2>&1; then
            export TERMUX_XFCE_HOSTINFO="$OUT" LD_PRELOAD="$SHIM${LD_PRELOAD:+:$LD_PRELOAD}"
            # Termux btop은 root가 아니면 바로 끝낸다 — 훅이 root로 보이게 하고 막힌 입력을 채운다
            [ "${1##*/}" = btop ] && export TERMUX_XFCE_HOSTINFO_BTOP=1
        fi
        exec "$@"
        ;;
    *)
        echo "사용법: termux-xfce-hostinfo [start|once|build|exec 명령 [인자...]]" >&2; exit 2 ;;
esac
EOF

    chmod +x "$bin.new" && mv -f "$bin.new" "$bin"

    # Termux 네이티브 htop도 막힌 /proc 대신 브리지 파일을 읽도록 훅을 붙여 실행한다
    _build_hostinfo_proc || true
    local block btop_block rc
    block=$(cat << 'HOSTINFO'

# termux-xfce-hostinfo — Android이 막은 /proc/stat 등을 채워 htop에 CPU·부하·업타임 표시
alias htop='termux-xfce-hostinfo exec htop'
HOSTINFO
)
    # 기존 설치의 rc에도 들어가도록 htop 블록과 마커를 따로 둔다
    btop_block=$(cat << 'HOSTINFO'

# termux-xfce-hostinfo btop — Termux btop의 root 검사를 넘기고 막힌 입력을 채운다
alias btop='termux-xfce-hostinfo exec btop'
HOSTINFO
)
    while IFS= read -r rc; do
        _append_to_rc "# termux-xfce-hostinfo" "$block" "$rc"
        _append_to_rc "# termux-xfce-hostinfo btop" "$btop_block" "$rc"
    done < <(_rc_targets)
}

# 네이티브 htop용 /proc 훅과 btop 네트워크 카운터 도우미 소스를 두고 빌드한다. 기본 설치는 컴파일러를
# 새로 받지 않으므로, clang이 없으면 clang이 생긴 뒤 처음 htop을 실행할 때 termux-xfce-hostinfo가 빌드한다.
_build_hostinfo_proc() {
    local libexec="$PREFIX/libexec/termux-xfce"
    mkdir -p "$libexec" &&
        cp -f "${SCRIPT_DIR}/assets/hostinfo_proc.c" "${SCRIPT_DIR}/assets/hostinfo_net.c" "$libexec/" || return 1
    if ! command -v clang >/dev/null 2>&1; then
        ui_info "clang이 없어 네이티브 htop 훅은 clang이 설치된 뒤 처음 htop을 실행할 때 빌드됩니다."
        return 0
    fi
    "$PREFIX/bin/termux-xfce-hostinfo" build ||
        { ui_warn "네이티브 htop용 /proc 훅(hostinfo_proc.so) 빌드에 실패했습니다."; return 1; }
}

# prun-gui: proot GUI 앱 실행 시 로딩 알림 표시
# proot-distro login은 콜드 스타트에 10–30초 걸려 사용자가 실행 여부를 알기 어려움
# → notify-send로 "로딩 중" 토스트를 먼저 띄우고 prun exec
_setup_prun_gui() {
    local bin="$PREFIX/bin/prun-gui"

    cat > "$bin" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# 사용: prun-gui "AppName" -- <proot 내부 명령...>
# "--" 는 선택. 없으면 $1 이후 전부 명령으로 간주.
if [ $# -eq 0 ]; then
    echo '사용법: prun-gui "AppName" -- command [args...]' >&2
    exit 2
fi
NAME="$1"; shift
[ "${1:-}" = "--" ] && shift
[ $# -gt 0 ] || { echo "[ERROR] 실행할 명령이 없습니다." >&2; exit 2; }
export PRUN_GUI=true

if command -v notify-send >/dev/null 2>&1; then
    notify-send -t 30000 -i system-run \
        "$NAME" "로딩 중... (proot 컨테이너 기동, 최대 30초)" \
        >/dev/null 2>&1 &
fi

exec prun "$@"
EOF

    chmod +x "$bin"

    # 기존 .desktop 파일 중 prun을 쓰는 항목을 prun-gui로 마이그레이션
    _migrate_desktop_to_prun_gui
}

# 기존 설치된 .desktop 파일의 Exec=...prun ... → prun-gui 마이그레이션
# 신규 설치는 desktop_copy_from_proot / desktop_register가 처리하므로
# 이 함수는 업그레이드 시 기존 파일만 패치
_migrate_desktop_to_prun_gui() {
    local apps_dir="$PREFIX/share/applications"
    local helper="${BASH_SOURCE[0]%/*}/../app-installer/domain/desktop.sh"
    source "$helper" || return 1
    local f
    for f in "$apps_dir"/*.desktop "$HOME/Desktop"/*.desktop; do
        [ -f "$f" ] || continue
        desktop_migrate_proot_launcher "$f" || ui_warn "기존 런처를 보존합니다: $f"
    done
}

_setup_app_installer() {
    local bin="$PREFIX/bin/app-installer"
    local desktop="$PREFIX/share/applications/app-installer.desktop"
    local installer_path_q
    printf -v installer_path_q '%q' "${SCRIPT_DIR}/app-installer/install.sh"

    # SCRIPT_DIR은 install.sh 실행 시점 기준 — curl-pipe(~/.termux-xfce-installer),
    # 수동 clone(~/usix-termux) 양쪽 모두 정확한 경로를 기록한다.
    # 항상 재생성하여 SCRIPT_DIR 변경을 반영한다.
    cat > "$bin" << EOF
#!/data/data/com.termux/files/usr/bin/bash
# GTK4 zenity: Zink+Turnip GLX 스왑체인 크래시 방지
export GSK_RENDERER=cairo
exec bash ${installer_path_q} "\$@"
EOF
    chmod +x "$bin"

    if [ ! -f "$desktop" ]; then
        mkdir -p "$PREFIX/share/applications"
        cat > "$desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=App Installer
Exec=app-installer
Icon=appimagekit-pioneer_install_icon
Categories=System;
Terminal=false
StartupNotify=false
EOF
    fi

    # 데스크탑 바탕화면 아이콘 (phoenixbyrd 방식)
    local desktop_icon="$HOME/Desktop/App-Installer.desktop"
    if [ ! -f "$desktop_icon" ]; then
        mkdir -p "$HOME/Desktop"
        cat > "$desktop_icon" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=App Installer
Exec=app-installer
Icon=appimagekit-pioneer_install_icon
Categories=System;
Terminal=false
StartupNotify=false
EOF
        chmod +x "$desktop_icon"
        gio set "$desktop_icon" metadata::trusted true 2>/dev/null || true
    fi
}

_setup_cp2menu() {
    local bin="$PREFIX/bin/cp2menu"
    local helper="${BASH_SOURCE[0]%/*}/../app-installer/domain/desktop.sh"

    mkdir -p "$PREFIX/share/applications" "$PREFIX/libexec/termux-xfce"
    # cp2menu reads the checkout's helper and falls back to this copy, refreshed
    # on every run, when the checkout has been moved or deleted.
    cp -- "$helper" "$PREFIX/libexec/termux-xfce/desktop.sh" || return 1
    script_build_cp2menu "$bin" "$helper" || return 1
    chmod +x "$bin"

    cat > "$PREFIX/share/applications/cp2menu.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=cp2menu
Exec=cp2menu
Icon=edit-move
Categories=System;
Terminal=false
StartupNotify=false
EOF
}

_setup_clipboard_sync() {
    local bin="$PREFIX/bin/termux-clipboard-sync"
    mkdir -p "$(dirname "$bin")"

    cat > "$bin" << 'SYNCEOF'
#!/data/data/com.termux/files/usr/bin/bash
# Android ↔ X11 클립보드 양방향 동기화 데몬
PREV_ANDROID="" PREV_X11=""
while true; do
    sleep 2
    ANDROID=$(termux-clipboard-get 2>/dev/null) || continue
    if ! X11=$(DISPLAY="${DISPLAY:-:0}" xclip -selection clipboard -o 2>/dev/null); then
        if DISPLAY="${DISPLAY:-:0}" xclip -selection clipboard -t TARGETS -o >/dev/null 2>&1; then
            # The owner offers no text (a copied image, for example). Keep it
            # until Android receives a newer copy.
            X11="$PREV_X11"
        else
            # A fresh X11 session has no selection owner. Seed it from Android
            # instead of waiting for an X11 application to copy something first.
            printf '%s' "$ANDROID" | DISPLAY="${DISPLAY:-:0}" xclip -selection clipboard -i 2>/dev/null || continue
            X11="$ANDROID"
        fi
    fi
    if [ "$ANDROID" != "$PREV_ANDROID" ] && [ "$ANDROID" != "$X11" ]; then
        printf '%s' "$ANDROID" | DISPLAY="${DISPLAY:-:0}" xclip -selection clipboard -i 2>/dev/null || continue
    elif [ "$X11" != "$PREV_X11" ] && [ "$X11" != "$ANDROID" ]; then
        termux-clipboard-set "$X11" 2>/dev/null || continue
    fi
    PREV_ANDROID="$ANDROID" PREV_X11="$X11"
done
SYNCEOF
    chmod +x "$bin"
}

_setup_screenshot() {
    local bin="$PREFIX/bin/screenshot"
    mkdir -p "${bin%/*}"
    cat > "$bin" << 'SHOTEOF'
#!/data/data/com.termux/files/usr/bin/bash
# Usage: screenshot [full|region|window]
set -eu
mode="${1:-full}"
case "$mode" in full|region|window) ;; *) echo '사용법: screenshot [full|region|window]' >&2; exit 2 ;; esac
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
    command -v spectacle >/dev/null 2>&1 || {
        echo '[ERROR] Wayland 캡처에는 Spectacle이 필요합니다: pkg install spectacle' >&2
        exit 1
    }
    case "$mode" in
        full) set -- --fullscreen ;;
        region) set -- --region ;;
        window) set -- --activewindow ;;
    esac
    exec env QT_QPA_PLATFORM=wayland spectacle "$@"
else
    case "$mode" in
        full) set -- -f ;;
        region) set -- -r ;;
        window) set -- -w ;;
    esac
    exec xfce4-screenshooter "$@"
fi
SHOTEOF
    chmod +x "$bin"
}

# Only enable Conky when a configured container can run it. The preset uses
# TryExec so native-only installs do not emit startup errors.
_setup_conky_autostart() {
    local bin="$PREFIX/bin/termux-xfce-conky"
    mkdir -p "${bin%/*}"
    cat > "$bin" << 'CONKY'
#!/data/data/com.termux/files/usr/bin/bash
[ ! -r "$HOME/.config/termux-xfce/config" ] || . "$HOME/.config/termux-xfce/config"
[ -n "${PROOT_DISTRO:-}" ] || exit 0
base="$PREFIX/var/lib/proot-distro"
[ -d "$base/containers/$PROOT_DISTRO/rootfs" ] || [ -d "$base/installed-rootfs/$PROOT_DISTRO" ] || exit 0
[ $# -gt 0 ] || set -- -c .config/conky/Alterf/Alterf.conf
exec prun conky "$@"
CONKY
    chmod +x "$bin"
    local desktop="$HOME/.config/autostart/conky.desktop"
    if [ -f "$desktop" ] && grep -q '^Exec=prun conky ' "$desktop"; then
        sed -i 's|^Exec=prun conky |Exec=termux-xfce-conky |' "$desktop"
    fi
}
