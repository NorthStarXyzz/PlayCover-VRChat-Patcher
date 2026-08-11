#include "fake-backend.h"

#include <errno.h>
#include <string.h>

static uid_t fake_uid = 501;
static const char *fake_home = "/Users/PCVRTest";

void pcvr_test_fake_target_set_uid(uid_t uid) {
    fake_uid = uid;
}

void pcvr_test_fake_target_set_home(const char *home) {
    fake_home = home;
}

static int fake_console_uid(uid_t *uid) {
    *uid = fake_uid;
    return 0;
}

static int fake_home_for_uid(uid_t uid, gid_t *gid,
                             char *home, size_t home_capacity) {
    if (uid != fake_uid || fake_home == NULL) {
        errno = ENOENT;
        return -1;
    }
    size_t length = strlen(fake_home);
    if (length >= home_capacity) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(home, fake_home, length + 1U);
    *gid = 20;
    return 0;
}

pcvr_target_backend_t pcvr_test_fake_target_backend(void) {
    const pcvr_target_backend_t backend = {
        .console_uid = fake_console_uid,
        .home_for_uid = fake_home_for_uid
    };
    return backend;
}

void pcvr_test_fake_status_backend(pcvr_status_server_t *server,
                                   int client_descriptor) {
    memset(server, 0, sizeof(*server));
    server->listener_descriptor = -1;
    for (size_t index = 0; index < PCVR_STATUS_MAX_CLIENTS; index++) {
        server->clients[index].descriptor = -1;
    }
    server->clients[0].descriptor = client_descriptor;
}
