#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# TEST: termux-xfce-hostinfo (Android Host Info Bridge)
#   - 코어별 cpuidle 체류 시간으로 /proc/stat을 만들고, 꺼진 코어는 뺀다
#   - proot-distro sysdata(stat/uptime/loadavg)와 chroot-ng용 파일을 같은 inode에 덮어쓴다
#     (top/vmstat은 fd를 열어 둔 채 되감아 읽으므로 바꿔치기하면 값이 멈춘다)
#   - getprop으로 DMI·cpuinfo Hardware 줄을 만든다
#   - Termux 네이티브 htop: exec가 hostinfo_proc.so 훅을 붙이고, 훅은 EACCES인 /proc만 대신 연다
#   - Termux 네이티브 btop: exec가 btop 모드를 켜고, 훅이 root로 보이게 하고 막힌 입력을 채운다
#   - 막힌 /sys/class/net·/proc/net/dev 통계: start가 hostinfo_net으로 한 번 먼저 쓰고, 데몬은 -w 갱신 루프를 띄운다
# 가짜 sysfs·getprop·uptime으로 생성된 스크립트를 실제 실행해 검증한다.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/framework.sh"
source "${SCRIPT_DIR}/mocks.sh"

DOMAIN_DIR="${SCRIPT_DIR}/../domain"
_BASH="${BASH:-$(command -v bash)}"

_setup_hostinfo_sandbox() {
    local sb="$1" n
    setup_fs_sandbox "$sb"
    mock_pkg_adapter
    mock_ui_adapter
    source "${DOMAIN_DIR}/packages.sh"
    source "${DOMAIN_DIR}/../adapters/output/script_builder_zenity.sh"
    source "${DOMAIN_DIR}/termux_env.sh"
    _build_hostinfo_proc() { :; }   # 실제 clang 빌드는 네이티브 htop 테스트에서만 한다
    _setup_hostinfo

    # 코어 3개 중 cpu2는 꺼져 있다. cpu0 idle 합 = 1s + 2s = 3s
    mkdir -p "$sb/cpu"
    echo "0-2" > "$sb/cpu/possible"
    for n in 0 1 2; do mkdir -p "$sb/cpu/cpu$n/cpuidle/state0" "$sb/cpu/cpu$n/cpuidle/state1"; done
    echo 1000000 > "$sb/cpu/cpu0/cpuidle/state0/time"
    echo 2000000 > "$sb/cpu/cpu0/cpuidle/state1/time"
    echo 500000 > "$sb/cpu/cpu1/cpuidle/state0/time"
    echo 0 > "$sb/cpu/cpu1/cpuidle/state1/time"
    echo 1 > "$sb/cpu/cpu1/online"
    echo 0 > "$sb/cpu/cpu2/online"

    mkdir -p "$sb/fakebin" "${PREFIX}/var/lib/proot-distro/containers/archlinux/sysdata"
    cat > "$sb/fakebin/getprop" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
case "$1" in
    ro.product.manufacturer) echo samsung ;;
    ro.product.model) echo SM-F956N ;;
    ro.board.platform) echo pineapple ;;
    ro.soc.manufacturer) echo QTI ;;
    ro.soc.model) echo SM8650 ;;
esac
EOF
    # 네이티브 fastfetch 대역: FAKE_FASTFETCH_CPU가 없으면 실패한다
    cat > "$sb/fakebin/fastfetch" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
[ -n "${FAKE_FASTFETCH_CPU:-}" ] || exit 1
printf '[\n  {\n    "type": "CPU",\n    "result": {\n      "cpu": "%s",\n      "vendor": "Qualcomm"\n    }\n  }\n]\n' "$FAKE_FASTFETCH_CPU"
EOF
    cat > "$sb/fakebin/uptime" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
if [ "$1" = -s ]; then echo "2026-10-01 00:00:00"; else echo " 10:00:00 up 1 day,  0 users,  load average: 1.50, 0.75, 0.25"; fi
EOF
    chmod +x "$sb/fakebin/"*
}

_hostinfo() {
    local sb="$1"; shift
    PATH="$sb/fakebin:$PATH" HOSTINFO_DIR="$sb/out" HOSTINFO_CPU_ROOT="$sb/cpu" \
        HOSTINFO_UPTIME="$sb/fakebin/uptime" "$_BASH" "${PREFIX}/bin/termux-xfce-hostinfo" "$@"
}

_hostinfo_once() { _hostinfo "$1" once; }

describe "termux-xfce-hostinfo — /proc 대체 파일"

