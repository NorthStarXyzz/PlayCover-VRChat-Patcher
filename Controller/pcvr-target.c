#include "pcvr-target.h"

#include <errno.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char target_suffix[] =
    "/Library/Containers/io.github.northstarxyzz.PlayCoverVRChat/Applications/"
    "com.vrchat.mobile.app/VRChat";

int pcvr_build_target_path(const char *home, char output[PATH_MAX]) {
    if (home == NULL || home[0] != '/' || home[1] == '\0') {
        errno = EINVAL;
        return -1;
    }
    size_t home_length = strlen(home);
    while (home_length > 1U && home[home_length - 1U] == '/') {
        home_length--;
    }
    for (size_t index = 0; index < home_length; index++) {
        unsigned char value = (unsigned char)home[index];
        if (value < 0x20U || value == 0x7fU) {
            errno = EINVAL;
            return -1;
        }
    }
    int amount = snprintf(output, PATH_MAX, "%.*s%s",
                          (int)home_length, home, target_suffix);
    if (amount < 0 || amount >= PATH_MAX) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 0;
}

static int production_console_uid(uid_t *uid) {
    struct stat console_info = {0};
    if (lstat("/dev/console", &console_info) != 0 ||
        !S_ISCHR(console_info.st_mode) || console_info.st_uid == 0 ||
        console_info.st_uid == (uid_t)-1) {
        errno = ENXIO;
        return -1;
    }
    *uid = console_info.st_uid;
    return 0;
}

static int production_home_for_uid(uid_t uid, gid_t *gid,
                                   char *home, size_t home_capacity) {
    long suggested = sysconf(_SC_GETPW_R_SIZE_MAX);
    size_t buffer_size = suggested > 0 ? (size_t)suggested : 16384U;
    if (buffer_size < 1024U) {
        buffer_size = 1024U;
    }
    if (buffer_size > 1024U * 1024U) {
        buffer_size = 1024U * 1024U;
    }
    char *buffer = malloc(buffer_size);
    if (buffer == NULL) {
        return -1;
    }
    struct passwd entry = {0};
    struct passwd *result = NULL;
    int lookup_result = getpwuid_r(uid, &entry, buffer, buffer_size, &result);
    if (lookup_result != 0 || result == NULL || result->pw_uid != uid ||
        result->pw_dir == NULL || result->pw_dir[0] != '/') {
        free(buffer);
        errno = lookup_result != 0 ? lookup_result : ENOENT;
        return -1;
    }
    size_t length = strlen(result->pw_dir);
    if (length == 0 || length >= home_capacity) {
        free(buffer);
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(home, result->pw_dir, length + 1U);
    *gid = result->pw_gid;
    free(buffer);
    return 0;
}

int pcvr_resolve_target_with_backend(const pcvr_target_backend_t *backend,
                                     pcvr_target_t *target) {
    if (backend == NULL || backend->console_uid == NULL ||
        backend->home_for_uid == NULL || target == NULL) {
        errno = EINVAL;
        return -1;
    }
    memset(target, 0, sizeof(*target));
    char home[PATH_MAX] = {0};
    if (backend->console_uid(&target->uid) != 0 || target->uid == 0 ||
        target->uid == (uid_t)-1 ||
        backend->home_for_uid(target->uid, &target->gid,
                              home, sizeof(home)) != 0 ||
        target->gid == (gid_t)-1 ||
        pcvr_build_target_path(home, target->executable_path) != 0) {
        memset(target, 0, sizeof(*target));
        return -1;
    }
    size_t home_length = strlen(home);
    while (home_length > 1U && home[home_length - 1U] == '/') {
        home_length--;
    }
    if (home_length >= sizeof(target->home_path)) {
        memset(target, 0, sizeof(*target));
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(target->home_path, home, home_length);
    target->home_path[home_length] = '\0';
    return 0;
}

int pcvr_resolve_console_target(pcvr_target_t *target) {
    const pcvr_target_backend_t production_backend = {
        .console_uid = production_console_uid,
        .home_for_uid = production_home_for_uid
    };
    return pcvr_resolve_target_with_backend(&production_backend, target);
}
