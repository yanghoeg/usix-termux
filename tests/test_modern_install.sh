#!/data/data/com.termux/files/usr/bin/bash
# Runtime regression tests for fresh installs and upgrades from old presets.
_MODERN_ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
source "$_MODERN_ROOT/tests/framework.sh"
source "$_MODERN_ROOT/tests/mocks.sh"

_modern_setup() {
    setup_fs_sandbox "$1"
    export SCRIPT_DIR="$_MODERN_ROOT"
    export PATH="$PREFIX/bin:$PATH"
    printf '#!/data/data/com.termux/files/usr/bin/bash\nexit 0\n' > "$PREFIX/bin/termux-wake-lock"
    chmod +x "$PREFIX/bin/termux-wake-lock"
    mock_ui_adapter
    mock_pkg_adapter
    source "$_MODERN_ROOT/domain/termux_env.sh"
    source "$_MODERN_ROOT/adapters/output/display_x11.sh"
    source "$_MODERN_ROOT/adapters/output/script_builder_zenity.sh"
    source "$_MODERN_ROOT/app-installer/lib/input_method.sh"
    source "$_MODERN_ROOT/app-installer/domain/desktop.sh"
    source "$_MODERN_ROOT/app-installer/ports/pkg_manager.sh"
    source "$_MODERN_ROOT/app-installer/domain/apps.sh"
    unset WAYLAND_DISPLAY XDG_SESSION_TYPE
}

_test_input_optional() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    _setup_input_method
    assert_eq none "$(input_method_current)"
    assert_not_called nimf
    export GTK_IM_MODULE=nimf QT_IM_MODULE=nimf XMODIFIERS=@im=nimf
    source "$PREFIX/etc/profile.d/termux-xfce-input.sh"
    assert_eq unset "${GTK_IM_MODULE-unset}"
    cleanup_sandbox "$sb"
}
it 'base setup does not install or select an input method' _test_input_optional

_test_input_upgrade_and_selection() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    fcitx5() { :; }
    cat >> "$PREFIX/etc/bash.bashrc" <<'RC'
# termux-xfce-locale
export LANG=ko_KR.UTF-8
if command -v nimf >/dev/null 2>&1; then
    export GTK_IM_MODULE=fcitx5
    export QT_IM_MODULE=fcitx5
    export XMODIFIERS=@im=fcitx5
fi
export KEEP_USER_SETTING=yes
RC
    _setup_input_method
    _setup_input_method
    assert_eq fcitx5 "$(input_method_current)"
    assert_file_contains "$PREFIX/etc/bash.bashrc" KEEP_USER_SETTING
    assert_file_not_contains "$PREFIX/etc/bash.bashrc" 'command -v nimf'
    source "$PREFIX/etc/profile.d/termux-xfce-input.sh"
    assert_eq fcitx "$GTK_IM_MODULE"
    assert_eq @im=fcitx "$XMODIFIERS"
    assert_file_contains "$HOME/.config/autostart/nimf.desktop" '^Hidden=true$'
    assert_file_contains "$HOME/.config/autostart/org.fcitx.Fcitx5.desktop" '^NotShowIn=KDE;$'
    input_method_select nimf
    input_method_remove fcitx5
    assert_eq nimf "$(input_method_current)"
    input_method_remove nimf
    source "$PREFIX/etc/profile.d/termux-xfce-input.sh"
    assert_eq unset "${GTK_IM_MODULE-unset}"
    cleanup_sandbox "$sb"
}
it 'input method migration preserves choice and removal clears only the selected method' _test_input_upgrade_and_selection

_test_input_wayland() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    input_method_select fcitx5
    export XDG_SESSION_TYPE=wayland GTK_IM_MODULE=nimf QT_IM_MODULE=nimf XMODIFIERS=@im=nimf
    source "$PREFIX/etc/profile.d/termux-xfce-input.sh"
    assert_eq unset "${QT_IM_MODULE-unset}"
    cleanup_sandbox "$sb"
}
it 'Wayland leaves input modules to the compositor' _test_input_wayland