_test_stat_from_cpuidle() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    _hostinfo_once "$sb" || { cleanup_sandbox "$sb"; return 1; }
    local stat="$sb/out/stat" rc=0 btime
    btime=$(date -d "2026-10-01 00:00:00" +%s)
    assert_file_contains "$stat" '^cpu  ' || rc=1
    # cpu0 idle = 3,000,000µs = 300 jiffies (USER_HZ 100)
    assert_file_contains "$stat" '^cpu0 [0-9][0-9]* 0 0 300 ' || rc=1
    assert_file_contains "$stat" '^cpu1 ' || rc=1
    assert_file_not_contains "$stat" '^cpu2 ' || rc=1
    assert_file_contains "$stat" "^btime ${btime}$" || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}
it "cpuidle 체류 시간으로 코어별 /proc/stat을 만들고 꺼진 코어와 btime을 반영한다" _test_stat_from_cpuidle

_test_cpu_hotplug_keeps_cumulative_totals() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    # 데몬의 같은 프로세스에서 표본을 갱신하되 시각과 sysfs만 결정적인 값으로 바꾼다.
    PATH="$sb/fakebin:$PATH" HOSTINFO_DIR="$sb/out" HOSTINFO_CPU_ROOT="$sb/cpu" \
        "$_BASH" -s -- "$PREFIX/bin/termux-xfce-hostinfo" "$sb" << 'EOF'
source <(sed '/^case "${1:-start}" in/,$d' "$1")
sb="$2"
mkdir -p "$OUT"
BTIME=100
unset EPOCHREALTIME
EPOCHREALTIME=110.000000; _tick; cp "$OUT/stat" "$sb/before"
echo 0 > "$CPU_ROOT/cpu1/online"
EPOCHREALTIME=111.000000; _tick; cp "$OUT/stat" "$sb/offline"
# offline 중 idle이 크게 증가해도 복귀 표본에서 더하지 않는다.
echo 99000000 > "$CPU_ROOT/cpu1/cpuidle/state0/time"
EPOCHREALTIME=112.000000; _tick; cp "$OUT/stat" "$sb/still-offline"
echo 1 > "$CPU_ROOT/cpu1/online"
EPOCHREALTIME=113.000000; _tick; cp "$OUT/stat" "$sb/online"
# 처음부터 꺼져 있던 코어가 켜져도 부팅 이후 사용량이 새로 붙지 않는다.
echo 1 > "$CPU_ROOT/cpu2/online"
EPOCHREALTIME=114.000000; _tick; cp "$OUT/stat" "$sb/first-online"
echo 99500000 > "$CPU_ROOT/cpu1/cpuidle/state0/time"
EPOCHREALTIME=115.000000; _tick; cp "$OUT/stat" "$sb/next"
# cpuidle 카운터가 offline 중 초기화되는 기기도 다음 표본부터 정상 계산한다.
echo 0 > "$CPU_ROOT/cpu1/online"
EPOCHREALTIME=116.000000; _tick
echo 100000 > "$CPU_ROOT/cpu1/cpuidle/state0/time"
echo 1 > "$CPU_ROOT/cpu1/online"
EPOCHREALTIME=117.000000; _tick
echo 350000 > "$CPU_ROOT/cpu1/cpuidle/state0/time"
EPOCHREALTIME=118.000000; _tick; cp "$OUT/stat" "$sb/reset-next"
EOF
    local rc=0
    # 첫 두 코어의 누적 busy=1650, idle=350 jiffies; offline 동안 cpu0만 매초 +100.
    assert_file_contains "$sb/offline" '^cpu  1750 0 0 350 ' || rc=1
    assert_file_not_contains "$sb/offline" '^cpu1 ' || rc=1
    assert_file_contains "$sb/still-offline" '^cpu  1850 0 0 350 ' || rc=1
    assert_eq "$(awk '$1 == "cpu1" { print $2, $5 }' "$sb/before")" \
        "$(awk '$1 == "cpu1" { print $2, $5 }' "$sb/online")" "재online 시 offline 구간을 제외한다" || rc=1
    assert_file_contains "$sb/first-online" '^cpu2 0 0 0 0 ' || rc=1
    assert_file_contains "$sb/next" '^cpu1 1100 0 0 100 ' || rc=1
    assert_file_contains "$sb/reset-next" '^cpu1 1175 0 0 125 ' || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}
it "CPU offline에도 누적 합계를 유지하고 재online 표본의 사용량 급증을 막는다" _test_cpu_hotplug_keeps_cumulative_totals

