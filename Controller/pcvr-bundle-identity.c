#include "pcvr-bundle-identity.h"

#include <errno.h>
#include <limits.h>
#include <string.h>
#include <sys/acl.h>
#include <unistd.h>

static int path_has_extended_acl(const char *path) {
    errno = 0;
    acl_t acl = acl_get_file(path, ACL_TYPE_EXTENDED);
    if (acl == NULL) {
        return errno == ENOENT ? 0 : -1;
    }
    if (acl_free(acl) != 0) {
        return -1;
    }
    return 1;
}

int pcvr_safe_metadata_accepts(const struct stat *metadata,
                               uid_t expected_uid, mode_t expected_type,
                               int has_extended_acl) {
    const uint32_t dangerous_flags =
        UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND;
    return metadata != NULL && metadata->st_uid == expected_uid &&
           (metadata->st_mode & S_IFMT) == expected_type &&
           (metadata->st_mode & 0022) == 0 &&
           (metadata->st_flags & dangerous_flags) == 0 &&
           has_extended_acl == 0;
}

static int verify_safe_directory(const char *path, uid_t expected_uid) {
    struct stat metadata = {0};
    int acl_state = 0;
    if (lstat(path, &metadata) != 0 ||
        (acl_state = path_has_extended_acl(path)) < 0 ||
        !pcvr_safe_metadata_accepts(&metadata, expected_uid, S_IFDIR,
                                    acl_state)) {
        errno = EPERM;
        return -1;
    }
    return 0;
}

int pcvr_verify_safe_directory_chain(const char *home_path,
                                     const char *directory_path,
                                     uid_t expected_uid) {
    if (home_path == NULL || directory_path == NULL || home_path[0] != '/' ||
        expected_uid == 0) {
        errno = EINVAL;
        return -1;
    }
    size_t home_length = strlen(home_path);
    while (home_length > 1U && home_path[home_length - 1U] == '/') {
        home_length--;
    }
    if (strlen(directory_path) < home_length ||
        strncmp(directory_path, home_path, home_length) != 0 ||
        (directory_path[home_length] != '\0' &&
         directory_path[home_length] != '/')) {
        errno = EINVAL;
        return -1;
    }
    char component[PATH_MAX] = {0};
    if (home_length >= sizeof(component)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(component, home_path, home_length);
    component[home_length] = '\0';
    if (verify_safe_directory(component, expected_uid) != 0) {
        return -1;
    }
    size_t full_length = strlen(directory_path);
    for (size_t cursor = home_length; cursor < full_length;) {
        if (directory_path[cursor] != '/') {
            errno = EINVAL;
            return -1;
        }
        cursor++;
        if (cursor == full_length) {
            errno = EINVAL;
            return -1;
        }
        const char *next_separator = strchr(directory_path + cursor, '/');
        size_t next = next_separator == NULL
            ? full_length : (size_t)(next_separator - directory_path);
        if (next >= sizeof(component)) {
            errno = ENAMETOOLONG;
            return -1;
        }
        memcpy(component, directory_path, next);
        component[next] = '\0';
        if (verify_safe_directory(component, expected_uid) != 0) {
            return -1;
        }
        cursor = next;
    }
    return 0;
}