_test_launcher_reads_selection() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    input_method_select fcitx5
    nimf() { :; }
    pulseaudio() { :; }
    pacmd() { :; }
    export -f nimf pulseaudio pacmd
    display_emit_kill_session() { echo '_kill_display_session() { :; }'; }
    display_emit_session_detect() { echo '_DISPLAY_SERVER=x11'; }
    display_emit_server_start() { echo 'XDISPLAY=:7'; }
    display_emit_clipboard_sync() { :; }
    display_emit_session_launch() { echo 'printf "%s|%s|%s\n" "$GTK_IM_MODULE" "$QT_IM_MODULE" "$XMODIFIERS"'; }
    script_build_start_xfce "$sb/start"
    local actual; actual=$(bash "$sb/start")
    assert_eq 'fcitx|fcitx|@im=fcitx' "$actual"
    cleanup_sandbox "$sb"
}
it 'a generated launcher honors Fcitx even when Nimf is installed' _test_launcher_reads_selection

_test_gpu_rc_migration() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    cat >> "$PREFIX/etc/bash.bashrc" <<'RC'
# termux-xfce-gpu — Adreno 감지 시 Zink 상시 활성화
if [ -f /sys/class/kgsl/kgsl-3d0/gpu_model ]; then
    export MESA_LOADER_DRIVER_OVERRIDE=zink
fi
export KEEP_USER_SETTING=yes
RC
    _migrate_gpu_rc
    _migrate_gpu_rc
    assert_file_not_contains "$PREFIX/etc/bash.bashrc" MESA_LOADER_DRIVER_OVERRIDE
    assert_file_contains "$PREFIX/etc/bash.bashrc" KEEP_USER_SETTING
    cleanup_sandbox "$sb"
}
it 'old global GPU exports are removed without changing user settings' _test_gpu_rc_migration

_test_gpu_profile_migration() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    export PROOT_DISTRO=ubuntu PROOT_USER=testuser
    local rootfs; rootfs=$(_proot_rootfs)
    mkdir -p "$rootfs/etc/profile.d" "$rootfs/usr/share/vulkan/icd.d"
    source "$_MODERN_ROOT/app-installer/domain/installers/gpu_proot.sh"
    cat > "$rootfs/etc/profile.d/termux-xfce-env.sh" <<'PROFILE'
export DISPLAY=${DISPLAY:-:0.0}
export MESA_LOADER_DRIVER_OVERRIDE=zink
export VK_DRIVER_FILES=/data/data/com.termux/files/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
export KEEP_USER_SETTING=yes
PROFILE
    touch "$rootfs/etc/profile.d/gpu-accel.sh"
    app_remove_gpu_proot
    assert_file_not_contains "$rootfs/etc/profile.d/termux-xfce-env.sh" 'MESA_\|VK_'
    assert_file_contains "$rootfs/etc/profile.d/termux-xfce-env.sh" DISPLAY
    assert_file_contains "$rootfs/etc/profile.d/termux-xfce-env.sh" KEEP_USER_SETTING
    [ ! -f "$rootfs/etc/profile.d/gpu-accel.sh" ]
    _gpu_proot_has_kgsl() { return 0; }
    proot_pkg_install_wine_mesa() { return 0; }
    proot_pkg_install_gpu_tools() { return 0; }
    _gpu_proot_install_termux_turnip() { : > "$rootfs$GPU_PROOT_TURNIP_ICD"; }
    proot_exec() { echo 'llvmpipe'; }
    if app_install_gpu_proot >/dev/null 2>&1; then return 1; fi
    [ ! -f "$rootfs/etc/profile.d/gpu-accel.sh" ]
    proot_exec() { echo 'driverName = turnip'; }
    app_install_gpu_proot
    assert_file_contains "$rootfs/etc/profile.d/gpu-accel.sh" 'VK_DRIVER_FILES="/usr/share/vulkan/'
    assert_file_not_contains "$rootfs/etc/profile.d/gpu-accel.sh" '/data/data/'
    cleanup_sandbox "$sb"
}
it 'GPU removal clears both profiles and activation requires a working container Turnip driver' _test_gpu_profile_migration

_test_screenshot_dispatch() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    _setup_screenshot
    export TEST_CAPTURE="$sb/capture"
    cat > "$PREFIX/bin/spectacle" <<'STUB'
#!/bin/sh
printf '%s:%s\n' "$QT_QPA_PLATFORM" "$*" > "$TEST_CAPTURE"
STUB
    cat > "$PREFIX/bin/xfce4-screenshooter" <<'STUB'