_test_proot_sysdata_files() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    _hostinfo_once "$sb" || { cleanup_sandbox "$sb"; return 1; }
    local sd="${PREFIX}/var/lib/proot-distro/containers/archlinux/sysdata" rc=0
    cmp -s "$sb/out/stat" "$sd/stat" || { echo "[ASSERT] sysdata/stat이 chroot-ng용 stat과 다르다" >&2; rc=1; }
    assert_file_contains "$sd/loadavg" '^1.50 0.75 0.25 ' || rc=1
    assert_file_contains "$sd/uptime" '^[0-9][0-9]*\.[0-9][0-9] [0-9][0-9]*\.[0-9][0-9]$' || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}
it "proot-distro sysdata의 stat·uptime·loadavg를 실제 값으로 채운다" _test_proot_sysdata_files

_test_rewrites_same_inode() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    _hostinfo_once "$sb" || { cleanup_sandbox "$sb"; return 1; }
    local sd="${PREFIX}/var/lib/proot-distro/containers/archlinux/sysdata" before after
    before="$(stat -c %i "$sb/out/stat") $(stat -c %i "$sd/stat")"
    echo 4000000 > "$sb/cpu/cpu0/cpuidle/state0/time"
    _hostinfo_once "$sb" || { cleanup_sandbox "$sb"; return 1; }
    after="$(stat -c %i "$sb/out/stat") $(stat -c %i "$sd/stat")"
    local rc=0
    assert_eq "$before" "$after" "갱신해도 inode가 그대로여야 fd를 열어 둔 top이 새 값을 본다" || rc=1
    assert_file_contains "$sb/out/stat" '^cpu0 [0-9][0-9]* 0 0 600 ' || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}
it "같은 inode에 덮어써서 fd를 열어 둔 채 다시 읽는 top/vmstat도 새 값을 본다" _test_rewrites_same_inode

_test_replaces_planted_symlink() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    local sd="${PREFIX}/var/lib/proot-distro/containers/archlinux/sysdata"
    echo "keep" > "$sb/victim"
    ln -s "$sb/victim" "$sd/stat"
    _hostinfo_once "$sb" || { cleanup_sandbox "$sb"; return 1; }
    local rc=0
    [ ! -L "$sd/stat" ] || { echo "[ASSERT] 심볼릭 링크가 남아 있다" >&2; rc=1; }
    assert_eq "keep" "$(cat "$sb/victim")" "링크 대상 파일을 덮어쓰면 안 된다" || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}
it "sysdata에 심어진 심볼릭 링크를 따라가지 않고 일반 파일로 바꾼다" _test_replaces_planted_symlink

describe "termux-xfce-hostinfo — 기기 정보"

_test_device_info() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    FAKE_FASTFETCH_CPU='Qualcomm Snapdragon 8 Gen 3 [SM8650]' _hostinfo_once "$sb" || { cleanup_sandbox "$sb"; return 1; }
    local rc=0
    assert_eq "samsung" "$(cat "$sb/out/dmi/sys_vendor")" "sys_vendor" || rc=1
    assert_eq "SM-F956N" "$(cat "$sb/out/dmi/product_name")" "product_name" || rc=1
    assert_eq "pineapple" "$(cat "$sb/out/dmi/board_name")" "board_name" || rc=1
    assert_eq "$(printf 'Hardware\t: Qualcomm Snapdragon 8 Gen 3 [SM8650]')" "$(tail -1 "$sb/out/cpuinfo")" \
        "cpuinfo 끝에 네이티브 fastfetch가 아는 SoC 이름" || rc=1
    # btop은 model name이 없으면 /sys/devices를 뒤지다 죽는다 — 코어마다 하나씩
    assert_eq "$(grep -c '^processor' "$sb/out/cpuinfo")" \
        "$(grep -c "^model name"$'\t'": Qualcomm Snapdragon 8 Gen 3 \[SM8650\]$" "$sb/out/cpuinfo")" \
        "processor 블록마다 model name" || rc=1
    # 네이티브 btop은 /proc/filesystems가 막히면 디스크를 못 고른다
    assert_file_contains "$sb/out/filesystems" $'^\tf2fs$' || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}
it "getprop으로 DMI(제조사·모델·보드)를, 네이티브 fastfetch로 cpuinfo Hardware 줄을 만든다" _test_device_info

