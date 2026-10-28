#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# 테스트 진입점 — 모든 테스트 스위트 실행
# 사용법:
#   ./tests/run_tests.sh           # 전체 실행
#   ./tests/run_tests.sh ports     # 특정 스위트만
#   ./tests/run_tests.sh adapters domain_termux
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_RED='\033[0;31m'
_GREEN='\033[0;32m'
_CYAN='\033[0;36m'
_NC='\033[0m'

declare -A SUITES=(
    [ports]="${SCRIPT_DIR}/test_ports.sh"
    [adapters]="${SCRIPT_DIR}/test_adapters.sh"
    [adapters_deb]="${SCRIPT_DIR}/test_adapters_deb.sh"
    [display_wayland]="${SCRIPT_DIR}/test_display_wayland.sh"
    [input_interactive]="${SCRIPT_DIR}/test_input_interactive.sh"
    [domain_termux]="${SCRIPT_DIR}/test_domain_termux.sh"
    [domain_xfce]="${SCRIPT_DIR}/test_domain_xfce.sh"
    [domain_proot]="${SCRIPT_DIR}/test_domain_proot.sh"
    [domain_locale_ko]="${SCRIPT_DIR}/test_domain_locale_ko.sh"
    [force_gettext]="${SCRIPT_DIR}/test_force_gettext.sh"
    [app_installer]="${SCRIPT_DIR}/test_app_installer.sh"
    [prun_ld_preload]="${SCRIPT_DIR}/test_prun_ld_preload.sh"
    [prun_runtime]="${SCRIPT_DIR}/test_prun_runtime.sh"
    [hostinfo]="${SCRIPT_DIR}/test_hostinfo.sh"
    [install_matrix]="${SCRIPT_DIR}/test_install_matrix.sh"
    [modern_install]="${SCRIPT_DIR}/test_modern_install.sh"
    [review_regressions]="${SCRIPT_DIR}/test_review_regressions.sh"
    [review_install_fixes]="${SCRIPT_DIR}/test_review_install_fixes.sh"
    [review_all_parent]="${SCRIPT_DIR}/test_review_all_parent.sh"
    [desktop_review]="${SCRIPT_DIR}/test_desktop_review.sh"
    [review_followup]="${SCRIPT_DIR}/test_review_followup.sh"
    [review_applied_fixes]="${SCRIPT_DIR}/test_review_applied_fixes.sh"
    [e2e_install]="${SCRIPT_DIR}/test_e2e_install.sh"
)

# 실행할 스위트 결정
if [ $# -eq 0 ]; then
    selected_suites=("ports" "adapters" "adapters_deb" "display_wayland" "input_interactive" "domain_termux" "domain_xfce" "domain_proot" "domain_locale_ko" "force_gettext" "app_installer" "prun_ld_preload" "prun_runtime" "hostinfo" "install_matrix" "e2e_install" "modern_install" "review_regressions" "review_install_fixes" "review_all_parent" "desktop_review" "review_followup" "review_applied_fixes")
else
    selected_suites=("$@")
fi

total_pass=0
total_fail=0
total_skip=0
failed_suites=()

for suite in "${selected_suites[@]}"; do
    if [ -z "${SUITES[$suite]+_}" ]; then
        echo -e "${_RED}알 수 없는 스위트: ${suite}${_NC}"
        echo "사용 가능: ${!SUITES[*]}"
        exit 1
    fi

    file="${SUITES[$suite]}"
    echo -e "\n${_CYAN}════ ${suite} ════${_NC}"

    output=$(bash "$file" 2>&1)
    exit_code=$?

    echo "$output"

    # 결과 파싱
    pass=$(echo "$output" | grep -oP '\d+(?= passed)' || echo 0)
    fail=$(echo "$output" | grep -oP '\d+(?= failed)' || echo 0)
    skip=$(echo "$output" | grep -oP '\d+(?= skipped)' || echo 0)

    total_pass=$(( total_pass + pass ))
    total_fail=$(( total_fail + fail ))
    total_skip=$(( total_skip + skip ))

    [ "$exit_code" -ne 0 ] && failed_suites+=("$suite")
done

echo ""
echo "╔══════════════════════════════════════╗"
echo "║           전체 테스트 결과            ║"
echo "╠══════════════════════════════════════╣"
printf "║  %-10s %3d passed / %3d failed / %3d skipped  ║\n" \
    "" "$total_pass" "$total_fail" "$total_skip"

if [ "${#failed_suites[@]}" -eq 0 ]; then
    echo -e "║  ${_GREEN}모든 테스트 통과${_NC}                       ║"
else
    echo -e "║  ${_RED}실패 스위트: ${failed_suites[*]}${_NC}"
fi
echo "╚══════════════════════════════════════╝"

[ "$total_fail" -eq 0 ] && [ "${#failed_suites[@]}" -eq 0 ]