#!/bin/sh
printf 'x11:%s\n' "$*" > "$TEST_CAPTURE"
STUB
    chmod +x "$PREFIX/bin/spectacle" "$PREFIX/bin/xfce4-screenshooter"
    export PATH="$PREFIX/bin:$PATH"
    WAYLAND_DISPLAY=wayland-3 bash "$PREFIX/bin/screenshot" region
    assert_eq 'wayland:--region' "$(cat "$TEST_CAPTURE")"
    XDG_SESSION_TYPE=wayland bash "$PREFIX/bin/screenshot" window
    assert_eq 'wayland:--activewindow' "$(cat "$TEST_CAPTURE")"
    bash "$PREFIX/bin/screenshot" full
    assert_eq 'x11:-f' "$(cat "$TEST_CAPTURE")"
    cleanup_sandbox "$sb"
}
it 'screenshot uses the actual session backend and capture mode' _test_screenshot_dispatch

_test_native_only_helpers() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    mkdir -p "$HOME/.config/termux-xfce"
    echo 'PROOT_DISTRO=""' > "$HOME/.config/termux-xfce/config"
    _setup_prun
    _setup_cp2menu
    _setup_conky_autostart
    if bash "$PREFIX/bin/prun" true > "$sb/error" 2>&1; then return 1; fi
    assert_file_contains "$sb/error" 'proot 환경이 설정되지'
    # cp2menu reports errors through zenity too; keep it off a live X display.
    if env -u DISPLAY bash "$PREFIX/bin/cp2menu" > "$sb/error" 2>&1; then return 1; fi
    assert_file_contains "$sb/error" 'proot 환경이 설정되지'
    bash "$PREFIX/bin/termux-xfce-conky"
    cleanup_sandbox "$sb"
}
it 'native-only launchers fail clearly and Conky skips missing containers' _test_native_only_helpers

_test_panel_exit_migration() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    mkdir -p "$HOME/.config/xfce4/panel/launcher-4"
    printf '[Desktop Entry]\nName=Kill Termux X11\nExec=kill_termux_x11\n' > "$HOME/.config/xfce4/panel/launcher-4/old.desktop"
    _setup_kill_display
    assert_file_contains "$HOME/.config/xfce4/panel/launcher-4/old.desktop" '^Exec=kill_display_session$'
    [ -x "$PREFIX/bin/kill_display_session" ]
    cleanup_sandbox "$sb"
}
it 'existing panel exit buttons target the current session command' _test_panel_exit_migration

_test_desktop_forwarding() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    cat > "$sb/app.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Writer 100%
Exec=libreoffice --writer %U
TryExec=/usr/bin/libreoffice
Path=/opt/libreoffice
DBusActivatable=true
[Desktop Action Edit]
Exec=libreoffice --draw %F
DESKTOP
    desktop_rewrite_for_proot "$sb/app.desktop"
    assert_file_contains "$sb/app.desktop" '^Exec=prun-gui "Writer 100%%" -- libreoffice --writer %U$'
    assert_file_contains "$sb/app.desktop" '^Exec=prun-gui "Writer 100%%" -- libreoffice --draw %F$'
    assert_file_contains "$sb/app.desktop" '^DBusActivatable=false$'
    assert_file_not_contains "$sb/app.desktop" 'bash -c\|TryExec=\|Path='
    cleanup_sandbox "$sb"
}
it 'desktop imports keep file arguments and actions without shell parsing or container-only paths' _test_desktop_forwarding

_test_wine_native_current_loader() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    unset _WINE_BACKEND_SH
    source "$_MODERN_ROOT/app-installer/lib/wine_backend.sh"
    source "$_MODERN_ROOT/app-installer/domain/installers/wine.sh"
    termux_pkg_enable_repo() { :; }
    termux_pkg_install() { :; }
    mkdir -p "$HOME/.wine-staging/bin" "$HOME/.wine-staging/lib/wine/x86_64-unix" \
        "$HOME/.wine-staging/lib/wine/x86_64-windows" "$PREFIX/glibc/bin" "$PREFIX/glibc/lib"
    printf '#!/data/data/com.termux/files/usr/bin/bash\nexit 0\n' > "$HOME/.wine-staging/bin/wineserver"
    printf fixture > "$HOME/.wine-staging/lib/wine/x86_64-unix/ntdll.so"
    printf fixture > "$HOME/.wine-staging/lib/wine/x86_64-windows/kernel32.dll"
    cat > "$HOME/.wine-staging/bin/wine" <<'STUB'
#!/data/data/com.termux/files/usr/bin/bash
printf '%s:%s\n' "$DISPLAY" "$*"
STUB
    cat > "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" <<'STUB'