_test_cpuinfo_without_fastfetch() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    _hostinfo_once "$sb" || { cleanup_sandbox "$sb"; return 1; }
    local rc=0
    assert_eq "$(printf 'Hardware\t: Qualcomm Technologies, Inc SM8650')" "$(tail -1 "$sb/out/cpuinfo")" \
        "fastfetch가 없으면 getprop의 SoC 제조사·모델" || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}
it "네이티브 fastfetch가 없거나 실패하면 getprop의 SoC 코드로 Hardware 줄을 만든다" _test_cpuinfo_without_fastfetch

describe "termux-xfce-hostinfo — 네트워크 카운터"

# hostinfo_net 대역: 받은 인자를 기록한다
_write_fake_net() {
    mkdir -p "$PREFIX/libexec/termux-xfce"
    printf '#!%s\necho "$*" >> "%s"\n' "$_BASH" "$1/net.log" > "$PREFIX/libexec/termux-xfce/hostinfo_net"
    chmod +x "$PREFIX/libexec/termux-xfce/hostinfo_net"
}

_test_start_writes_net_once() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"; _write_fake_net "$sb"
    # 이미 떠 있는 데몬처럼 보이는 프로세스를 두어 start가 진짜 데몬을 띄우지 않게 한다
    mkdir -p "$sb/out" && mkfifo "$sb/fifo"
    "$_BASH" -c 'read -t 30 <> "$1"' termux-xfce-hostinfo-dummy "$sb/fifo" &
    local dummy=$! rc=0
    echo "$dummy" > "$sb/out/pid"
    _hostinfo "$sb" start || rc=1
    kill "$dummy" 2>/dev/null; wait "$dummy" 2>/dev/null || true
    assert_eq "$sb/out" "$(cat "$sb/net.log" 2>/dev/null)" "갱신 루프 없이 한 번만 쓴다" || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}
it "start는 데몬이 떠 있어도 네트워크 카운터를 먼저 한 번 쓴다 (btop이 첫 값을 0으로 읽지 않게)" _test_start_writes_net_once

_test_daemon_runs_net_watcher() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"; _write_fake_net "$sb"
    _hostinfo_once "$sb" || { cleanup_sandbox "$sb"; return 1; }
    local daemon n rc=0
    # 게스트가 /sys/class/net·/proc/net에 바인드할 디렉터리는 도우미가 없어도 있어야 한다
    assert_dir_exists "$sb/out/net" || rc=1
    assert_dir_exists "$sb/out/proc_net" || rc=1
    _hostinfo "$sb" run &
    daemon=$!
    for (( n = 0; n < 30; n++ )); do
        grep -qxF -- "-w $sb/out" "$sb/net.log" 2>/dev/null && break
        sleep 0.1
    done
    kill "$daemon" 2>/dev/null; wait "$daemon" 2>/dev/null || true
    grep -qxF -- "-w $sb/out" "$sb/net.log" 2>/dev/null ||
        { echo "[ASSERT] 데몬이 hostinfo_net -w를 띄우지 않았다" >&2; rc=1; }
    cleanup_sandbox "$sb"; return "$rc"
}
it "데몬은 1초마다 네트워크 카운터를 쓰는 hostinfo_net -w를 띄운다" _test_daemon_runs_net_watcher

describe "termux-xfce-hostinfo — Termux 네이티브 htop"

_test_native_uptime_loadavg() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    _hostinfo_once "$sb" || { cleanup_sandbox "$sb"; return 1; }
    local sd="${PREFIX}/var/lib/proot-distro/containers/archlinux/sysdata" rc=0
    cmp -s "$sb/out/uptime" "$sd/uptime" || { echo "[ASSERT] 네이티브용 uptime이 sysdata와 다르다" >&2; rc=1; }
    assert_file_contains "$sb/out/loadavg" '^1.50 0.75 0.25 ' || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}
it "훅이 대신 열 uptime·loadavg도 브리지 디렉터리에 쓴다" _test_native_uptime_loadavg

# exec 대상: 받은 환경과 자기 PID를 출력한다
_write_env_probe() {
    cat > "$1/fakebin/probe" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "pid=$$"
echo "hostinfo=${TERMUX_XFCE_HOSTINFO-unset}"
echo "preload=${LD_PRELOAD-}"
echo "btop=${TERMUX_XFCE_HOSTINFO_BTOP-unset}"
EOF
    chmod +x "$1/fakebin/probe"
    cp "$1/fakebin/probe" "$1/fakebin/btop"
}

