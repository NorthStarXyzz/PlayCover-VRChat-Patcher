#ifndef PCVR_STATUS_PROTOCOL_H
#define PCVR_STATUS_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#define PCVR_PROTOCOL_PREFIX "PCVR/2"
#define PCVR_CONTROLLER_BUILD_ID "25G70-vrchat-2026.2.30300-1365-r6"
#define PCVR_RUNTIME_DIRECTORY \
    "/private/var/run/io.github.northstarxyzz.pcvrpatcher"
#define PCVR_STATUS_SOCKET_PATH PCVR_RUNTIME_DIRECTORY "/session.sock"
#define PCVR_SINGLETON_LOCK_PATH PCVR_RUNTIME_DIRECTORY "/controller.lock"
#define PCVR_INSTALL_JOURNAL_PATH \
    "/private/var/db/io.github.northstarxyzz.pcvrpatcher.memory-policy.install"

enum {
    PCVR_STATUS_MAX_CLIENTS = 4,
    PCVR_STATUS_MAX_LINE = 256
};

typedef enum pcvr_status_phase {
    PCVR_STATUS_NONE = 0,
    PCVR_STATUS_WAITING,
    PCVR_STATUS_TARGET_BOUND,
    PCVR_STATUS_LEASE_ACTIVE,
    PCVR_STATUS_COMPLETED,
    PCVR_STATUS_FAILED
} pcvr_status_phase_t;

typedef enum pcvr_client_command {
    PCVR_CLIENT_COMMAND_INVALID = 0,
    PCVR_CLIENT_COMMAND_CANCEL
} pcvr_client_command_t;

typedef struct pcvr_status_client {
    int descriptor;
    char input[PCVR_STATUS_MAX_LINE];
    size_t input_length;
} pcvr_status_client_t;

typedef struct pcvr_status_server {
    int listener_descriptor;
    uid_t console_uid;
    gid_t console_gid;
    dev_t socket_device;
    ino_t socket_inode;
    pcvr_status_phase_t phase;
    char phase_line[PCVR_STATUS_MAX_LINE];
    char metrics_line[PCVR_STATUS_MAX_LINE];
    pcvr_status_client_t clients[PCVR_STATUS_MAX_CLIENTS];
} pcvr_status_server_t;

/* Creates or verifies the fixed root-owned runtime directory. */
int pcvr_prepare_runtime_directory(void);
int pcvr_path_has_no_extended_acl(const char *path);
/* Returns zero only when lstat proves that the exact path is absent. */
int pcvr_path_must_be_absent(const char *path);

/* Opens the fixed session.sock. The filesystem socket is owned by the active
 * console user with mode 0600, while the listening process remains root. */
int pcvr_status_server_open(pcvr_status_server_t *server,
                            uid_t console_uid, gid_t console_gid);
void pcvr_status_server_close(pcvr_status_server_t *server);

/* A forked guardian must close inherited descriptors without unlinking the
 * parent's socket path. */
void pcvr_status_server_detach_after_fork(pcvr_status_server_t *server);

/* Accepts authenticated console-UID clients and consumes complete commands.
 * Returns 1 only for an exact pre-bind "PCVR/2 CANCEL", 0 otherwise, and -1
 * if the listener itself can no longer be serviced. */
int pcvr_status_server_pump(pcvr_status_server_t *server,
                            int cancellation_is_allowed);

int pcvr_status_publish_waiting(pcvr_status_server_t *server,
                                uint32_t limit_mib,
                                uint32_t safe_maximum_mib);
int pcvr_status_publish_target_bound(pcvr_status_server_t *server, pid_t pid);
int pcvr_status_publish_lease_active(pcvr_status_server_t *server,
                                     pid_t pid, uint32_t limit_mib);
int pcvr_status_publish_metrics(pcvr_status_server_t *server, pid_t pid,
                                uint32_t limit_mib,
                                uint64_t footprint_bytes,
                                uint64_t headroom_bytes,
                                uint64_t reapply_count,
                                uint32_t pressure);
int pcvr_status_publish_completed(pcvr_status_server_t *server);
int pcvr_status_publish_failed(pcvr_status_server_t *server,
                               const char *stable_code);

/* Pure protocol and credential helpers used by the production transport and
 * the non-root fake-backend tests. */
pcvr_client_command_t pcvr_parse_client_command(const char *line,
                                                 size_t length);
int pcvr_cancel_command_is_allowed(pcvr_status_phase_t phase,
                                   pcvr_client_command_t command);
int pcvr_format_hello(char output[PCVR_STATUS_MAX_LINE]);
int pcvr_peer_uid_matches(int connected_socket, uid_t expected_uid);

#endif
