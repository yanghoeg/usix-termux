/* Reproduce Android's EACCES without depending on the host's sysfs policy. */
#define _GNU_SOURCE
#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void *native_symbol(const char *name) { return dlsym(RTLD_NEXT, name); }
static void *mock_dlsym(void *handle, const char *name);
#define dlsym mock_dlsym
#include "../assets/hostinfo_proc.c"
#undef dlsym

static int denied(const char *path)
{
    return strcmp(path, "/sys/class/net/usix-hostinfo-test/statistics/rx_bytes") == 0 ||
        strcmp(path, "/proc/stat") == 0;
}

static FILE *mock_fopen(const char *path, const char *mode)
{
    if (denied(path)) { errno = EACCES; return NULL; }
    FILE *(*real)(const char *, const char *) = native_symbol("fopen");
    return real(path, mode);
}

static int mock_openat(int dirfd, const char *path, int flags, ...)
{
    if (denied(path)) { errno = EACCES; return -1; }
    mode_t mode = 0;
    if (NEEDS_MODE(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    int (*real)(int, const char *, int, ...) = native_symbol("openat");
    return real(dirfd, path, flags, mode);
}

static int mock_faccessat(int dirfd, const char *path, int mode, int flags)
{
    if (denied(path)) { errno = EACCES; return -1; }
    int (*real)(int, const char *, int, int) = native_symbol("faccessat");
    return real(dirfd, path, mode, flags);
}

static int mock_fstatat(int dirfd, const char *path, struct stat *st, int flags)
{
    if (denied(path)) { errno = EACCES; return -1; }
    int (*real)(int, const char *, struct stat *, int) = native_symbol("fstatat");
    return real(dirfd, path, st, flags);
}

static void *mock_dlsym(void *handle, const char *name)
{
    (void)handle;
    if (!strcmp(name, "fopen")) return mock_fopen;
    if (!strcmp(name, "openat")) return mock_openat;
    if (!strcmp(name, "faccessat")) return mock_faccessat;
    if (!strcmp(name, "fstatat")) return mock_fstatat;
    return native_symbol(name);
}

#define FAILS_WITH(call, result, error) do { \
    errno = 0; \
    assert((call) == (result)); \
    assert(errno == (error)); \
} while (0)

int main(int argc, char **argv)
{
    assert(argc == 2);
    assert(setenv("TERMUX_XFCE_HOSTINFO", argv[1], 1) == 0);
    const char *path = "/sys/class/net/usix-hostinfo-test/statistics/rx_bytes";
    struct stat st;

    for (int btop = 0; btop <= 1; ++btop) {
        assert(setenv("TERMUX_XFCE_HOSTINFO_BTOP", btop ? "1" : "0", 1) == 0);
        int error = btop ? ENOENT : EACCES;
        FAILS_WITH(fopen(path, "r"), NULL, error);
        FAILS_WITH(open(path, O_RDONLY), -1, error);
        FAILS_WITH(openat(AT_FDCWD, path, O_RDONLY), -1, error);
        FAILS_WITH(access(path, R_OK), -1, error);
        FAILS_WITH(faccessat(AT_FDCWD, path, R_OK, 0), -1, error);
        FAILS_WITH(stat(path, &st), -1, error);
        FAILS_WITH(fstatat(AT_FDCWD, path, &st, 0), -1, error);

        /* Write access and other proc paths retain Android's original error. */
        FAILS_WITH(fopen(path, "r+"), NULL, EACCES);
        FAILS_WITH(open(path, O_WRONLY), -1, EACCES);
        FAILS_WITH(access(path, W_OK), -1, EACCES);
        FAILS_WITH(fopen("/proc/stat", "r"), NULL, EACCES);
        FAILS_WITH(open("/proc/stat", O_RDONLY), -1, EACCES);
        FAILS_WITH(access("/proc/stat", R_OK), -1, EACCES);
    }
    return 0;
}