_test_exec_without_shim() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"; _write_env_probe "$sb"
    local out rc=0
    out=$(_hostinfo "$sb" exec "$sb/fakebin/probe") || rc=1
    assert_output_contains "$out" '^hostinfo=unset$' || rc=1
    assert_eq "preload=${LD_PRELOAD-}" "$(grep '^preload=' <<< "$out")" "LD_PRELOAD를 건드리지 않는다" || rc=1
    # start는 첫 갱신을 동기로 쓰므로, 브리지 디렉터리가 없어야 데몬도 PID 기록도 없었던 것이다
    [ ! -e "$sb/out" ] || { echo "[ASSERT] 훅이 없는데 데몬을 띄우거나 PID를 남겼다" >&2; rc=1; }
    cleanup_sandbox "$sb"; return "$rc"
}
it "훅을 만들 수 없으면(소스·clang 없음) exec는 명령을 그대로 실행하고 데몬을 띄우지 않는다" _test_exec_without_shim

# 샌드박스 설정이 빌드를 막아 두므로 함수를 다시 읽어 실제 clang으로 빌드한다
_build_real_shim() {
    source "${DOMAIN_DIR}/termux_env.sh"
    SCRIPT_DIR="${DOMAIN_DIR}/.." _build_hostinfo_proc
}

_test_build_shim_once() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    local so="$PREFIX/lib/hostinfo_proc.so" net="$PREFIX/libexec/termux-xfce/hostinfo_net" rc=0 before f
    _build_real_shim || { cleanup_sandbox "$sb"; return 1; }
    # 설치 뒤 clang이 생겼을 때 exec가 다시 빌드할 수 있도록 소스도 남긴다
    for f in hostinfo_proc.c hostinfo_net.c; do
        cmp -s "${DOMAIN_DIR}/../assets/$f" "$PREFIX/libexec/termux-xfce/$f" ||
            { echo "[ASSERT] 런타임 빌드용 소스 $f가 없다" >&2; rc=1; }
    done
    assert_file_exists "$so" || rc=1
    [ -x "$net" ] || { echo "[ASSERT] 네트워크 도우미가 빌드되지 않았다" >&2; rc=1; }
    assert_eq "$(sha256sum "${DOMAIN_DIR}/../assets/hostinfo_proc.c" | cut -d' ' -f1)" "$(cat "$so.sha256")" \
        "소스 해시를 기록한다" || rc=1
    before="$(stat -c %i "$so") $(stat -c %i "$net")"
    _build_real_shim || rc=1
    assert_eq "$before" "$(stat -c %i "$so") $(stat -c %i "$net")" "소스가 그대로면 다시 빌드하지 않는다" || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}

_test_exec_builds_and_attaches_shim() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"; _write_env_probe "$sb"
    # clang 없이 설치된 상태: 소스만 있고 훅은 없다
    mkdir -p "$PREFIX/libexec/termux-xfce"
    cp "${DOMAIN_DIR}/../assets/hostinfo_proc.c" "$PREFIX/libexec/termux-xfce/"
    # 이미 떠 있는 데몬처럼 보이는 프로세스를 두어 exec가 진짜 데몬을 띄우지 않게 한다
    mkdir -p "$sb/out" && mkfifo "$sb/fifo"
    "$_BASH" -c 'read -t 30 <> "$1"' termux-xfce-hostinfo-dummy "$sb/fifo" &
    local dummy=$! out btop_out pid rc=0
    echo "$dummy" > "$sb/out/pid"
    out=$(_hostinfo "$sb" exec "$sb/fakebin/probe") || rc=1
    btop_out=$(_hostinfo "$sb" exec "$sb/fakebin/btop") || rc=1
    kill "$dummy" 2>/dev/null; wait "$dummy" 2>/dev/null || true
    pid=$(sed -n 's/^pid=//p' <<< "$out")
    assert_file_exists "$PREFIX/lib/hostinfo_proc.so" || rc=1
    assert_file_exists "$sb/out/holders/$pid" || rc=1
    assert_output_contains "$out" "^hostinfo=$sb/out$" || rc=1
    assert_output_contains "$out" "^preload=$PREFIX/lib/hostinfo_proc.so" || rc=1
    # btop 모드는 btop에만 켠다 (htop 등은 실제 UID를 그대로 본다)
    assert_output_contains "$out" '^btop=unset$' || rc=1
    assert_output_contains "$btop_out" '^btop=1$' || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}

