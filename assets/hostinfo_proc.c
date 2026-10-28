/*
 * hostinfo_proc.so — Termux 네이티브 프로그램(htop 등)용 Host Info Bridge LD_PRELOAD 훅
 *
 * Android은 앱에서 /proc/stat·/proc/uptime·/proc/loadavg 읽기를 막는다(EACCES).
 * 원래 파일이 EACCES로 열리지 않는 읽기 전용 열기·읽기 확인만 TERMUX_XFCE_HOSTINFO 디렉터리의
 * 같은 이름 파일(termux-xfce-hostinfo가 1초마다 갱신)로 다시 시도한다.
 * 막힌 /proc/net 아래는 proc_net/ 아래 같은 이름(hostinfo_net이 쓰는 dev)으로 다시 시도한다.
 *
 * TERMUX_XFCE_HOSTINFO_BTOP=1(termux-xfce-hostinfo exec btop)이면 btop 호환을 더한다:
 *   - Termux btop은 실효 UID가 root가 아니면 바로 끝내므로 getuid·geteuid를 0으로 보고한다
 *   - ARM /proc/cpuinfo에는 model name이 없어 /sys/devices 목록(막힘)을 뒤지다 죽으므로 브리지 cpuinfo를 연다
 *   - 막힌 /proc/filesystems는 브리지 파일로 대신 연다
 *   - 막힌(EACCES·ENOENT) /sys/class/net 아래는 hostinfo_net이 netstats 서비스 값으로 채운 net/ 아래 같은 경로로 열고,
 *     거기도 없으면 권한 오류 대신 ENOENT("없음")를 돌려준다 (btop은 권한 오류를 예외로 죽는다)
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int btop_mode(void)
{
    const char *v = getenv("TERMUX_XFCE_HOSTINFO_BTOP");
    return v && strcmp(v, "1") == 0;
}

/* Android은 같은 sysfs 통계도 기기마다 EACCES 또는 ENOENT로 숨긴다.
 * ENOENT 대체는 btop의 네트워크 sysfs 경로로 한정한다. */
static int bridged_error(const char *path, int error)
{
    return error == EACCES ||
        (error == ENOENT && btop_mode() && path && strncmp(path, "/sys/class/net/", 15) == 0);
}

/* 막힌 /proc 항목이나 (btop 모드) /sys/class/net 아래 경로면 alt에 대체 경로를 채우고 1을 돌려준다 */
static int bridged(const char *path, char alt[PATH_MAX])
{
    const char *dir = getenv("TERMUX_XFCE_HOSTINFO");
    const char *name;

    if (!path || !dir || !*dir)
        return 0;
    if (btop_mode() && strncmp(path, "/sys/class/net/", 15) == 0)
        return snprintf(alt, PATH_MAX, "%s/net/%s", dir, path + 15) < PATH_MAX;
    /* hostinfo_net이 쓰는 proc_net/dev — htop 네트워크 미터·psutil·ifconfig가 /proc/net/dev를 읽는다 */
    if (strncmp(path, "/proc/net/", 10) == 0)
        return snprintf(alt, PATH_MAX, "%s/proc_net/%s", dir, path + 10) < PATH_MAX;
    if (strncmp(path, "/proc/", 6) != 0)
        return 0;
    name = path + 6;
    if (strcmp(name, "stat") != 0 && strcmp(name, "uptime") != 0 && strcmp(name, "loadavg") != 0 &&
        !(btop_mode() && (strcmp(name, "cpuinfo") == 0 || strcmp(name, "filesystems") == 0)))
        return 0;
    return snprintf(alt, PATH_MAX, "%s/%s", dir, name) < PATH_MAX;
}

FILE *fopen(const char *path, const char *mode)
{
    static FILE *(*real)(const char *, const char *);
    char alt[PATH_MAX];
    FILE *f, *g;
    int error;

    if (!real)
        real = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen");
    /* /proc/cpuinfo는 열리지만 model name이 없다 — btop 모드면 먼저 브리지 파일을 연다 */
    if (path && strcmp(path, "/proc/cpuinfo") == 0 && mode[0] == 'r' && !strchr(mode, '+') &&
        bridged(path, alt) && (g = real(alt, mode)))
        return g;
    f = real(path, mode);
    error = errno;
    if (f || !bridged_error(path, error) || mode[0] != 'r' || strchr(mode, '+') || !bridged(path, alt))
        return f;
    g = real(alt, mode);
    if (!g)
        errno = error;
    return g;
}

