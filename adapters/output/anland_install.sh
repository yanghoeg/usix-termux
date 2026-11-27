#!/data/data/com.termux/files/usr/bin/bash
# Pinned Anland: Termux 5.13.3 includes the Android IME fix (PR #30).
_ANLAND_ASSET_BASE=https://github.com/lfdevs/anland-termux/releases/download/5.13.3
_ANLAND_MESA_BASE=https://github.com/lfdevs/termux-packages/releases/download/freedreno-26.2.0-devel-20260709
_ANLAND_REPO_ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)"

_anland_apk_variant() {
    local variant="${ANLAND_APK_VARIANT:-}"
    if [ -z "$variant" ]; then
        case "${TERMUX_APP__APK_RELEASE:-${TERMUX_APK_RELEASE:-}}" in
            GITHUB) variant=standard ;;
            *) variant=compatible ;;
        esac
    fi
    case "$variant" in
        standard|compatible) printf '%s\n' "$variant" ;;
        *) ui_error "ANLAND_APK_VARIANT는 standard 또는 compatible이어야 합니다."; return 1 ;;
    esac
}

_anland_load_fetch() {
    local lib="$_ANLAND_REPO_ROOT/app-installer/lib/fetch.sh"
    [ -f "$lib" ] || { ui_error "app-installer/lib/fetch.sh 없음. git submodule update --init 실행이 필요합니다."; return 1; }
    source "$lib"
}

_anland_deb() {
    local name="$1" version="$2" url="$3" sha="$4" deb="$5" installed
    # The first Status word is the selection; it reads "hold" after apt-mark
    # below, so compare only the installed state and version.
    installed=$(dpkg-query -W -f='${Status} ${Version}' "$name" 2>/dev/null) || installed=""
    if [ "${installed#* }" != "ok installed $version" ]; then
        fetch_verified "$url" "$deb" "$sha" || return 1
        apt install -y --allow-downgrades --allow-change-held-packages \
            -o Dpkg::Options::="--force-confold" "$deb" || return 1
        installed=$(dpkg-query -W -f='${Status} ${Version}' "$name" 2>/dev/null) || return 1
        [ "${installed#* }" = "ok installed $version" ] || {
            ui_error "$name $version 설치 확인 실패: $installed"; return 1;
        }
    fi
    apt-mark hold "$name" || return 1
}

anland_install_runtime() {
    _anland_load_fetch || return 1
    local work variant rc=0
    variant=$(_anland_apk_variant) || return 1
    work=$(mktemp -d "${TMPDIR:-/tmp}/anland-install.XXXXXX") || return 1
    ui_info "Anland 5.13.3 + KWin 및 호환 Mesa/Xwayland 설치 (버전 고정)"
    _anland_deb mesa 26.2.0-1 "$_ANLAND_MESA_BASE/mesa_26.2.0-1_aarch64.deb" \
        5adfa7b3000bdce3ff660afb40e069e95508b0ab5c54c29dd9732111a548cfeb "$work/mesa.deb" || rc=$?
    if [ "$rc" -eq 0 ]; then
        _anland_deb mesa-vulkan-icd-freedreno 26.2.0-1 "$_ANLAND_MESA_BASE/mesa-vulkan-icd-freedreno_26.2.0-1_aarch64.deb" \
            f22d1258f28d71f38ce4e39e67f251565f1f1df57ccb4c046698e6e853aa5aca "$work/freedreno.deb" || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        _anland_deb xwayland 24.1.12-2 "$_ANLAND_ASSET_BASE/xwayland_24.1.12-2_aarch64.deb" \
            cd7ddcd96bf57bbcb6034babe89ba99afeed6bddd84a835d1a49aedcb951715c "$work/xwayland.deb" || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        _anland_deb kwin-anland 6.7.4 "$_ANLAND_ASSET_BASE/kwin-anland_6.7.4_aarch64.deb" \
            57510e21fc68558b78696abb4eea32071502806318c9187e03cb455523456a62 "$work/kwin.deb" || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        _anland_deb anland 5.13.3 "$_ANLAND_ASSET_BASE/anland_5.13.3_aarch64.deb" \
            62cc21942692377aff64f4e7d6d8cd110c4ed1b49e524c95584c98c7c222d493 "$work/anland.deb" || rc=$?
    fi
    rm -rf "$work"
    [ "$rc" -eq 0 ] || return "$rc"
    mkdir -p "$PREFIX/bin" "$HOME/.config/termux-xfce"
    install -m 700 "$_ANLAND_REPO_ROOT/runtime/anland-session.sh" "$PREFIX/bin/termux-xfce-anland-session"
    # Left behind by installs that ran the XFCE-on-KWin session; nothing starts it now.
    rm -f "$PREFIX/bin/termux-xfce-anland-xfce"
    printf '%s\n' "$variant" > "$HOME/.config/termux-xfce/anland-variant"
}

anland_install_apk() {
    _anland_load_fetch || return 1
    local variant filename sha dir apk tmp
    variant=$(_anland_apk_variant) || return 1
    case "$variant" in
        standard)
            filename=AnlandTermux-5.13.3.apk
            sha=b63aa9ae001316e0440ab9f963192554ab9a9e33c1a9ebe0074d9dd023d18a28 ;;
        compatible)
            filename=AnlandTermux-5.13.3-compatible.apk
            sha=929add98d56c247a070cac642d0d1034dcadf23f08c72bcb0966de89ca635838 ;;
    esac
    dir="$HOME/storage/downloads"
    [ -d "$dir" ] || dir="$HOME"
    apk="$dir/$filename"
    if [ ! -f "$apk" ] || [ "$(sha256sum "$apk" | cut -d' ' -f1)" != "$sha" ]; then
        tmp=$(mktemp "$dir/.anland-apk.XXXXXX") || return 1
        fetch_verified "$_ANLAND_ASSET_BASE/$filename" "$tmp" "$sha" || { rm -f "$tmp"; return 1; }
        chmod 600 "$tmp"
        mv "$tmp" "$apk" || return 1
    fi
    ui_info "Anland APK ($variant): Android 설치 화면에서 설치를 완료하세요. 다른 APK 종류로 전환할 때는 기존 Anland 제거가 필요합니다."
    termux-open "$apk" 2>/dev/null || ui_warn "APK를 직접 열어 설치하세요: $apk"
}