_test_shim_redirects_blocked_proc() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    _build_real_shim || { cleanup_sandbox "$sb"; return 1; }
    mkdir -p "$sb/bridge/proc_net"
    echo "cpu  1 0 0 2 0 0 0 0 0 0" > "$sb/bridge/stat"
    echo "123.45 67.89" > "$sb/bridge/uptime"
    echo "1.50 0.75 0.25 1/1 1" > "$sb/bridge/loadavg"
    echo "Inter-|   Receive" > "$sb/bridge/proc_net/dev"
    cat > "$sb/reader.c" << 'EOF'
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

static void show(const char *tag, int fd)
{
    char buf[64] = "";
    ssize_t n = fd < 0 ? -1 : read(fd, buf, sizeof(buf) - 1);
    printf("%s=%s", tag, n > 0 ? buf : "fail\n");
    if (fd >= 0)
        close(fd);
}

int main(void)
{
    char buf[64] = "";
    FILE *f = fopen("/proc/stat", "r");
    printf("fopen=%s", f && fgets(buf, sizeof(buf), f) ? buf : "fail\n");
    show("open", open("/proc/uptime", O_RDONLY));
    show("openat", openat(AT_FDCWD, "/proc/loadavg", O_RDONLY));
    printf("access=%d\n", access("/proc/stat", R_OK));
    printf("access_w=%d\n", access("/proc/stat", W_OK));
    f = fopen("/proc/net/dev", "r");
    printf("netdev=%s", f && fgets(buf, sizeof(buf), f) ? buf : "fail\n");
    return 0;
}
EOF
    clang -O2 -o "$sb/reader" "$sb/reader.c" || { cleanup_sandbox "$sb"; return 1; }
    local preload="$PREFIX/lib/hostinfo_proc.so${LD_PRELOAD:+:$LD_PRELOAD}" out plain rc=0
    out=$(TERMUX_XFCE_HOSTINFO="$sb/bridge" LD_PRELOAD="$preload" "$sb/reader")
    plain=$(unset TERMUX_XFCE_HOSTINFO; LD_PRELOAD="$preload" "$sb/reader")
    assert_output_contains "$out" '^fopen=cpu  1 0 0 2 ' || rc=1
    assert_output_contains "$out" '^open=123.45 67.89$' || rc=1
    assert_output_contains "$out" '^openat=1.50 0.75 0.25 ' || rc=1
    assert_output_contains "$out" '^access=0$' || rc=1
    assert_output_contains "$out" '^access_w=-1$' || rc=1
    # htop 네트워크 미터 등은 btop 모드가 아니어도 /proc/net/dev를 읽는다
    assert_output_contains "$out" '^netdev=Inter-|   Receive$' || rc=1
    # 브리지 경로가 없으면 원래 실패(EACCES)를 그대로 돌려준다
    assert_output_contains "$plain" '^fopen=fail$' || rc=1
    assert_output_contains "$plain" '^access=-1$' || rc=1
    assert_output_contains "$plain" '^netdev=fail$' || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}

_test_shim_btop_mode() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    _build_real_shim || { cleanup_sandbox "$sb"; return 1; }
    mkdir -p "$sb/bridge/net/wlan0/statistics"
    printf 'processor\t: 0\nmodel name\t: Test SoC\n' > "$sb/bridge/cpuinfo"
    printf '\tf2fs\n' > "$sb/bridge/filesystems"
    echo 12345 > "$sb/bridge/net/wlan0/statistics/rx_bytes"
    cat > "$sb/reader.c" << 'EOF'
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void find(const char *tag, const char *path, const char *want)
{
    char buf[128];
    FILE *f = fopen(path, "r");
    const char *got = "none\n";
    while (f && fgets(buf, sizeof(buf), f))
        if (strstr(buf, want)) { got = buf; break; }
    printf("%s=%s", tag, got);
    if (f)
        fclose(f);
}

static void net(const char *tag, const char *path)
{
    struct stat st;
    int rc = stat(path, &st);
    printf("%s=%s\n", tag, rc == 0 ? "ok" : errno == ENOENT ? "ENOENT" : errno == EACCES ? "EACCES" : "other");
}