/* open과 openat 모두 실제 openat으로 연다 (open은 openat(AT_FDCWD, …)과 같다) */
static int open_bridged(int dirfd, const char *path, int flags, mode_t mode)
{
    static int (*real)(int, const char *, int, ...);
    char alt[PATH_MAX];
    int fd, error;

    if (!real)
        real = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
    fd = real(dirfd, path, flags, mode);
    error = errno;
    if (fd >= 0 || !bridged_error(path, error) || (flags & O_ACCMODE) != O_RDONLY ||
        (flags & (O_CREAT | O_TRUNC | O_APPEND)) || !bridged(path, alt))
        return fd;
    fd = real(dirfd, alt, flags, mode);
    if (fd < 0)
        errno = error;
    return fd;
}

/* mode 인자는 O_CREAT·O_TMPFILE일 때만 넘어온다 */
#define NEEDS_MODE(flags) (((flags) & O_CREAT) || ((flags) & O_TMPFILE) == O_TMPFILE)

int open(const char *path, int flags, ...)
{
    mode_t mode = 0;

    if (NEEDS_MODE(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return open_bridged(AT_FDCWD, path, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
    mode_t mode = 0;

    if (NEEDS_MODE(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return open_bridged(dirfd, path, flags, mode);
}

/* Termux htop은 /proc/stat을 열기 전에 access(R_OK)로 먼저 확인하고, 막혀 있으면 CPU를 읽지 않는다 */
static int access_bridged(int dirfd, const char *path, int mode, int flags)
{
    static int (*real)(int, const char *, int, int);
    char alt[PATH_MAX];
    int rc, error;

    if (!real)
        real = (int (*)(int, const char *, int, int))dlsym(RTLD_NEXT, "faccessat");
    rc = real(dirfd, path, mode, flags);
    error = errno;
    if (rc == 0 || !bridged_error(path, error) || (mode & (W_OK | X_OK)) || !bridged(path, alt))
        return rc;
    rc = real(dirfd, alt, mode, flags);
    if (rc != 0)
        errno = error;
    return rc;
}

int access(const char *path, int mode)
{
    return access_bridged(AT_FDCWD, path, mode, 0);
}

int faccessat(int dirfd, const char *path, int mode, int flags)
{
    return access_bridged(dirfd, path, mode, flags);
}

uid_t getuid(void)
{
    static uid_t (*real)(void);

    if (btop_mode())
        return 0;
    if (!real)
        real = (uid_t (*)(void))dlsym(RTLD_NEXT, "getuid");
    return real();
}

uid_t geteuid(void)
{
    static uid_t (*real)(void);

    if (btop_mode())
        return 0;
    if (!real)
        real = (uid_t (*)(void))dlsym(RTLD_NEXT, "geteuid");
    return real();
}

/* btop은 /sys/class/net/<if>/statistics가 없으면 0으로 보지만, 권한 오류는 예외로 죽는다 —
 * 브리지 파일이 있으면 그 정보를, 없으면 ENOENT를 돌려준다 */
static int stat_bridged(int dirfd, const char *path, struct stat *st, int flags)
{
    static int (*real)(int, const char *, struct stat *, int);
    char alt[PATH_MAX];
    int rc;

    if (!real)
        real = (int (*)(int, const char *, struct stat *, int))dlsym(RTLD_NEXT, "fstatat");
    rc = real(dirfd, path, st, flags);
    if (rc == 0 || !bridged_error(path, errno) || !path || strncmp(path, "/sys/class/net/", 15) != 0 || !bridged(path, alt))
        return rc;
    if (real(AT_FDCWD, alt, st, flags) == 0)
        return 0;
    errno = ENOENT;
    return -1;
}

int stat(const char *path, struct stat *st)
{
    return stat_bridged(AT_FDCWD, path, st, 0);
}

int fstatat(int dirfd, const char *path, struct stat *st, int flags)
{
    return stat_bridged(dirfd, path, st, flags);
}
