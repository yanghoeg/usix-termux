#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# DOMAIN: xfce_env.sh
# -----------------------------------------------------------------------------
# XFCE 환경 구성 도메인 로직 (Termux native)
# - 기존 xfce.sh 통합 및 멱등성 확보
# - 테마, 폰트, 배경화면, fancybash
# =============================================================================

# Immutable upstream release archives, verified after download. The two themes
# ship their release payloads inside GitHub's tagged source archives.
_WHITESUR_VER="2026-09-10"
_WHITESUR_URL="https://github.com/vinceliuice/WhiteSur-gtk-theme/archive/refs/tags/${_WHITESUR_VER}.zip"
_WHITESUR_SHA256="e06899f596706ad9a4aace9bec5f739d63e7f54530a488670026b027d915081c"
_FLUENT_VER="2026-07-27"
_FLUENT_URL="https://github.com/vinceliuice/Fluent-icon-theme/archive/refs/tags/${_FLUENT_VER}.zip"
_FLUENT_SHA256="7b98420a734536ae53ae0a89a1adc767de5961ea7f6948a93af82563db4cca27"
_CASCADIA_VER="2407.24"
_CASCADIA_URL="https://github.com/microsoft/cascadia-code/releases/download/v${_CASCADIA_VER}/CascadiaCode-${_CASCADIA_VER}.zip"
_CASCADIA_SHA256="e67a68ee3386db63f48b9054bd196ea752bc6a4ebb4df35adce6733da50c8474"
_MESLO_VER="3.5.1"
_MESLO_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v${_MESLO_VER}/Meslo.zip"
_MESLO_SHA256="fb104893ecd8f57e8afacbc0a7086b42657120448d056d6093c728a9afb8e237"

_download_verified_asset() {
    local url="$1" target="$2" expected_sha256="$3"
    wget -q "$url" -O "$target" || return 1
    printf '%s  %s\n' "$expected_sha256" "$target" | sha256sum -c - >/dev/null 2>&1 || {
        rm -f "$target"
        return 1
    }
}

_repo_asset_path() {
    local name="$1"
    local candidate="${SCRIPT_DIR:-}/$name"
    if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/$name"
    [ -f "$candidate" ] || return 1
    printf '%s\n' "$candidate"
}

_install_repo_asset() {
    local name="$1" target="$2" source_path
    source_path=$(_repo_asset_path "$name") || {
        ui_warn "저장소 자산을 찾을 수 없습니다: $name"
        return 1
    }
    cp "$source_path" "$target"
}

# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------