int main(void)
{
    net("net", "/sys/class/net/lo/statistics/rx_bytes");
    net("wlan0", "/sys/class/net/wlan0/statistics/rx_bytes");
    printf("uid=%d euid=%d\n", (int)getuid(), (int)geteuid());
    find("model", "/proc/cpuinfo", "model name");
    find("fs", "/proc/filesystems", "f2fs");
    find("rx", "/sys/class/net/wlan0/statistics/rx_bytes", "");
    return 0;
}
EOF
    clang -O2 -o "$sb/reader" "$sb/reader.c" || { cleanup_sandbox "$sb"; return 1; }
    local preload="$PREFIX/lib/hostinfo_proc.so${LD_PRELOAD:+:$LD_PRELOAD}" out plain rc=0
    out=$(TERMUX_XFCE_HOSTINFO_BTOP=1 TERMUX_XFCE_HOSTINFO="$sb/bridge" LD_PRELOAD="$preload" "$sb/reader")
    plain=$(TERMUX_XFCE_HOSTINFO="$sb/bridge" LD_PRELOAD="$preload" "$sb/reader")
    assert_output_contains "$out" '^uid=0 euid=0$' || rc=1
    assert_output_contains "$out" $'^model=model name\t: Test SoC$' || rc=1
    assert_output_contains "$out" $'^fs=\tf2fs$' || rc=1
    # 브리지 파일이 없는 인터페이스는 권한 오류 대신 "없음", 있는 인터페이스는 그 값을 본다
    assert_output_contains "$out" '^net=ENOENT$' || rc=1
    assert_output_contains "$out" '^wlan0=ok$' || rc=1
    assert_output_contains "$out" '^rx=12345$' || rc=1
    # btop 모드가 아니면 실제 UID·실제 cpuinfo·원래 권한 오류를 그대로 본다
    assert_output_contains "$plain" "^uid=$(id -u) euid=$(id -u)$" || rc=1
    assert_output_contains "$plain" '^model=none$' || rc=1
    assert_output_contains "$plain" '^fs=none$' || rc=1
    assert_output_contains "$plain" '^net=\(EACCES\|ENOENT\)$' || rc=1
    assert_output_contains "$plain" '^rx=none$' || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}

_test_shim_missing_net_readonly() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    _build_real_shim || { cleanup_sandbox "$sb"; return 1; }
    mkdir -p "$sb/bridge/net/usix-hostinfo-test/statistics"
    echo 67890 > "$sb/bridge/net/usix-hostinfo-test/statistics/rx_bytes"
    cat > "$sb/reader.c" << 'EOF'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *path = "/sys/class/net/usix-hostinfo-test/statistics/rx_bytes";

static void show(const char *tag, int fd)
{
    char buf[32] = "";
    ssize_t n = fd < 0 ? -1 : read(fd, buf, sizeof(buf) - 1);
    printf("%s=%s", tag, n > 0 ? buf : "fail\n");
    if (fd >= 0) close(fd);
}

int main(void)
{
    char buf[32];
    struct stat st;
    FILE *f = fopen(path, "r");
    printf("fopen=%s", f && fgets(buf, sizeof(buf), f) ? buf : "fail\n");
    if (f) fclose(f);
    show("open", open(path, O_RDONLY));
    show("openat", openat(AT_FDCWD, path, O_RDONLY));
    printf("access=%d\n", access(path, R_OK));
    printf("faccessat=%d\n", faccessat(AT_FDCWD, path, R_OK, 0));
    printf("stat=%d\n", stat(path, &st));
    printf("fstatat=%d\n", fstatat(AT_FDCWD, path, &st, 0));
    /* 원래 경로는 없지만 브리지에는 있다. 쓰기·생성·자르기는 대체하면 안 된다. */
    int write_flags[] = { O_WRONLY, O_RDWR, O_RDONLY | O_TRUNC, O_RDONLY | O_CREAT };
    int allowed = 0;
    for (unsigned i = 0; i < sizeof(write_flags) / sizeof(write_flags[0]); ++i) {
        int fd = open(path, write_flags[i], 0600);
        if (fd >= 0) { ++allowed; close(fd); }
    }
    const char *write_modes[] = { "r+", "w", "a" };
    for (unsigned i = 0; i < sizeof(write_modes) / sizeof(write_modes[0]); ++i) {
        f = fopen(path, write_modes[i]);
        if (f) { ++allowed; fclose(f); }
    }
    allowed += access(path, W_OK) == 0;
    allowed += faccessat(AT_FDCWD, path, X_OK, 0) == 0;
    printf("writes=%d\n", allowed);
    return 0;
}
EOF
    clang -O2 -o "$sb/reader" "$sb/reader.c" || { cleanup_sandbox "$sb"; return 1; }
    local preload="$PREFIX/lib/hostinfo_proc.so${LD_PRELOAD:+:$LD_PRELOAD}" out plain tag rc=0
    out=$(TERMUX_XFCE_HOSTINFO_BTOP=1 TERMUX_XFCE_HOSTINFO="$sb/bridge" LD_PRELOAD="$preload" "$sb/reader")
    plain=$(TERMUX_XFCE_HOSTINFO_BTOP=0 TERMUX_XFCE_HOSTINFO="$sb/bridge" LD_PRELOAD="$preload" "$sb/reader")
    for tag in fopen open openat; do
        assert_output_contains "$out" "^$tag=67890$" || rc=1
        assert_output_contains "$plain" "^$tag=fail$" || rc=1
    done
    for tag in access faccessat stat fstatat; do
        assert_output_contains "$out" "^$tag=0$" || rc=1
        assert_output_contains "$plain" "^$tag=-1$" || rc=1
    done
    assert_output_contains "$out" '^writes=0$' || rc=1
    assert_file_contains "$sb/bridge/net/usix-hostinfo-test/statistics/rx_bytes" '^67890$' || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}

