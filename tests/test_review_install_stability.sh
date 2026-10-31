#!/data/data/com.termux/files/usr/bin/bash
# Isolated regressions for generated prompts and installation configuration.
_STABILITY_ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
source "$_STABILITY_ROOT/tests/framework.sh"
source "$_STABILITY_ROOT/tests/mocks.sh"

_stability_sandbox() {
    STABILITY_SB=$(make_sandbox)
    trap 'cleanup_sandbox "$STABILITY_SB"' EXIT
    setup_fs_sandbox "$STABILITY_SB"
    export PROOT_DISTRO=ubuntu PROOT_USER=alice
    source "$_STABILITY_ROOT/domain/proot_env.sh"
    ui_info() { :; }
    STABILITY_ROOTFS="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"
    mkdir -p "$STABILITY_ROOTFS/home/alice"
    STABILITY_PROMPT="$STABILITY_ROOTFS/home/alice/.fancybash.sh"
    _generate_proot_fancybash "$STABILITY_PROMPT"
    git init -q "$STABILITY_SB/repo"
}

_test_prompt_does_not_execute_branch() {
    _stability_sandbox
    cd "$STABILITY_SB/repo"
    local branch
    for branch in '$(touch${IFS}prompt-dollar)' '`touch${IFS}prompt-backtick`'; do
        # These names are accepted by Git, including its normal symbolic-ref path.
        git check-ref-format --branch "$branch" >/dev/null
        git symbolic-ref HEAD "refs/heads/$branch"
        source "$STABILITY_PROMPT"
        __proot_ps1
        local rendered="${PS1@P}"
        [[ "$rendered" == *"$branch"* ]]
        [ ! -e prompt-dollar ]
        [ ! -e prompt-backtick ]
    done
}

_test_prompt_login_shell_does_not_execute_branch() {
    _stability_sandbox
    cd "$STABILITY_SB/repo"
    git symbolic-ref HEAD 'refs/heads/$(touch${IFS}prompt-login)'
    export STABILITY_PROMPT
    # Run the normal interactive login Bash prompt expansion as well as @P.
    HISTFILE=/dev/null bash --noprofile --norc --login -i > "$STABILITY_SB/login.log" 2>&1 <<'LOGIN'
source "$STABILITY_PROMPT"

exit
LOGIN
    [ ! -e prompt-login ]
    assert_file_contains "$STABILITY_SB/login.log" 'prompt-login'
}

_test_prompt_migration_preserves_user_content() {
    _stability_sandbox
    local legacy="$STABILITY_SB/legacy.sh"
    sed 's/\\[$](__git_branch)/$(__git_branch)/' "$STABILITY_PROMPT" > "$legacy"
    printf '\n# custom prompt setting\nexport KEEP_PROMPT=yes\n' >> "$legacy"
    mv "$legacy" "$STABILITY_PROMPT"
    printf 'export KEEP_BASHRC=yes\n' > "$STABILITY_ROOTFS/home/alice/.bashrc"
    local before; before=$(sha256sum "$STABILITY_PROMPT")
    setup_proot_fancybash
    local after; after=$(sha256sum "$STABILITY_PROMPT")
    [ "$before" != "$after" ]
    assert_file_contains "$STABILITY_PROMPT" '^export KEEP_PROMPT=yes$'
    setup_proot_fancybash
    assert_eq "$after" "$(sha256sum "$STABILITY_PROMPT")"
    assert_eq 'export KEEP_BASHRC=yes' "$(cat "$STABILITY_ROOTFS/home/alice/.bashrc")"
    cd "$STABILITY_SB/repo"
    git symbolic-ref HEAD 'refs/heads/$(touch${IFS}prompt-migrated)'
    source "$STABILITY_PROMPT"
    __proot_ps1
    local rendered="${PS1@P}"
    [[ "$rendered" == *'$(touch${IFS}prompt-migrated)'* ]]
    [ ! -e prompt-migrated ]
}

_test_custom_prompt_untouched() {
    _stability_sandbox
    printf 'PS1="custom> "\n' > "$STABILITY_PROMPT"
    local before; before=$(sha256sum "$STABILITY_PROMPT")
    setup_proot_fancybash
    assert_eq "$before" "$(sha256sum "$STABILITY_PROMPT")"
}

_config_fixture() {
    _stability_sandbox
    mkdir -p "$HOME/.config/termux-xfce"
    STABILITY_CONFIG="$HOME/.config/termux-xfce/config"
    printf 'PROOT_DISTRO="ubuntu"\nPROOT_USER="alice"\nDISPLAY_SERVER="x11"\nPROOT_SHELL="zsh"\nPRUN_RUNTIME="chroot-ng"\n' > "$STABILITY_CONFIG"
    awk '/^_cfg_file=/ { active=1 } active && /^# 11\./ { exit } active { print }' \
        "$_STABILITY_ROOT/install.sh" > "$STABILITY_SB/config.sh"
    export SKIP_PROOT=true DISPLAY_SERVER=x11 ARCH=aarch64
    unset PROOT_SHELL
    ui_warn() { :; }
    export -f ui_warn
}

_test_config_write_failure_preserves_original() {
    _config_fixture
    local before; before=$(sha256sum "$STABILITY_CONFIG")
    cat() { printf 'partial configuration\n'; return 42; }
    export -f cat
    if bash -euo pipefail "$STABILITY_SB/config.sh"; then return 1; fi
    assert_eq "$before" "$(sha256sum "$STABILITY_CONFIG")"
    assert_eq '' "$(find "${STABILITY_CONFIG%/*}" -maxdepth 1 -name 'config.*' -print)"
}

_test_config_publish_failure_preserves_original() {
    _config_fixture
    local before; before=$(sha256sum "$STABILITY_CONFIG")
    mv() { return 42; }
    export -f mv
    if bash -euo pipefail "$STABILITY_SB/config.sh"; then return 1; fi
    assert_eq "$before" "$(sha256sum "$STABILITY_CONFIG")"
    assert_eq '' "$(find "${STABILITY_CONFIG%/*}" -maxdepth 1 -name 'config.*' -print)"
}

_test_config_symlink_preserved() {
    _config_fixture
    local target="$STABILITY_SB/linked-config"
    mv "$STABILITY_CONFIG" "$target"
    ln -s "$target" "$STABILITY_CONFIG"
    bash -euo pipefail "$STABILITY_SB/config.sh"
    [ -L "$STABILITY_CONFIG" ]
    assert_file_contains "$target" '^PROOT_DISTRO=""$'
    assert_file_contains "$target" '^PROOT_SHELL="zsh"$'
    assert_file_contains "$target" '^PRUN_RUNTIME="chroot-ng"$'
    assert_eq 600 "$(stat -c %a "$target")"
}

describe 'generated proot prompts treat Git branch names as text'
it 'valid command-substitution and backtick branch names remain literal' _test_prompt_does_not_execute_branch
it 'an interactive login Bash does not execute a valid branch name' _test_prompt_login_shell_does_not_execute_branch
it 'existing generated prompts migrate safely and retain custom settings' _test_prompt_migration_preserves_user_content
it 'custom prompts retain their content' _test_custom_prompt_untouched

describe 'installation configuration publishes only complete writes'
it 'a failed write preserves the previous configuration and cleans staging' _test_config_write_failure_preserves_original
it 'a failed rename preserves the previous configuration and cleans staging' _test_config_publish_failure_preserves_original
it 'successful publication follows a symlink and retains saved preferences' _test_config_symlink_preserved

print_results
