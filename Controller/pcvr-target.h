#ifndef PCVR_TARGET_H
#define PCVR_TARGET_H

#include <limits.h>
#include <stddef.h>
#include <sys/types.h>

typedef struct pcvr_target {
    uid_t uid;
    gid_t gid;
    char home_path[PATH_MAX];
    char executable_path[PATH_MAX];
} pcvr_target_t;

typedef struct pcvr_target_backend {
    int (*console_uid)(uid_t *uid);
    int (*home_for_uid)(uid_t uid, gid_t *gid,
                        char *home, size_t home_capacity);
} pcvr_target_backend_t;

/* Production resolution is fixed to the owner of /dev/console and getpwuid_r.
 * No caller-provided path is accepted. */
int pcvr_resolve_console_target(pcvr_target_t *target);

/* Injectable only as a C API for non-root tests; production main calls the
 * fixed resolver above. */
int pcvr_resolve_target_with_backend(const pcvr_target_backend_t *backend,
                                     pcvr_target_t *target);

int pcvr_build_target_path(const char *home,
                           char output[PATH_MAX]);

#endif