# 실기기 전용: Android 16 netstats(StatsResult getIfaceStats(String))에서 실제 카운터를 받는다
_test_real_net_helper() {
    local sb; sb=$(make_sandbox); _setup_hostinfo_sandbox "$sb"
    _build_real_shim || { cleanup_sandbox "$sb"; return 1; }
    local rc=0 rx dev="$sb/proc_net/dev"
    # 게스트는 바인드된 /sys/class/net·/proc/net에 링크를 심을 수 있다
    mkdir -p "$sb/net/lo/statistics" "$sb/proc_net"
    echo keep > "$sb/victim"
    ln -s "$sb/victim" "$sb/net/lo/statistics/rx_bytes"
    "$PREFIX/libexec/termux-xfce/hostinfo_net" "$sb" || rc=1
    assert_eq "keep" "$(cat "$sb/victim")" "심은 링크의 대상 파일을 덮어쓰면 안 된다" || rc=1
    # 루프백은 항상 있고, Android에서는 부팅 뒤 늘 트래픽이 있다
    rx=$(cat "$sb/net/lo/statistics/rx_bytes" 2>/dev/null)
    [[ "$rx" =~ ^[0-9]+$ ]] && (( rx > 0 )) || { echo "[ASSERT] lo rx_bytes가 양의 정수가 아니다: '$rx'" >&2; rc=1; }
    assert_file_exists "$sb/net/lo/statistics/tx_bytes" || rc=1
    # /proc/net/dev 형식: 머리글 두 줄 뒤에 "이름: 열 16개", 값은 같은 갱신의 sysfs 값과 같다
    assert_eq "Inter-|" "$(head -c 7 "$dev" 2>/dev/null)" "/proc/net/dev 머리글" || rc=1
    assert_eq "$rx 16" "$(awk -F: '$1 ~ /^ *lo$/ { n = split($2, f, " "); print f[1], n }' "$dev" 2>/dev/null)" \
        "lo 줄은 sysfs와 같은 rx 바이트와 열 16개" || rc=1
    cleanup_sandbox "$sb"; return "$rc"
}

if ! command -v clang >/dev/null 2>&1; then
    skip "훅 빌드·exec 연결·/proc 대체 열기 (clang 없음)"
else
    it "clang으로 훅과 네트워크 도우미를 빌드하고 소스가 그대로면 다시 빌드하지 않는다" _test_build_shim_once
    it "설치 뒤 clang이 생기면 첫 exec가 훅을 빌드해 붙이고 데몬이 볼 PID를 남긴다" _test_exec_builds_and_attaches_shim
    it "btop의 ENOENT 네트워크 경로는 읽기 API만 브리지로 열고 쓰기와 일반 모드는 보존한다" _test_shim_missing_net_readonly
    if (read -r _ < /proc/stat) 2>/dev/null; then
        skip "훅의 /proc 대체 열기 (이 환경은 /proc/stat을 직접 읽을 수 있다)"
    else
        it "훅은 EACCES인 /proc/stat·uptime·loadavg·net/dev 읽기·확인만 브리지 파일로 대신 연다" _test_shim_redirects_blocked_proc
        it "btop 모드의 훅은 root로 보이게 하고 cpuinfo·filesystems·막힌 /sys/class/net을 채운다" _test_shim_btop_mode
    fi
    if [ "$(getprop ro.build.version.sdk 2>/dev/null)" -ge 36 ] 2>/dev/null; then
        it "hostinfo_net은 netstats 서비스 값으로 /sys/class/net 모양과 /proc/net/dev를 쓴다 (실기기)" _test_real_net_helper
    else
        skip "netstats 실제 호출 (Android 16 이상 실기기 전용)"
    fi
fi

print_results