#!/data/data/com.termux/files/usr/bin/bash
[ "$1" = --library-path ] && [ "$2" = "$PREFIX/glibc/lib" ] || exit 1
shift 2
exec "$@"
STUB
    cat > "$PREFIX/glibc/bin/box64" <<'STUB'
#!/data/data/com.termux/files/usr/bin/bash
exec "$@"
STUB
    chmod +x "$HOME/.wine-staging/bin/wine" "$HOME/.wine-staging/bin/wineserver" \
        "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" "$PREFIX/glibc/bin/box64"
    _wine_install_native >/dev/null
    export PATH="$PREFIX/bin:$PATH" DISPLAY=:91
    assert_eq ':91:winecfg' "$(bash "$PREFIX/bin/wine-box64" winecfg)"
    [ ! -e "$HOME/.wine-staging/bin/wine64" ]
    cleanup_sandbox "$sb"
}
it 'native Wine starts from a modern bundle containing wine but no wine64' _test_wine_native_current_loader

_test_wine_proot_wrapper() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    unset _WINE_BACKEND_SH
    source "$_MODERN_ROOT/app-installer/lib/wine_backend.sh"
    source "$_MODERN_ROOT/app-installer/domain/installers/wine.sh"
    export PROOT_DISTRO=ubuntu PROOT_USER=testuser
    mkdir -p "$HOME/.config/termux-xfce" "$HOME/.wine" "$sb/container-bin"
    printf 'PROOT_DISTRO=ubuntu\n' > "$HOME/.config/termux-xfce/config"
    printf '"LogPixels"=dword:00000060\n' > "$HOME/.wine/user.reg"
    has_proot_distro() { return 0; }
    _wine_create_launchers
    cat > "$PREFIX/bin/proot-distro" <<'STUB'
#!/data/data/com.termux/files/usr/bin/bash
# The mock container maps its /opt Wine path into the temporary filesystem.
[ "$1" = login ] && [ "$2" = ubuntu ] && [ "$3" = --user ] && [ "$4" = testuser ] || exit 41
while [ "$1" != -- ]; do shift; done
shift
args=()
for arg in "$@"; do
    args+=("${arg//\/opt\/wine-staging\/bin\/wine/$CONTAINER_STUB_BIN/wine}")
done
export PATH="$CONTAINER_STUB_BIN:$PATH"
exec "${args[@]}"
STUB
    cat > "$sb/container-bin/wine" <<'STUB'
#!/data/data/com.termux/files/usr/bin/bash
printf '%s:%s\n' "$DISPLAY" "$*"
STUB
    chmod +x "$PREFIX/bin/proot-distro" "$sb/container-bin/wine"
    export PATH="$PREFIX/bin:$PATH" DISPLAY=:91 WINE_DPI=240 CONTAINER_STUB_BIN="$sb/container-bin"
    unset WINEPREFIX
    assert_eq ':91:argument with spaces' "$(bash "$PREFIX/bin/wine-box64" 'argument with spaces')"
    assert_file_contains "$HOME/.wine/user.reg" '^"LogPixels"=dword:000000f0$'
    printf 'PROOT_DISTRO=""\n' > "$HOME/.config/termux-xfce/config"
    export PROOT_DISTRO=archlinux PROOT_USER=anotheruser
    assert_eq ':91:winecfg' "$(bash "$PREFIX/bin/wine-box64" winecfg)"
    cleanup_sandbox "$sb"
}
it 'proot Wine preserves display, arguments and DPI and keeps its saved target after config changes' _test_wine_proot_wrapper

_test_retired_browser_and_notion() {
    local sb; sb=$(make_sandbox); _modern_setup "$sb"
    source "$_MODERN_ROOT/app-installer/domain/installers/tor_browser.sh"
    source "$_MODERN_ROOT/app-installer/domain/installers/notion.sh"
    if app_can_install tor_browser; then return 1; fi
    if app_install_tor_browser >/dev/null 2>&1; then return 1; fi
    if app_is_visible tor_browser; then return 1; fi
    desktop_register tor Tor old-browser tor Network
    app_is_visible tor_browser
    termux_pkg_enable_repo() { return 0; }
    termux_pkg_install() { return 0; }
    app_upgrade_notion
    assert_file_contains "$PREFIX/share/applications/notion.desktop" '^Exec=firefox --new-window https://www.notion.so$'
    cleanup_sandbox "$sb"
}
it 'retired Tor remains removable and Notion can migrate to its native web launcher' _test_retired_browser_and_notion

print_results