setup_xfce_packages() {
    ui_info "XFCE 패키지 설치"
    # 패키지 설치 전에 Desktop 생성 — desktop-file-utils trigger가
    # pkg install 중에 ~/Desktop에 .desktop 파일을 복사하려 시도하기 때문
    mkdir -p "$HOME/Desktop"

    local -a _pkgs=("${PKGS_TERMUX_XFCE[@]}")
    local total=${#_pkgs[@]} i=0
    for p in "${_pkgs[@]}"; do
        ((++i))
        if pkg_is_installed "$p"; then
            ui_info "  (${i}/${total}) ${p} — 이미 설치됨"
        else
            ui_info "  (${i}/${total}) ${p} 설치 중..."
            pkg_install "$p"
        fi
    done

    # 디스플레이 서버 패키지 설치
    local _dp
    local -a _dp_arr
    IFS=' ' read -ra _dp_arr <<< "$(display_get_packages)"
    for _dp in "${_dp_arr[@]}"; do
        if pkg_is_installed "$_dp"; then
            ui_info "  ${_dp} — 이미 설치됨 (display)"
        else
            ui_info "  ${_dp} 설치 중... (display)"
            pkg_install "$_dp"
        fi
    done

    # Firefox 데스크탑 아이콘
    local firefox_desktop="$HOME/Desktop/firefox.desktop"
    [ -f "$firefox_desktop" ] || \
        cp "$PREFIX/share/applications/firefox.desktop" "$firefox_desktop" 2>/dev/null || true
    if [ -f "$firefox_desktop" ]; then
        chmod +x "$firefox_desktop"
        gio set "$firefox_desktop" metadata::trusted true 2>/dev/null || true
    fi
}

setup_xfce_theme() {
    # 테마/커서는 선택적 — 다운로드 실패 시 경고만 출력하고 계속 진행
    ui_info "WhiteSur-Dark 테마 설치"
    _install_whitesur_theme || true
    ui_info "Fluent 커서 아이콘 설치"
    _install_fluent_cursor || true
}

setup_xfce_fonts() {
    # 폰트는 선택적 — 다운로드 실패 시 경고만 출력하고 계속 진행
    ui_info "폰트 설치 (CascadiaCode, Meslo Nerd, Noto Emoji)"
    mkdir -p "$HOME/.fonts"
    _install_cascadia_code || true
    _install_meslo_nerd    || true
    _install_noto_emoji    || true
    _install_termux_font   || true
    # fontconfig 캐시 갱신: MesloLGS NF 등 신규 폰트를 xfce4-terminal이 FontName으로 찾을 수 있게 함
    command -v fc-cache >/dev/null && fc-cache -f "$HOME/.fonts" 2>/dev/null || true
}

setup_xfce_wallpaper() {
    # 배경화면은 선택적 — 다운로드 실패 시 경고만 출력하고 계속 진행
    ui_info "배경화면 다운로드"
    local bg_dir="$PREFIX/share/backgrounds/xfce"
    mkdir -p "$bg_dir"

    [ -f "$bg_dir/dark_waves.png" ] || \
        _install_repo_asset "dark_waves.png" "$bg_dir/dark_waves.png" || true
    [ -f "$bg_dir/TheSolarSystem.jpg" ] || \
        _install_repo_asset "TheSolarSystem.jpg" "$bg_dir/TheSolarSystem.jpg" || true
}

setup_xfce_fancybash() {
    local username="$1"
    ui_info "fancybash 설치 (Termux)"
    _install_fancybash "$username" "termux"
}

# XFCE 전용 autostart 항목을 Plasma(Wayland) 세션에서 제외한다.
# Why: conky는 prun으로 XFCE 세션 디스플레이에 붙어 Plasma에서 SIGSEGV로 죽고,
#      fix-x11-input은 Termux:X11 전용 우회, nimf는 Anland가 안드로이드 키보드를
#      Wayland text-input으로 직접 넘겨주므로 불필요하다. 중복 프로세스는 메모리
#      압박을 키워 LMK가 plasmashell을 죽이는 원인이 된다.
# NotShowIn=KDE also supports existing X11 launchers without XDG_CURRENT_DESKTOP.
_migrate_autostart_not_show_in_kde() {
    local dir="$HOME/.config/autostart" f
    for f in conky.desktop fix-x11-input.desktop org.flameshot.Flameshot.desktop nimf.desktop; do
        [ -f "$dir/$f" ] || continue
        grep -q '^NotShowIn=' "$dir/$f" 2>/dev/null && continue
        # 기존 설치본의 사용자 오버라이드는 Type 줄이 없을 수 있어 그룹 헤더에 붙인다.
        grep -q '^\[Desktop Entry\]$' "$dir/$f" 2>/dev/null || continue
        sed -i '0,/^\[Desktop Entry\]$/s//[Desktop Entry]\nNotShowIn=KDE;/' "$dir/$f"
    done
    # set -e 하에서 마지막 grep 실패 상태가 새어나가 설치가 중단되지 않도록 한다.
    return 0
}

setup_xfce_autostart() {
    ui_info "자동시작 설정 (Conky, Flameshot)"
    _setup_autostart_config
    _disable_conky_autostart
    _migrate_fix_x11_input
    _migrate_autostart_not_show_in_kde
    _migrate_flameshot_native
    _migrate_terminal_font
    _migrate_borderless_maximize
    _migrate_disable_compositing
    _migrate_remove_actions_plugin
    _migrate_dbus_propagate_path
    _migrate_conky_exec_ampersand
    _migrate_screenshot_keybindings
    _migrate_terminal_disable_server
    _setup_terminal_override
}

# -----------------------------------------------------------------------------
# Private
# -----------------------------------------------------------------------------

# Network download paths are pinned above. Focused tests cover idempotency and
# checksum rejection; full archive extraction remains an end-to-end concern.

_install_whitesur_theme() (
    local theme_dir="$PREFIX/share/themes/WhiteSur-Dark"
    [ -d "$theme_dir" ] && return 0  # 멱등성

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    local zip="WhiteSur-${_WHITESUR_VER}.zip"
    _download_verified_asset "$_WHITESUR_URL" "$tmpdir/$zip" "$_WHITESUR_SHA256" \
        || { ui_warn "WhiteSur 테마 다운로드 실패"; return 1; }
    unzip -o -q "$tmpdir/$zip" -d "$tmpdir" \
        || { ui_warn "WhiteSur 테마 압축 해제 실패"; return 1; }
    tar -xf "$tmpdir/WhiteSur-gtk-theme-${_WHITESUR_VER}/release/WhiteSur-Dark.tar.xz" -C "$tmpdir" \
        || { ui_warn "WhiteSur 테마 tar 해제 실패"; return 1; }
    mv "$tmpdir/WhiteSur-Dark/" "$PREFIX/share/themes/"
)

_install_fluent_cursor() (
    local cursor_dir="$PREFIX/share/icons/dist-dark"
    [ -d "$cursor_dir" ] && return 0  # 멱등성

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    local zip="Fluent-${_FLUENT_VER}.zip"
    _download_verified_asset "$_FLUENT_URL" "$tmpdir/$zip" "$_FLUENT_SHA256" \
        || { ui_warn "Fluent 커서 다운로드 실패"; return 1; }
    unzip -o -q "$tmpdir/$zip" -d "$tmpdir" \
        || { ui_warn "Fluent 커서 압축 해제 실패"; return 1; }
    # proot-only 클린 설치에서는 native XFCE 패키지가 이 경로를 만들지 않는다.
    mkdir -p "$PREFIX/share/icons"
    rm -rf "$PREFIX/share/icons/dist" "$PREFIX/share/icons/dist-dark"
    mv "$tmpdir/Fluent-icon-theme-${_FLUENT_VER}/cursors/dist"      "$PREFIX/share/icons/"
    mv "$tmpdir/Fluent-icon-theme-${_FLUENT_VER}/cursors/dist-dark" "$PREFIX/share/icons/"
)

_install_cascadia_code() (
    [ -f "$HOME/.fonts/CascadiaCode-Regular.otf" ] && return 0

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    local zip="CascadiaCode-${_CASCADIA_VER}.zip"
    _download_verified_asset "$_CASCADIA_URL" "$tmpdir/$zip" "$_CASCADIA_SHA256" \
        || { ui_warn "CascadiaCode 폰트 다운로드 실패"; return 1; }
    unzip -q "$tmpdir/$zip" -d "$tmpdir" \
        || { ui_warn "CascadiaCode 폰트 압축 해제 실패"; return 1; }
    mv "$tmpdir/otf/static/"*.otf "$HOME/.fonts/" 2>/dev/null || true
    mv "$tmpdir/ttf/"*.ttf       "$HOME/.fonts/" 2>/dev/null || true
)

_install_meslo_nerd() (
    # ryanoasis/nerd-fonts v3.5.1 Meslo.zip은 "MesloLGSNerdFont-Regular.ttf" 형태로 압축
    # (family: "MesloLGS Nerd Font" / "MesloLGS Nerd Font Mono")
    [ -f "$HOME/.fonts/MesloLGSNerdFont-Regular.ttf" ] && return 0

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    _download_verified_asset "$_MESLO_URL" "$tmpdir/Meslo.zip" "$_MESLO_SHA256" \
        || { ui_warn "Meslo Nerd Font 다운로드 실패"; return 1; }
    unzip -q "$tmpdir/Meslo.zip" -d "$tmpdir/meslo_tmp" \
        || { ui_warn "Meslo Nerd Font 압축 해제 실패"; return 1; }
    mv "$tmpdir/meslo_tmp/"*.ttf "$HOME/.fonts/" 2>/dev/null || true
)

_install_noto_emoji() {
    [ -f "$HOME/.fonts/NotoColorEmoji-Regular.ttf" ] && return 0
    _install_repo_asset "NotoColorEmoji-Regular.ttf" \
        "$HOME/.fonts/NotoColorEmoji-Regular.ttf"
}

_install_termux_font() {
    [ -f "$HOME/.termux/font.ttf" ] && return 0
    _install_repo_asset "font.ttf" "$HOME/.termux/font.ttf"
}

_install_fancybash() {
    local username="$1"
    local hostname="${2:-termux}"
    local target="$HOME/.fancybash.sh"

    [ -f "$target" ] && return 0

    _install_repo_asset "fancybash.sh" "$target" || return 1

    # 사용자명/호스트명 치환 (line 326, 327은 원본 기준)
    # PROMT_USER/PROMT_HOST 정의 라인으로 한정 — 라인 미지정 시 TRIANGLE 구분자 등
    # 무관한 유니코드 이스케이프의 첫 \u,\h 까지 손상됨
    sed -i "/local PROMT_USER=/s/\\\\u/${username}/" "$target"
    sed -i "/local PROMT_HOST=/s/\\\\h/${hostname}/" "$target"

    local bashrc="$PREFIX/etc/bash.bashrc"
    grep -q "source.*\.fancybash\.sh" "$bashrc" 2>/dev/null || \
        echo "source \$HOME/.fancybash.sh" >> "$bashrc"
}

# --no-conky: 자동시작 항목만 숨긴다. 파일은 남겨 XFCE "세션 및 시작 프로그램"에서 다시 켤 수 있다.
# Why: conky가 떠 있으면 proot 게스트가 살아 있어 termux-xfce-hostinfo도 1초마다 계속 돈다.
#      플래그 없이 재설치할 때는 건드리지 않아 사용자가 끈 설정을 되살리지 않는다.
_disable_conky_autostart() {
    [ "${SKIP_CONKY:-false}" = true ] || return 0
    local desktop="$HOME/.config/autostart/conky.desktop"
    [ -f "$desktop" ] || return 0
    grep -qx 'Hidden=true' "$desktop" && return 0
    sed -i '/^Hidden=/d' "$desktop"
    echo 'Hidden=true' >> "$desktop"
}

# 자동시작 + XFCE 프리셋(.config 하위 전체) 1회성 배포
# 가드가 conky.desktop 하나만 체크하는 이유:
#   - tar/config/.config/ 하위엔 Thunar/, Mousepad/, xfce4/, mimeapps.list 등이 함께 들어있음
#   - 사용자가 재설치/재실행 시 자신의 XFCE 커스터마이즈(패널 배치, 단축키 변경 등)를
#     덮어쓰지 않기 위해 의도적으로 광범위 가드 사용 — "첫 설치 프리셋"으로만 작동
#   - tar/config/ 내용이 업데이트되어 기존 사용자에게 반영이 필요하면
#     _migrate_terminal_font()처럼 "구 값 감지 → 선택적 치환" 패턴의 마이그레이션 함수를 별도로 추가할 것
_setup_autostart_config() {
    local autostart_dir="$HOME/.config/autostart"
    [ -d "$autostart_dir" ] && \
        [ -f "$autostart_dir/conky.desktop" ] && return 0  # 멱등성 (위 주석 참조)

    mkdir -p "$autostart_dir"

    # install.sh:28-35이 curl-pipe 실행을 git clone으로 재시작하므로 SCRIPT_DIR은 항상 존재
    # (과거엔 config.tar.gz wget 폴백이 있었으나 해당 아티팩트 미발행 → 제거)
    cp -rn "${SCRIPT_DIR}/tar/config/.config/." "$HOME/.config/"

    chmod +x "$autostart_dir/conky.desktop" 2>/dev/null || true
    chmod +x "$autostart_dir/org.flameshot.Flameshot.desktop" 2>/dev/null || true
}

# 기존 설치본의 xfce4-terminal 폰트를 Nerd Font로 갱신 (p10k 아이콘 렌더링용)
# Why: _setup_autostart_config가 cp -rn로 보호되어 재설치 시 신규 terminalrc가 적용되지 않음
# Note: "MesloLGS NF"는 romkatv/p10k-media 전용 이름이며 ryanoasis Meslo.zip의 family는
#       "MesloLGS Nerd Font Mono" — fc-match로 확인함 (fallback 방지)
# Note: xfce4-terminal ≥ 1.1은 terminalrc → xfconf xml로 이관됨 → 양쪽 모두 갱신
# Termux:X11 포커스 복귀 시 입력 오류 수정용 autostart 추가
# Why: 다른 앱 전환 후 X11로 돌아오면 터치→우클릭 오작동, 방향키 불가 현상 발생
#      _setup_autostart_config의 cp -rn + 멱등 가드로 기존 설치본에는 반영 안 됨
_migrate_fix_x11_input() {
    local src="${SCRIPT_DIR}/tar/config/.config/autostart/fix-x11-input.desktop"
    local dst="$HOME/.config/autostart/fix-x11-input.desktop"
    [ -f "$src" ] || return 0  # 소스 없으면 건너뜀
    # 항상 덮어씀 — xdotool alt 고착 해제 등 내용이 업데이트될 수 있음
    cp "$src" "$dst"
}

# 기존 설치본의 flameshot autostart를 prun → native로 전환
# Why: 6cb9166에서 flameshot을 Termux native로 이동했으나
#      _setup_autostart_config의 cp -rn + 멱등 가드로 기존 파일이 업데이트되지 않음
# Issue: #2 — proot dbus EXTERNAL auth UID 불일치로 flameshot DBus 연결 실패
_migrate_flameshot_native() {
    local desktop="$HOME/.config/autostart/org.flameshot.Flameshot.desktop"
    [ -f "$desktop" ] || return 0
    grep -q "Exec=prun " "$desktop" 2>/dev/null || return 0
    sed -i 's#Exec=prun flameshot#Exec=flameshot#g' "$desktop"
}

_migrate_terminal_font() {
    local target="MesloLGS Nerd Font Mono 12"
    local old='Cascadia Mono PL|MesloLGS NF'

    # 1) terminalrc (xfce4-terminal < 1.1)
    local rc="$HOME/.config/xfce4/terminal/terminalrc"
    if [ -f "$rc" ] && grep -qE "^FontName=($old)" "$rc" 2>/dev/null; then
        sed -i -E "s#^FontName=($old).*#FontName=${target}#" "$rc"
    fi

    # 2) xfconf xml (xfce4-terminal ≥ 1.1 — 최초 실행 시 terminalrc를 xfconf로 이관,
    #   이후 terminalrc는 무시됨. 설치 후 재로그인에서 이관이 일어나도 cover하도록 xml도 수정)
    local xml="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-terminal.xml"
    if [ -f "$xml" ] && grep -qE "name=\"font-name\"[^/]*value=\"($old)" "$xml" 2>/dev/null; then
        sed -i -E "s#(name=\"font-name\"[^/]*value=)\"($old)[^\"]*\"#\\1\"${target}\"#" "$xml"
    fi
}

# 기존 설치본의 borderless_maximize 끄기 — 최대화 시 타이틀바(닫기 버튼) 숨김 방지
# Why: borderless_maximize=true면 최대화된 창의 닫기/최소화 버튼이 사라져
#      모바일 환경에서 창을 닫을 방법이 없어짐
_migrate_borderless_maximize() {
    local xml="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
    [ -f "$xml" ] || return 0
    grep -q 'name="borderless_maximize"[^/]*value="true"' "$xml" 2>/dev/null || return 0
    sed -i 's#name="borderless_maximize" type="bool" value="true"#name="borderless_maximize" type="bool" value="false"#' "$xml"
}

# 기존 설치본의 컴포지터 끄기 — Zink(GPU) + 컴포지터 조합이 검은 화면 유발
# Why: Adreno GPU에서 MESA_LOADER_DRIVER_OVERRIDE=zink + use_compositing=true면
#      Termux:X11 화면이 검은색으로만 표시되어 데스크탑을 사용할 수 없음
_migrate_disable_compositing() {
    local xml="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
    [ -f "$xml" ] || return 0
    grep -q 'name="use_compositing"[^/]*value="true"' "$xml" 2>/dev/null || return 0
    sed -i 's#name="use_compositing" type="bool" value="true"#name="use_compositing" type="bool" value="false"#' "$xml"
}

# 패널에서 XFCE actions 플러그인 제거 — Termux에 systemd/logind 없어서
# shutdown/reboot 비활성화, logout도 정상 종료 불가 → Kill Termux X11 버튼만 유지
_migrate_remove_actions_plugin() {
    local xml="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
    [ -f "$xml" ] || return 0
    grep -q 'value="actions"' "$xml" 2>/dev/null || return 0
    # Plugin IDs belong to the user configuration, not to the preset. Discover
    # actions definitions first, then remove only their plugin-ids references and
    # complete definition blocks. Stage both changes together so an awk failure
    # also preserves the original panel references.
    local tmp
    tmp=$(mktemp "${xml}.tmp.XXXXXX") || {
        ui_warn "xfce4-panel 마이그레이션 임시 파일 생성 실패 — 건너뜁니다."
        return 0
    }
    awk '
        function attribute(line, key, value) {
            if (!match(line, "(^|[[:space:]])" key "=\"[^\"]*\"")) return ""
            value = substr(line, RSTART, RLENGTH)
            sub(/^[^\"]*\"/, "", value)
            sub(/\"$/, "", value)
            return value
        }
        function property_delta(line, opens, selfclose, closes) {
            opens = gsub(/<property([[:space:]][^>]*)?>/, "&", line)
            selfclose = gsub(/<property([[:space:]][^>]*)?\/>/, "&", line)
            closes = gsub(/<\/property>/, "&", line)
            return opens - selfclose - closes
        }
        FNR == NR {
            name = attribute($0, "name")
            if (/<property[[:space:]]/ && name ~ /^plugin-[0-9]+$/ &&
                attribute($0, "value") == "actions") actions[substr(name, 8)] = 1
            next
        }
        {
            delta = property_delta($0)
            if (skip_depth > 0) { skip_depth += delta; next }
            name = attribute($0, "name")
            if (/<property[[:space:]]/ && name ~ /^plugin-[0-9]+$/ &&
                substr(name, 8) in actions) { skip_depth = delta; next }
            if (name == "plugin-ids" && delta > 0) ids_depth = depth + 1
            if (ids_depth > 0 && /<value[[:space:]]/ &&
                attribute($0, "value") in actions) next
            print
            depth += delta
            if (depth < ids_depth) ids_depth = 0
        }
    ' "$xml" "$xml" > "$tmp" && mv "$tmp" "$xml" || {
        rm -f "$tmp"
        ui_warn "xfce4-panel actions 플러그인 제거 마이그레이션 실패 — 건너뜁니다."
        return 0
    }
}

# 기존 설치본의 dbus-propagate autostart에서 /usr/bin/env → bash 직접 호출로 전환
# Why: Termux에는 /usr/bin/env가 없어 XFCE autostart 실행 시 절대경로 해석 실패
#      → dbus activation 환경 전파가 완전히 무동작 상태
_migrate_dbus_propagate_path() {
    local desktop="$HOME/.config/autostart/00-env-dbus-propagate.desktop"
    [ -f "$desktop" ] || return 0
    grep -q '/usr/bin/env' "$desktop" 2>/dev/null || return 0
    sed -i 's|Exec=/usr/bin/env bash|Exec=bash|' "$desktop"
}

# 기존 설치본의 conky autostart Exec 끝 '&' 제거
# Why: desktop entry 스펙에서 Exec 값은 셸 해석 없이 직접 실행되므로
#      '&'가 conky 인자로 전달되어 실행 실패 가능
_migrate_conky_exec_ampersand() {
    local desktop="$HOME/.config/autostart/conky.desktop"
    [ -f "$desktop" ] || return 0
    grep -q 'Exec=.*&$' "$desktop" 2>/dev/null || return 0
    sed -i 's| &$||' "$desktop"
}

# 기존 설치본의 Print 계열 스크린샷 키를 세션 인식 래퍼(screenshot)로 전환
# The wrapper selects Spectacle for KWin/Wayland and xfce4-screenshooter for X11.
_migrate_screenshot_keybindings() {
    local xml="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml"
    [ -f "$xml" ] || return 0
    grep -q 'value="xfce4-screenshooter' "$xml" 2>/dev/null || return 0
    sed -i \
        -e 's#value="xfce4-screenshooter -w"#value="screenshot window"#' \
        -e 's#value="xfce4-screenshooter -r"#value="screenshot region"#' \
        -e 's#value="xfce4-screenshooter"#value="screenshot full"#' \
        "$xml"
}

# 기존 설치본의 xfce4-terminal 실행에 --disable-server 부여
# Why: xfce4-terminal은 기본 단일 인스턴스(D-Bus server) — 모든 창이 한 프로세스에 종속돼,
#      server를 품은 창에서 exit 하면 나머지 창까지 전부 닫힌다. --disable-server로
#      창마다 독립 프로세스가 되어 개별 종료된다.
# Note: _setup_autostart_config의 cp -rn + 멱등 가드로 기존 config는 갱신되지 않음
_migrate_terminal_disable_server() {
    # 1) 패널 런처 (.desktop) — 인자 없는 `Exec=xfce4-terminal`만 대상 (--preferences 제외)
    local desktop
    for desktop in "$HOME"/.config/xfce4/panel/launcher-*/*.desktop; do
        [ -f "$desktop" ] || continue
        grep -qx 'Exec=xfce4-terminal' "$desktop" 2>/dev/null || continue
        sed -i 's#^Exec=xfce4-terminal$#Exec=xfce4-terminal --disable-server#' "$desktop"
    done

    # 2) 키보드 단축키 (<Primary><Alt>t) — exo-open 헬퍼 경유 시 플래그 전달 불가 → 직접 실행으로 전환
    local xml="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml"
    if [ -f "$xml" ] && grep -q 'value="exo-open --launch TerminalEmulator"' "$xml" 2>/dev/null; then
        sed -i 's#value="exo-open --launch TerminalEmulator"#value="xfce4-terminal --disable-server"#' "$xml"
    fi

    # 3) Thunar "여기서 터미널 열기" 커스텀 액션 — exo 헬퍼 경유 → 직접 실행으로 전환
    local uca="$HOME/.config/Thunar/uca.xml"
    if [ -f "$uca" ] && grep -q 'exo-open --working-directory %f --launch TerminalEmulator' "$uca" 2>/dev/null; then
        sed -i 's#exo-open --working-directory %f --launch TerminalEmulator#xfce4-terminal --disable-server --working-directory %f#' "$uca"
    fi
}

# 애플리케이션 메뉴(Whisker)·데스크탑 아이콘용 xfce4-terminal override 설치
# Why: 메뉴/아이콘 실행은 패키지 소유 $PREFIX/share/applications/xfce4-terminal.desktop을
#      쓰므로 패널·단축키 수정만으론 커버되지 않는다. XDG 우선순위상 사용자 데이터 디렉터리의
#      동일 id(.desktop)가 시스템 것을 가려 --disable-server 실행을 강제한다.
# Note: 항상 덮어씀 — 멱등이며 신규/기존 설치 모두에 적용
_setup_terminal_override() {
    local dir="$HOME/.local/share/applications"
    mkdir -p "$dir"
    cat > "$dir/xfce4-terminal.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Xfce Terminal
Comment=Terminal Emulator
GenericName=Terminal Emulator
Exec=xfce4-terminal --disable-server
Icon=org.xfce.terminal
Terminal=false
Categories=GTK;System;TerminalEmulator;
StartupNotify=true
Actions=preferences;

[Desktop Action preferences]
Name=Terminal Preferences
Exec=xfce4-terminal --preferences
EOF
}
