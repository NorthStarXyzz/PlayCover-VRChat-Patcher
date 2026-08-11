#include <bsm/libbsm.h>
#include "pcvr-bundle-identity.h"
#include "pcvr-memory-policy.h"
#include "pcvr-runtime-images.h"
#include "pcvr-status-protocol.h"
#include "pcvr-target.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* These interfaces are present in libSystem and documented in Apple's XNU
 * source, but their memorystatus declarations are not installed in the
 * consumer macOS SDK's public headers. */
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                                void *buffer, size_t buffersize);

enum {
    MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES = 7,
    MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES = 8,
    MEMORYSTATUS_CMD_GET_PROCESS_IS_MANAGED = 17
};

typedef struct memorystatus_memlimit_properties {
    int32_t memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} memorystatus_memlimit_properties_t;

typedef struct process_identity {
    pid_t pid;
    uid_t uid;
    uint64_t start_seconds;
    uint64_t start_microseconds;
    uint64_t unique_identifier;
    int32_t identifier_version;
    uint8_t executable_uuid[16];
} process_identity_t;

typedef struct proc_uniqidentifierinfo_compat {
    uint8_t executable_uuid[16];
    uint64_t unique_identifier;
    uint64_t parent_unique_identifier;
    int32_t identifier_version;
    int32_t original_parent_identifier_version;
    uint64_t reserved2;
    uint64_t reserved3;
} proc_uniqidentifierinfo_compat_t;

typedef struct proc_bsdinfowithuniqid_compat {
    struct proc_bsdinfo bsd;
    proc_uniqidentifierinfo_compat_t unique;
} proc_bsdinfowithuniqid_compat_t;

_Static_assert(sizeof(proc_uniqidentifierinfo_compat_t) == 56,
               "proc unique-identifier ABI must remain 56 bytes");

typedef struct watchdog {
    pid_t pid;
    int socket_descriptor;
    uint64_t sent_sequence;
    uint64_t acknowledged_sequence;
    uint64_t last_acknowledged_at;
} watchdog_t;

typedef struct watchdog_message {
    uint64_t sequence;
    uint8_t command;
    uint8_t reserved[7];
} watchdog_message_t;

_Static_assert(sizeof(watchdog_message_t) == 16,
               "watchdog messages must remain atomic and fixed-size");

enum {
    TARGET_GONE = 0,
    TARGET_EXACT = 1,
    TARGET_CHANGED = 2,
    TARGET_UNKNOWN = 3
};

enum {
    PROC_PIDT_BSDINFOWITHUNIQID_COMPAT = 18
};

enum {
    VM_PRESSURE_NORMAL = 0x1,
    VM_PRESSURE_WARNING = 0x2,
    VM_PRESSURE_CRITICAL = 0x4
};

#ifndef POLICY_REQUIRE_MANAGED
#define POLICY_REQUIRE_MANAGED 1
#endif
#ifndef POLICY_TARGET_UUID_BYTES
#define POLICY_TARGET_UUID_BYTES \
    0x41, 0xca, 0xdb, 0x30, 0xcc, 0xef, 0x3b, 0x6c, \
    0x8a, 0x1d, 0x23, 0x7c, 0xe5, 0xd6, 0x4c, 0x42
#endif

static const char *const expected_os_build = "25G70";
static const char *const expected_kernel_fragment = "xnu-12377.161.13~4";
static const int target_wait_seconds = 300;
static const uint8_t expected_executable_uuid[16] = {
    POLICY_TARGET_UUID_BYTES
};

static pcvr_target_t target = {0};
static pcvr_reviewed_bundle_t reviewed_bundle = {0};
static pcvr_status_server_t status_server = {.listener_descriptor = -1};

#define target_path (target.executable_path)

static volatile sig_atomic_t stop_requested = 0;

static void request_stop(int signal_number) {
    (void)signal_number;
    stop_requested = 1;
}

static int install_signal_handlers(void) {
    struct sigaction stop_action = {0};
    stop_action.sa_handler = request_stop;
    if (sigemptyset(&stop_action.sa_mask) != 0) {
        return -1;
    }
    const int stop_signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT};
    for (size_t index = 0;
         index < sizeof(stop_signals) / sizeof(stop_signals[0]); index++) {
        if (sigaction(stop_signals[index], &stop_action, NULL) != 0) {
            return -1;
        }
    }

    struct sigaction ignore_action = {0};
    ignore_action.sa_handler = SIG_IGN;
    if (sigemptyset(&ignore_action.sa_mask) != 0 ||
        sigaction(SIGPIPE, &ignore_action, NULL) != 0) {
        return -1;
    }
    return 0;
}

static int read_sysctl_string(const char *name, char *buffer, size_t capacity) {
    size_t length = capacity;
    if (sysctlbyname(name, buffer, &length, NULL, 0) != 0 || length == 0 ||
        length > capacity) {
        return -1;
    }
    buffer[capacity - 1] = '\0';
    return 0;
}

static int verify_kernel_version(void) {
    char os_build[64] = {0};
    char kernel_version[512] = {0};
    if (read_sysctl_string("kern.osversion", os_build, sizeof(os_build)) != 0 ||
        read_sysctl_string("kern.version", kernel_version,
                           sizeof(kernel_version)) != 0) {
        perror("sysctlbyname");
        return -1;
    }
    if (strcmp(os_build, expected_os_build) != 0 ||
        strstr(kernel_version, expected_kernel_fragment) == NULL) {
        fprintf(stderr,
                "Unsupported kernel/build. Expected %s and %s; found %s and:\n%s\n",
                expected_os_build, expected_kernel_fragment, os_build,
                kernel_version);
        return -1;
    }
    return 0;
}

static int acquire_singleton_lock(void) {
    if (pcvr_prepare_runtime_directory() != 0) {
        perror("prepare runtime directory");
        return -1;
    }
    int descriptor = open(PCVR_SINGLETON_LOCK_PATH,
                          O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) {
        perror("open singleton lock");
        return -1;
    }
    struct stat info = {0};
    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) ||
        info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & 07777) != 0600 || info.st_nlink != 1 ||
        info.st_flags != 0) {
        fprintf(stderr, "Unsafe singleton lock metadata at %s.\n",
                PCVR_SINGLETON_LOCK_PATH);
        close(descriptor);
        return -1;
    }
    if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        fprintf(stderr,
                "Another VRChat memory-policy controller already owns the lock.\n");
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static int verify_target_file(struct stat *target_stat) {
    if (pcvr_verify_reviewed_bundle(&target, &reviewed_bundle) != 0) {
        fprintf(stderr,
                "Target bundle failed the reviewed cross-user identity gate: "
                "%s\n",
                target_path);
        return -1;
    }
    size_t main_index = 0;
    if (pcvr_reviewed_macho_index_for_absolute_path(
            &reviewed_bundle, target_path, &main_index) != 1) {
        errno = EPERM;
        return -1;
    }
    const struct stat *reviewed_stat =
        pcvr_reviewed_macho_stat(&reviewed_bundle, main_index);
    if (reviewed_stat == NULL) {
        errno = EPERM;
        return -1;
    }
    *target_stat = *reviewed_stat;
    return 0;
}

static int read_identity(pid_t pid, process_identity_t *identity) {
    proc_bsdinfowithuniqid_compat_t info = {0};
    errno = 0;
    int size = proc_pidinfo(pid, PROC_PIDT_BSDINFOWITHUNIQID_COMPAT, 0,
                            &info, (int)sizeof(info));
    if (size != (int)sizeof(info)) {
        if (size == 0 && errno == 0) {
            errno = EIO;
        }
        return -1;
    }
    identity->pid = pid;
    identity->uid = info.bsd.pbi_uid;
    identity->start_seconds = info.bsd.pbi_start_tvsec;
    identity->start_microseconds = info.bsd.pbi_start_tvusec;
    identity->unique_identifier = info.unique.unique_identifier;
    identity->identifier_version = info.unique.identifier_version;
    memcpy(identity->executable_uuid, info.unique.executable_uuid,
           sizeof(identity->executable_uuid));
    return 0;
}

static int same_identity(const process_identity_t *left,
                         const process_identity_t *right) {
    return left->pid == right->pid && left->uid == right->uid &&
           left->start_seconds == right->start_seconds &&
           left->start_microseconds == right->start_microseconds &&
           left->unique_identifier == right->unique_identifier &&
           left->identifier_version == right->identifier_version &&
           memcmp(left->executable_uuid, right->executable_uuid,
                  sizeof(left->executable_uuid)) == 0;
}

static int same_task(const process_identity_t *left,
                     const process_identity_t *right) {
    return left->pid == right->pid &&
           left->unique_identifier == right->unique_identifier;
}

static int read_identity_bound_path(const process_identity_t *identity,
                                    char path[PROC_PIDPATHINFO_MAXSIZE]) {
    audit_token_t token = {{0}};
    token.val[5] = (uint32_t)identity->pid;
    token.val[7] = (uint32_t)identity->identifier_version;
    errno = 0;
    return proc_pidpath_audittoken(&token, path,
                                   (uint32_t)PROC_PIDPATHINFO_MAXSIZE) > 0
        ? 0 : -1;
}

static int verify_process(const process_identity_t *expected, uid_t expected_uid) {
    process_identity_t current = {0};
    if (read_identity(expected->pid, &current) != 0 ||
        !same_identity(expected, &current) || current.uid != expected_uid ||
        memcmp(current.executable_uuid, expected_executable_uuid,
               sizeof(expected_executable_uuid)) != 0) {
        return -1;
    }
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (read_identity_bound_path(&current, path) != 0 ||
        strcmp(path, target_path) != 0) {
        return -1;
    }
    return 0;
}

static int target_state(const process_identity_t *expected,
                        uid_t expected_uid) {
    process_identity_t current = {0};
    if (read_identity(expected->pid, &current) != 0) {
        return errno == ESRCH ? TARGET_GONE : TARGET_UNKNOWN;
    }
    if (!same_task(expected, &current)) {
        return TARGET_GONE;
    }
    if (current.uid != expected_uid ||
        !same_identity(expected, &current) ||
        memcmp(current.executable_uuid, expected_executable_uuid,
               sizeof(expected_executable_uuid)) != 0) {
        return TARGET_CHANGED;
    }

    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (read_identity_bound_path(&current, path) != 0) {
        process_identity_t after_failure = {0};
        if (read_identity(expected->pid, &after_failure) != 0) {
            return errno == ESRCH ? TARGET_GONE : TARGET_UNKNOWN;
        }
        if (!same_task(expected, &after_failure)) {
            return TARGET_GONE;
        }
        if (!same_identity(expected, &after_failure)) {
            return TARGET_CHANGED;
        }
        return TARGET_UNKNOWN;
    }
    if (strcmp(path, target_path) != 0) {
        return TARGET_CHANGED;
    }
    return TARGET_EXACT;
}

static uint64_t monotonic_milliseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (uint64_t)now.tv_sec * 1000U + (uint64_t)now.tv_nsec / 1000000U;
}

static int read_vm_pressure(uint32_t *pressure) {
    size_t size = sizeof(*pressure);
    *pressure = 0;
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", pressure, &size,
                     NULL, 0) != 0 || size != sizeof(*pressure)) {
        return -1;
    }
    if (*pressure != VM_PRESSURE_NORMAL &&
        *pressure != VM_PRESSURE_WARNING &&
        *pressure != VM_PRESSURE_CRITICAL) {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

static int find_target(process_identity_t *identity, uid_t expected_uid) {
    int pids[8192];
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)sizeof(pids));
    if (bytes <= 0) {
        return -1;
    }

    int count = bytes / (int)sizeof(pids[0]);
    int matches = 0;
    process_identity_t match = {0};
    const char *target_name = strrchr(target_path, '/');
    target_name = target_name == NULL ? target_path : target_name + 1;
    for (int index = 0; index < count; index++) {
        if (pids[index] <= 0) {
            continue;
        }
        char process_name[2 * MAXCOMLEN] = {0};
        if (proc_name(pids[index], process_name,
                      (uint32_t)sizeof(process_name)) <= 0 ||
            strcmp(process_name, target_name) != 0) {
            continue;
        }
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (read_identity(pids[index], &match) == 0 &&
            read_identity_bound_path(&match, path) == 0 &&
            strcmp(path, target_path) == 0 &&
            match.uid == expected_uid &&
            memcmp(match.executable_uuid, expected_executable_uuid,
                   sizeof(expected_executable_uuid)) == 0) {
            *identity = match;
            matches++;
        }
    }
    return matches;
}

static int set_soft_limit(pid_t pid, uint32_t limit_mb) {
    memorystatus_memlimit_properties_t properties = {
        .memlimit_active = (int32_t)limit_mb,
        .memlimit_active_attr = 0,
        .memlimit_inactive = (int32_t)limit_mb,
        .memlimit_inactive_attr = 0
    };
    errno = 0;
    int result = memorystatus_control(
        MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES,
        pid, 0, &properties, sizeof(properties));
    if (result != 0) {
        fprintf(stderr, "memorystatus cmd7 failed for PID %d: %s\n",
                pid, strerror(errno));
        return -1;
    }
    return 0;
}

static int original_task_liveness(const process_identity_t *identity) {
    process_identity_t current = {0};
    if (read_identity(identity->pid, &current) != 0) {
        return errno == ESRCH ? 0 : -1;
    }
    return same_task(identity, &current) ? 1 : 0;
}

static int signal_original_task(const process_identity_t *identity,
                                int signal_number) {
    process_identity_t current = {0};
    const process_identity_t *token_identity = identity;
    if (read_identity(identity->pid, &current) == 0) {
        if (!same_task(identity, &current)) {
            errno = ESRCH;
            return -1;
        }
        token_identity = &current;
    } else if (errno == ESRCH) {
        return -1;
    }

    audit_token_t token = {{0}};
    token.val[5] = (uint32_t)token_identity->pid;
    token.val[7] = (uint32_t)token_identity->identifier_version;
    int error = proc_signal_with_audittoken(&token, signal_number);
    if (error != 0) {
        errno = error;
        return -1;
    }
    return 0;
}

static int rollback_and_stop_target(const process_identity_t *identity) {
    int liveness = original_task_liveness(identity);
    if (liveness == 0) {
        fprintf(stderr,
                "The original target task has exited; its transient policy is gone.\n");
        return 0;
    }
    if (liveness < 0) {
        fprintf(stderr,
                "Could not read target identity before rollback; using the "
                "saved audit token: %s\n",
                strerror(errno));
    }

    /* Task exit is the authoritative rollback because it destroys the ledger
     * even if cmd7 partially failed or RunningBoard concurrently changed it. */
    if (signal_original_task(identity, SIGTERM) != 0) {
        if (errno == ESRCH && original_task_liveness(identity) == 0) {
            fprintf(stderr,
                    "The original audit-token target no longer exists; "
                    "rollback is complete.\n");
            return 0;
        }
        if (errno != ESRCH) {
            fprintf(stderr, "SIGTERM failed for PID %d: %s\n",
                    identity->pid, strerror(errno));
        }
    }
    for (int attempt = 0; attempt < 50; attempt++) {
        liveness = original_task_liveness(identity);
        if (liveness == 0) {
            fprintf(stderr,
                    "VRChat exited; the transient policy is fully discarded.\n");
            return 0;
        }
        usleep(100000);
    }

    fprintf(stderr,
            "VRChat did not exit after SIGTERM; escalating to SIGKILL.\n");
    if (signal_original_task(identity, SIGKILL) != 0) {
        if (errno == ESRCH && original_task_liveness(identity) == 0) {
            fprintf(stderr,
                    "The original audit-token target is gone; rollback is complete.\n");
            return 0;
        }
        if (errno != ESRCH) {
            fprintf(stderr, "SIGKILL failed for PID %d: %s\n",
                    identity->pid, strerror(errno));
        }
        return -1;
    }
    for (int attempt = 0; attempt < 50; attempt++) {
        liveness = original_task_liveness(identity);
        if (liveness == 0) {
            fprintf(stderr,
                    "VRChat exited after SIGKILL; rollback is complete.\n");
            return 0;
        }
        usleep(100000);
    }
    fprintf(stderr,
            "FATAL: the original task identity remains after SIGKILL.\n");
    return -1;
}

static void rollback_until_stopped(const process_identity_t *identity) {
    for (;;) {
        if (rollback_and_stop_target(identity) == 0) {
            return;
        }
        fprintf(stderr,
                "Rollback is not yet proven; retrying in one second.\n");
        sleep(1);
    }
}

static int start_watchdog(const process_identity_t *identity,
                          watchdog_t *watchdog,
                          pcvr_status_server_t *status) {
    int sockets[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets) != 0) {
        perror("watchdog socketpair");
        return -1;
    }
    (void)fcntl(sockets[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(sockets[1], F_SETFD, FD_CLOEXEC);
    pid_t child = fork();
    if (child < 0) {
        perror("watchdog fork");
        close(sockets[0]);
        close(sockets[1]);
        return -1;
    }
    if (child == 0) {
        close(sockets[0]);
        pcvr_status_server_detach_after_fork(status);
        if (signal(SIGHUP, SIG_IGN) == SIG_ERR ||
            signal(SIGINT, SIG_IGN) == SIG_ERR ||
            signal(SIGTERM, SIG_IGN) == SIG_ERR ||
            signal(SIGQUIT, SIG_IGN) == SIG_ERR || setsid() < 0) {
            close(sockets[1]);
            rollback_until_stopped(identity);
            _exit(0);
        }
        int null_descriptor = open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (null_descriptor < 0 ||
            dup2(null_descriptor, STDERR_FILENO) < 0) {
            if (null_descriptor >= 0) {
                close(null_descriptor);
            }
            close(sockets[1]);
            rollback_until_stopped(identity);
            _exit(0);
        }
        if (null_descriptor != STDERR_FILENO) {
            close(null_descriptor);
        }

        watchdog_message_t ready = {.sequence = 0, .command = 'R'};
        if (send(sockets[1], &ready, sizeof(ready), 0) !=
            (ssize_t)sizeof(ready)) {
            close(sockets[1]);
            rollback_until_stopped(identity);
            _exit(0);
        }
        uint64_t last_heartbeat = monotonic_milliseconds();
        int should_rollback = 0;
        while (!should_rollback) {
            struct pollfd poll_descriptor = {
                .fd = sockets[1],
                .events = POLLIN | POLLHUP | POLLERR | POLLNVAL,
                .revents = 0
            };
            int poll_result;
            poll_result = poll(&poll_descriptor, 1, 250);
            if (poll_result < 0) {
                if (errno != EINTR) {
                    break;
                }
            }
            if ((poll_descriptor.revents & POLLIN) != 0) {
                watchdog_message_t message = {0};
                ssize_t amount = recv(sockets[1], &message,
                                      sizeof(message), 0);
                if (amount != (ssize_t)sizeof(message)) {
                    break;
                }
                if (message.command == 'D') {
                    if (original_task_liveness(identity) == 0) {
                        close(sockets[1]);
                        _exit(0);
                    }
                    should_rollback = 1;
                }
                if (message.command == 'H') {
                    last_heartbeat = monotonic_milliseconds();
                    watchdog_message_t acknowledgement = {
                        .sequence = message.sequence,
                        .command = 'A'
                    };
                    if (send(sockets[1], &acknowledgement,
                             sizeof(acknowledgement), 0) !=
                        (ssize_t)sizeof(acknowledgement)) {
                        should_rollback = 1;
                    }
                }
            }
            if ((poll_descriptor.revents &
                 (POLLHUP | POLLERR | POLLNVAL)) != 0) {
                should_rollback = 1;
            }
            uint64_t now = monotonic_milliseconds();
            if (now == 0 || last_heartbeat == 0 || now < last_heartbeat ||
                now - last_heartbeat > 2000U) {
                should_rollback = 1;
            }
        }
        close(sockets[1]);

        rollback_until_stopped(identity);
        _exit(0);
    }

    close(sockets[1]);
    watchdog->pid = child;
    watchdog->socket_descriptor = sockets[0];
    watchdog->sent_sequence = 0;
    watchdog->acknowledged_sequence = 0;
    watchdog->last_acknowledged_at = 0;
    return 0;
}

static int receive_watchdog_message(watchdog_t *watchdog,
                                    uint8_t expected_command,
                                    uint64_t expected_sequence,
                                    int timeout_milliseconds) {
    struct pollfd poll_descriptor = {
        .fd = watchdog->socket_descriptor,
        .events = POLLIN | POLLHUP | POLLERR | POLLNVAL,
        .revents = 0
    };
    uint64_t started = monotonic_milliseconds();
    if (started == 0) {
        return -1;
    }
    uint64_t deadline = started + (uint64_t)(unsigned int)timeout_milliseconds;
    int poll_result = 0;
    for (;;) {
        uint64_t now = monotonic_milliseconds();
        if (now == 0 || now >= deadline) {
            errno = ETIMEDOUT;
            return -1;
        }
        int remaining = (int)(deadline - now);
        poll_result = poll(&poll_descriptor, 1, remaining);
        if (poll_result < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
    if (poll_result <= 0 ||
        (poll_descriptor.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0 ||
        (poll_descriptor.revents & POLLIN) == 0) {
        errno = ETIMEDOUT;
        return -1;
    }
    watchdog_message_t message = {0};
    if (recv(watchdog->socket_descriptor, &message, sizeof(message), 0) !=
        (ssize_t)sizeof(message) || message.command != expected_command ||
        message.sequence != expected_sequence) {
        errno = EPROTO;
        return -1;
    }
    watchdog->acknowledged_sequence = message.sequence;
    watchdog->last_acknowledged_at = monotonic_milliseconds();
    return watchdog->last_acknowledged_at == 0 ? -1 : 0;
}

static int wait_watchdog_ready(watchdog_t *watchdog) {
    return receive_watchdog_message(watchdog, 'R', 0, 500);
}

static int heartbeat_watchdog(watchdog_t *watchdog) {
    if (watchdog->socket_descriptor < 0 || watchdog->pid <= 0) {
        errno = ESRCH;
        return -1;
    }
    watchdog_message_t heartbeat = {
        .sequence = ++watchdog->sent_sequence,
        .command = 'H'
    };
    if (send(watchdog->socket_descriptor, &heartbeat,
             sizeof(heartbeat), 0) != (ssize_t)sizeof(heartbeat)) {
        return -1;
    }
    return receive_watchdog_message(watchdog, 'A', heartbeat.sequence, 250);
}

static void disarm_watchdog(watchdog_t *watchdog) {
    if (watchdog->socket_descriptor >= 0) {
        watchdog_message_t command = {.sequence = 0, .command = 'D'};
        ssize_t ignored = send(watchdog->socket_descriptor, &command,
                               sizeof(command), 0);
        (void)ignored;
        close(watchdog->socket_descriptor);
        watchdog->socket_descriptor = -1;
    }
    if (watchdog->pid > 0) {
        int status = 0;
        int exited = 0;
        for (int attempt = 0; attempt < 50; attempt++) {
            pid_t result = waitpid(watchdog->pid, &status, WNOHANG);
            if (result == watchdog->pid || (result < 0 && errno == ECHILD)) {
                exited = 1;
                break;
            }
            if (result < 0 && errno != EINTR) {
                break;
            }
            usleep(10000);
        }
        if (!exited) {
            (void)kill(watchdog->pid, SIGKILL);
            while (waitpid(watchdog->pid, &status, 0) < 0 && errno == EINTR) {
            }
        }
        watchdog->pid = 0;
    }
}

static int watchdog_is_alive(watchdog_t *watchdog) {
    if (watchdog->pid <= 0) {
        return 0;
    }
    int status = 0;
    pid_t result;
    do {
        result = waitpid(watchdog->pid, &status, WNOHANG);
    } while (result < 0 && errno == EINTR);
    if (result == 0) {
        return 1;
    }
    if (watchdog->socket_descriptor >= 0) {
        close(watchdog->socket_descriptor);
        watchdog->socket_descriptor = -1;
    }
    watchdog->pid = 0;
    return 0;
}

static void fail_closed(const process_identity_t *identity,
                        watchdog_t *watchdog) {
    rollback_until_stopped(identity);
    disarm_watchdog(watchdog);
}

static int get_policy(pid_t pid,
                      memorystatus_memlimit_properties_t *properties) {
    memset(properties, 0, sizeof(*properties));
    errno = 0;
    if (memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES,
                             pid, 0, properties, sizeof(*properties)) != 0) {
        return -1;
    }
    return 0;
}

static int policy_matches(
    const memorystatus_memlimit_properties_t *properties, int limit_mb) {
    return properties->memlimit_active == limit_mb &&
           properties->memlimit_inactive == limit_mb &&
           (properties->memlimit_active_attr & 1U) == 0 &&
           (properties->memlimit_inactive_attr & 1U) == 0;
}

static int policy_is_rbs_default_reset(
    const memorystatus_memlimit_properties_t *properties) {
    return properties->memlimit_active == -1 &&
           properties->memlimit_inactive == -1 &&
           properties->memlimit_active_attr == 0 &&
           properties->memlimit_inactive_attr == 0;
}

/* Returns 0 when verified, 1 if RunningBoard immediately restored its known
 * default, and -1 for a syscall failure or an unfamiliar post-write state. */
static int set_and_verify_policy(pid_t pid, int limit_mb) {
    if (set_soft_limit(pid, (uint32_t)limit_mb) != 0) {
        return -1;
    }
    memorystatus_memlimit_properties_t properties = {0};
    if (get_policy(pid, &properties) != 0) {
        fprintf(stderr, "Immediate policy readback failed: %s\n",
                strerror(errno));
        return -1;
    }
    if (policy_matches(&properties, limit_mb)) {
        return 0;
    }
    if (policy_is_rbs_default_reset(&properties)) {
        return 1;
    }
    fprintf(stderr,
            "Unfamiliar policy after cmd7: active=%d attr=0x%x "
            "inactive=%d attr=0x%x\n",
            properties.memlimit_active, properties.memlimit_active_attr,
            properties.memlimit_inactive, properties.memlimit_inactive_attr);
    return -1;
}

static int read_target_safety(pid_t pid, int limit_mb,
                              int require_managed_now,
                              uint64_t *footprint,
                              uint64_t *predicted_available,
                              uint32_t *pressure) {
    errno = 0;
    int managed = memorystatus_control(
        MEMORYSTATUS_CMD_GET_PROCESS_IS_MANAGED, pid, 0, NULL, 0);
    if (managed < 0 && require_managed_now) {
        fprintf(stderr, "Could not read managed state: %s\n", strerror(errno));
        return -1;
    }
    if (require_managed_now && managed != 1) {
        fprintf(stderr,
                "Target is not reported as a managed app (value=%d).\n",
                managed);
        return -1;
    }

    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4,
                        (rusage_info_t *)&usage) != 0) {
        perror("proc_pid_rusage");
        return -1;
    }
    *footprint = usage.ri_phys_footprint;
    const uint64_t limit_bytes = (uint64_t)(uint32_t)limit_mb << 20;
    if (*footprint >= limit_bytes) {
        fprintf(stderr, "Footprint has reached the configured soft limit.\n");
        return -1;
    }
    *predicted_available = limit_bytes - *footprint;

    if (read_vm_pressure(pressure) != 0) {
        perror("kern.memorystatus_vm_pressure_level");
        return -1;
    }
    if (*pressure == VM_PRESSURE_CRITICAL) {
        fprintf(stderr,
                "System memory pressure is critical; refusing policy maintenance.\n");
        return -1;
    }
    return 0;
}

static int status_server_open = 0;

static void close_status_server(void) {
    if (status_server_open) {
        pcvr_status_server_close(&status_server);
        status_server_open = 0;
    }
}

static void publish_failed(const char *stable_code) {
    if (status_server_open) {
        (void)pcvr_status_server_pump(&status_server, 0);
        (void)pcvr_status_publish_failed(&status_server, stable_code);
    }
}

static void pump_bound_status(void) {
    if (status_server_open &&
        pcvr_status_server_pump(&status_server, 0) < 0) {
        fprintf(stderr,
                "Status socket became unavailable; policy safety remains "
                "independent of UI telemetry.\n");
        close_status_server();
    }
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <limitGiB>\n", argv[0]);
        return 64;
    }
    /* The package journal is created before an old runner is quarantined and
     * remains until the complete r6 payload is verified.  This early gate
     * closes the predecessor-runner race: even a script process that survives
     * quarantine cannot start the newly published controller mid-transaction. */
    if (pcvr_path_must_be_absent(PCVR_INSTALL_JOURNAL_PATH) != 0) {
        fprintf(stderr, "A controller package transition is active.\n");
        return 75;
    }
    uint32_t requested_gib = 0;
    if (pcvr_policy_parse_requested_gib(argv[1], &requested_gib) != 0) {
        fprintf(stderr,
                "Memory limit must be one canonical ASCII decimal GiB value.\n");
        return 64;
    }

    uint64_t physical_memory = 0;
    size_t physical_memory_size = sizeof(physical_memory);
    if (sysctlbyname("hw.memsize", &physical_memory, &physical_memory_size,
                     NULL, 0) != 0 ||
        physical_memory_size != sizeof(physical_memory)) {
        perror("sysctlbyname hw.memsize");
        return 78;
    }
    pcvr_memory_policy_t policy = {0};
    uint32_t safe_maximum_gib = 0;
    if (pcvr_policy_safe_maximum_gib(physical_memory,
                                     &safe_maximum_gib) != 0) {
        fprintf(stderr, "Physical-memory policy ceiling is not representable.\n");
        return 64;
    }
    if (pcvr_policy_resolve(argv[1], physical_memory, &policy) != 0) {
        fprintf(stderr,
                "Refusing requested %u GiB policy: the exact allowed range is "
                "%u GiB through %u GiB (floor(75%% of physical memory)) in "
                "whole GiB.\n",
                requested_gib, PCVR_POLICY_MINIMUM_GIB,
                safe_maximum_gib);
        return 64;
    }
    const int policy_limit_mib = (int)policy.limit_mib;
    if (policy.low_limit_warning) {
        fprintf(stderr,
                "Warning: the selected %u GiB policy is below 8 GiB; "
                "VRChat may disable memory-intensive features.\n",
                policy.selected_gib);
    }
    if (pcvr_resolve_console_target(&target) != 0) {
        perror("resolve active console user");
        return 78;
    }

    if (verify_kernel_version() != 0) {
        return 78;
    }

    struct stat target_stat = {0};
    if (verify_target_file(&target_stat) != 0) {
        return 79;
    }
    if (geteuid() != 0) {
        fprintf(stderr,
                "Kernel/build and target hash verified. Root is required because "
                "XNU protects memorystatus_control.\n");
        return 77;
    }

    int singleton_descriptor = acquire_singleton_lock();
    if (singleton_descriptor < 0) {
        return 73;
    }
    (void)singleton_descriptor;

    if (install_signal_handlers() != 0) {
        perror("sigaction");
        return 74;
    }
    if (pcvr_status_server_open(&status_server, target.uid, target.gid) != 0) {
        perror("open PCVR status socket");
        return 74;
    }
    status_server_open = 1;
    if (atexit(close_status_server) != 0) {
        perror("atexit");
        close_status_server();
        return 74;
    }

    process_identity_t identity = {0};
    int found = find_target(&identity, target_stat.st_uid);
    if (found < 0) {
        perror("proc_listpids");
        publish_failed("process_scan");
        return 1;
    }
    if (found > 0) {
        fprintf(stderr,
                "%d matching VRChat process%s already running. Close %s first.\n",
                found, found == 1 ? " is" : "es are",
                found == 1 ? "it" : "them");
        publish_failed("target_already_running");
        return 65;
    }
    if (pcvr_status_publish_waiting(&status_server, policy.limit_mib,
                                    policy.safe_maximum_mib) != 0) {
        perror("publish WAITING");
        publish_failed("status_channel");
        return 74;
    }
    fprintf(stderr,
            "controller_pid=%d ready=1\n"
            "Verified build %s and target composite identity. Selected %u GiB "
            "of a %u GiB "
            "safe maximum. Waiting up to %d seconds for:\n%s\n",
            getpid(), expected_os_build, policy.selected_gib,
            policy.safe_maximum_gib, target_wait_seconds, target_path);

    const int polls_per_second = 200;
    uint64_t wait_started = monotonic_milliseconds();
    if (wait_started == 0) {
        fprintf(stderr, "Could not initialize the monotonic wait clock.\n");
        publish_failed("controller_clock");
        return 1;
    }
    for (;;) {
        int command_result = pcvr_status_server_pump(&status_server, 1);
        if (command_result < 0) {
            fprintf(stderr, "Status socket failed while waiting.\n");
            publish_failed("status_channel");
            return 74;
        }
        if (command_result == 1) {
            stop_requested = 1;
        }
        if (stop_requested) {
            break;
        }
        uint64_t wait_now = monotonic_milliseconds();
        if (wait_now == 0 || wait_now < wait_started) {
            fprintf(stderr, "The monotonic wait clock became invalid.\n");
            publish_failed("controller_clock");
            return 1;
        }
        if (wait_now - wait_started >=
            (uint64_t)target_wait_seconds * 1000U) {
            break;
        }
        found = find_target(&identity, target_stat.st_uid);
        if (found < 0) {
            perror("proc_listpids");
            publish_failed("process_scan");
            return 1;
        }
        if (found > 0) {
            break;
        }
        usleep(1000000 / polls_per_second);
    }
    if (stop_requested) {
        if (found == 0) {
            found = find_target(&identity, target_stat.st_uid);
            if (found < 0) {
                perror("proc_listpids during cancellation");
                publish_failed("process_scan");
                return 1;
            }
        }
        if (found > 1) {
            fprintf(stderr,
                    "Cancellation found %d matching targets; refusing an "
                    "ambiguous rollback.\n",
                    found);
            publish_failed("target_ambiguous");
            return 72;
        }
        publish_failed("cancelled");
        if (found == 1) {
            fprintf(stderr,
                    "Cancelled after binding the exact target; failing closed.\n");
            rollback_until_stopped(&identity);
        } else {
            fprintf(stderr, "Cancelled before the target launched.\n");
        }
        return 130;
    }
    if (found == 0) {
        fprintf(stderr, "Timed out without finding VRChat.\n");
        publish_failed("target_timeout");
        return 66;
    }
    if (found != 1) {
        fprintf(stderr,
                "Found %d matching VRChat processes; refusing an ambiguous target.\n",
                found);
        publish_failed("target_ambiguous");
        return 72;
    }
    watchdog_t watchdog = {
        .pid = 0,
        .socket_descriptor = -1,
        .sent_sequence = 0,
        .acknowledged_sequence = 0,
        .last_acknowledged_at = 0
    };
    if (start_watchdog(&identity, &watchdog, &status_server) != 0) {
        publish_failed("watchdog");
        rollback_until_stopped(&identity);
        return 71;
    }
    if (!watchdog_is_alive(&watchdog) ||
        wait_watchdog_ready(&watchdog) != 0 ||
        heartbeat_watchdog(&watchdog) != 0) {
        fprintf(stderr, "Watchdog failed during startup; failing closed.\n");
        publish_failed("watchdog");
        fail_closed(&identity, &watchdog);
        return 71;
    }
    (void)pcvr_status_server_pump(&status_server, 0);
    if (pcvr_status_publish_target_bound(&status_server, identity.pid) != 0) {
        fprintf(stderr, "Could not publish TARGET_BOUND; failing closed.\n");
        publish_failed("status_channel");
        fail_closed(&identity, &watchdog);
        return 74;
    }

    if (pcvr_reviewed_bundle_disk_is_unchanged(&reviewed_bundle) != 1 ||
        verify_process(&identity, target_stat.st_uid) != 0) {
        fprintf(stderr, "Target identity changed before policy application.\n");
        publish_failed("target_identity");
        fail_closed(&identity, &watchdog);
        return 67;
    }

    struct timeval observed_at = {0};
    if (gettimeofday(&observed_at, NULL) != 0) {
        perror("gettimeofday");
        publish_failed("controller_clock");
        fail_closed(&identity, &watchdog);
        return 1;
    }
    int64_t launch_delay_us =
        ((int64_t)observed_at.tv_sec - (int64_t)identity.start_seconds) * 1000000 +
        ((int64_t)observed_at.tv_usec - (int64_t)identity.start_microseconds);
    if (launch_delay_us < 0 || launch_delay_us > 500000) {
        fprintf(stderr,
                "Detected VRChat %.1f ms after process start; this is too late for a "
                "controlled launch; failing closed.\n",
                (double)launch_delay_us / 1000.0);
        publish_failed("target_detected_late");
        fail_closed(&identity, &watchdog);
        return 70;
    }
    fprintf(stderr, "Detected the verified process %.1f ms after start.\n",
            (double)launch_delay_us / 1000.0);

    if (target_state(&identity, target_stat.st_uid) != TARGET_EXACT ||
        pcvr_verify_runtime_images_until_ready(identity.pid, &reviewed_bundle,
                                               1, 2000U) != 0 ||
        target_state(&identity, target_stat.st_uid) != TARGET_EXACT) {
        fprintf(stderr,
                "The target's executable image set is not fully reviewed; "
                "failing closed.\n");
        publish_failed("runtime_images");
        fail_closed(&identity, &watchdog);
        return 67;
    }

    uint64_t footprint = 0;
    uint64_t predicted_available = 0;
    uint32_t pressure = 0;
    if (read_target_safety(identity.pid, policy_limit_mib, 0, &footprint,
                           &predicted_available, &pressure) != 0) {
        publish_failed("policy_safety");
        fail_closed(&identity, &watchdog);
        return 69;
    }

    process_identity_t unique_match = {0};
    int unique_match_count = find_target(&unique_match, target_stat.st_uid);
    if (unique_match_count != 1 || !same_identity(&identity, &unique_match)) {
        fprintf(stderr,
                "Target set became ambiguous before the first policy write; "
                "failing closed.\n");
        publish_failed("target_ambiguous");
        fail_closed(&identity, &watchdog);
        return 72;
    }

    int initial_apply_result = 1;
    for (int attempt = 0; attempt < 100 && initial_apply_result == 1;
         attempt++) {
        pump_bound_status();
        if (stop_requested ||
            target_state(&identity, target_stat.st_uid) != TARGET_EXACT ||
            !watchdog_is_alive(&watchdog) ||
            heartbeat_watchdog(&watchdog) != 0 ||
            read_target_safety(identity.pid, policy_limit_mib, 0, &footprint,
                               &predicted_available, &pressure) != 0) {
            initial_apply_result = -1;
            break;
        }
        if (target_state(&identity, target_stat.st_uid) != TARGET_EXACT) {
            initial_apply_result = -1;
            break;
        }
        initial_apply_result = set_and_verify_policy(identity.pid,
                                                     policy_limit_mib);
        if (target_state(&identity, target_stat.st_uid) != TARGET_EXACT) {
            initial_apply_result = -1;
            break;
        }
        if (initial_apply_result == 1) {
            usleep(2000);
        }
    }
    if (initial_apply_result != 0) {
        fprintf(stderr, "Could not establish a verified initial policy.\n");
        publish_failed(stop_requested ? "interrupted" : "initial_policy");
        fail_closed(&identity, &watchdog);
        return 1;
    }
    if (verify_process(&identity, target_stat.st_uid) != 0 ||
        pcvr_verify_runtime_images(identity.pid, &reviewed_bundle, 1) != 0 ||
        target_state(&identity, target_stat.st_uid) != TARGET_EXACT) {
        fprintf(stderr,
                "Target identity or executable image set changed after policy "
                "application.\n");
        publish_failed("runtime_images");
        fail_closed(&identity, &watchdog);
        return 67;
    }

    fprintf(stderr,
            "Applied a non-fatal %d MiB policy to PID %d. Maintenance has no "
            "elapsed-time limit and ends when this exact task exits.\n",
            policy_limit_mib, identity.pid);
    (void)pcvr_status_publish_lease_active(&status_server, identity.pid,
                                           policy.limit_mib);

    const int checks_per_second = 500;
    const uint64_t reset_window_milliseconds = 10000;
    enum { max_resets_per_window = 200 };
    uint64_t reset_times[max_resets_per_window] = {0};
    size_t reset_count = 0;
    size_t reset_cursor = 0;
    uint64_t total_reapply_count = 0;
    int consecutive_reapply_count = 0;
    uint64_t last_reset_log_second = UINT64_MAX;
    uint64_t suppressed_reset_logs = 0;
    uint64_t maintenance_started = monotonic_milliseconds();
    uint64_t last_watchdog_heartbeat = maintenance_started;
    uint64_t last_pressure_check = 0;
    uint64_t last_safety_check = 0;
    uint64_t last_status_log = UINT64_MAX;
    uint32_t last_pressure = UINT32_MAX;
    uint64_t next_poll_deadline = maintenance_started;
    uint64_t maximum_poll_lateness = 0;
    if (maintenance_started == 0) {
        fprintf(stderr, "Could not initialize the monotonic maintenance clock.\n");
        publish_failed("controller_clock");
        fail_closed(&identity, &watchdog);
        return 69;
    }

    for (;;) {
        pump_bound_status();
        if (!watchdog_is_alive(&watchdog)) {
            fprintf(stderr, "Watchdog exited unexpectedly; failing closed.\n");
            publish_failed("watchdog");
            fail_closed(&identity, &watchdog);
            return 71;
        }
        if (stop_requested) {
            fprintf(stderr,
                    "Controller interrupted; failing closed and stopping VRChat.\n");
            publish_failed("interrupted");
            fail_closed(&identity, &watchdog);
            return 130;
        }

        int state = target_state(&identity, target_stat.st_uid);
        if (state == TARGET_GONE) {
            fprintf(stderr,
                    "The verified VRChat task exited; policy rollback is automatic.\n");
            (void)pcvr_status_publish_completed(&status_server);
            disarm_watchdog(&watchdog);
            return 0;
        }
        if (state != TARGET_EXACT) {
            fprintf(stderr,
                    "The original task changed executable identity; failing closed.\n");
            publish_failed("target_identity");
            fail_closed(&identity, &watchdog);
            return 67;
        }

        uint64_t now = monotonic_milliseconds();
        if (now == 0 || now < maintenance_started) {
            fprintf(stderr, "The monotonic maintenance clock became invalid.\n");
            publish_failed("controller_clock");
            fail_closed(&identity, &watchdog);
            return 69;
        }
        uint64_t elapsed_milliseconds = now - maintenance_started;
        uint64_t elapsed_seconds = elapsed_milliseconds / 1000U;
        if (now - last_watchdog_heartbeat >= 100U) {
            if (heartbeat_watchdog(&watchdog) != 0) {
                fprintf(stderr,
                        "Could not heartbeat the watchdog; failing closed.\n");
                publish_failed("watchdog");
                fail_closed(&identity, &watchdog);
                return 71;
            }
            last_watchdog_heartbeat = now;
        }
        if (last_pressure_check == 0 || now - last_pressure_check >= 100U) {
            uint32_t fast_pressure = 0;
            if (read_vm_pressure(&fast_pressure) != 0 ||
                fast_pressure == VM_PRESSURE_CRITICAL) {
                fprintf(stderr,
                        "System pressure check failed or became critical; "
                        "failing closed.\n");
                publish_failed("critical_memory_pressure");
                fail_closed(&identity, &watchdog);
                return 69;
            }
            if (fast_pressure != last_pressure) {
                fprintf(stderr, "System memory-pressure flag is now 0x%x.\n",
                        fast_pressure);
                last_pressure = fast_pressure;
            }
            last_pressure_check = now;
        }

        memorystatus_memlimit_properties_t properties = {0};
        if (get_policy(identity.pid, &properties) != 0) {
            if (target_state(&identity, target_stat.st_uid) == TARGET_GONE) {
                fprintf(stderr,
                        "The verified VRChat task exited while reading policy.\n");
                (void)pcvr_status_publish_completed(&status_server);
                disarm_watchdog(&watchdog);
                return 0;
            }
            fprintf(stderr, "Could not read target policy: %s\n", strerror(errno));
            publish_failed("policy_read");
            fail_closed(&identity, &watchdog);
            return 69;
        }

        if (!policy_matches(&properties, policy_limit_mib)) {
            if (!policy_is_rbs_default_reset(&properties)) {
                fprintf(stderr,
                        "Refusing to overwrite an unfamiliar policy: active=%d "
                        "attr=0x%x inactive=%d attr=0x%x\n",
                        properties.memlimit_active,
                        properties.memlimit_active_attr,
                        properties.memlimit_inactive,
                        properties.memlimit_inactive_attr);
                publish_failed("unfamiliar_policy");
                fail_closed(&identity, &watchdog);
                return 69;
            }

            int require_managed_now =
                POLICY_REQUIRE_MANAGED && elapsed_milliseconds >= 5000U;
            if (target_state(&identity, target_stat.st_uid) != TARGET_EXACT ||
                read_target_safety(identity.pid, policy_limit_mib,
                                   require_managed_now, &footprint,
                                   &predicted_available, &pressure) != 0) {
                fprintf(stderr,
                        "Target safety validation failed before policy repair.\n");
                publish_failed("policy_safety");
                fail_closed(&identity, &watchdog);
                return 69;
            }

            if (reset_count == max_resets_per_window &&
                now - reset_times[reset_cursor] < reset_window_milliseconds) {
                fprintf(stderr,
                        "Policy was reset %d times in less than %.1f seconds; "
                        "failing closed.\n",
                        max_resets_per_window,
                        (double)reset_window_milliseconds / 1000.0);
                publish_failed("reset_rate");
                fail_closed(&identity, &watchdog);
                return 69;
            }
            reset_times[reset_cursor] = now;
            reset_cursor = (reset_cursor + 1U) % max_resets_per_window;
            if (reset_count < max_resets_per_window) {
                reset_count++;
            }

            if (stop_requested || consecutive_reapply_count >= 100) {
                fprintf(stderr,
                        "Policy maintenance could not survive a continuous reset "
                        "window.\n");
                publish_failed("continuous_reset");
                fail_closed(&identity, &watchdog);
                return 69;
            }
            if (target_state(&identity, target_stat.st_uid) != TARGET_EXACT) {
                fprintf(stderr,
                        "Target identity changed immediately before policy repair.\n");
                publish_failed("target_identity");
                fail_closed(&identity, &watchdog);
                return 67;
            }
            int repair_result = set_and_verify_policy(identity.pid,
                                                      policy_limit_mib);
            if (repair_result < 0 ||
                target_state(&identity, target_stat.st_uid) != TARGET_EXACT) {
                fprintf(stderr,
                        "Policy repair failed immediate readback or identity check.\n");
                publish_failed("policy_repair");
                fail_closed(&identity, &watchdog);
                return 69;
            }
            total_reapply_count++;
            consecutive_reapply_count =
                repair_result == 0 ? 0 : consecutive_reapply_count + 1;
            if (elapsed_seconds != last_reset_log_second) {
                fprintf(stderr,
                        "Repaired known RunningBoard reset at t=%llus "
                        "(total=%llu, immediate_repeats=%d, suppressed=%llu).\n",
                        (unsigned long long)elapsed_seconds,
                        (unsigned long long)total_reapply_count,
                        consecutive_reapply_count,
                        (unsigned long long)suppressed_reset_logs);
                last_reset_log_second = elapsed_seconds;
                suppressed_reset_logs = 0;
            } else {
                suppressed_reset_logs++;
            }
        } else {
            consecutive_reapply_count = 0;
        }

        if (last_safety_check == 0 || now - last_safety_check >= 1000U) {
            int require_managed_now =
                POLICY_REQUIRE_MANAGED && elapsed_milliseconds >= 5000U;
            if (target_state(&identity, target_stat.st_uid) != TARGET_EXACT ||
                pcvr_verify_runtime_images(identity.pid,
                                           &reviewed_bundle, 1) != 0 ||
                target_state(&identity, target_stat.st_uid) != TARGET_EXACT) {
                fprintf(stderr,
                        "Periodic executable image validation failed.\n");
                publish_failed("runtime_images");
                fail_closed(&identity, &watchdog);
                return 67;
            }
            if (read_target_safety(identity.pid, policy_limit_mib,
                                   require_managed_now, &footprint,
                                   &predicted_available, &pressure) != 0) {
                fprintf(stderr, "Periodic target safety validation failed.\n");
                publish_failed("policy_safety");
                fail_closed(&identity, &watchdog);
                return 69;
            }
            if (last_status_log == UINT64_MAX || elapsed_seconds == 1U ||
                elapsed_seconds == 10U || elapsed_seconds == 30U ||
                elapsed_seconds == 60U || elapsed_seconds == 120U ||
                elapsed_seconds >= last_status_log + 300U) {
                printf("t=%llus pid=%d footprint_mib=%.1f "
                       "predicted_available_mib=%.1f reapplies=%llu "
                       "max_poll_late_ms=%llu\n",
                   (unsigned long long)elapsed_seconds, identity.pid,
                   (double)footprint / (1024.0 * 1024.0),
                   (double)predicted_available / (1024.0 * 1024.0),
                   (unsigned long long)total_reapply_count,
                   (unsigned long long)maximum_poll_lateness);
                fflush(stdout);
                (void)pcvr_status_publish_metrics(
                    &status_server, identity.pid, policy.limit_mib, footprint,
                    predicted_available, total_reapply_count, pressure);
                last_status_log = elapsed_seconds;
            }
            last_safety_check = now;
        }

        const uint64_t poll_period_milliseconds =
            1000U / (uint64_t)checks_per_second;
        next_poll_deadline += poll_period_milliseconds;
        uint64_t after_work = monotonic_milliseconds();
        if (after_work == 0) {
            fprintf(stderr, "The monotonic poll clock became invalid.\n");
            publish_failed("controller_clock");
            fail_closed(&identity, &watchdog);
            return 69;
        }
        if (after_work < next_poll_deadline) {
            usleep((useconds_t)((next_poll_deadline - after_work) * 1000U));
        } else {
            uint64_t lateness = after_work - next_poll_deadline;
            if (lateness > maximum_poll_lateness) {
                maximum_poll_lateness = lateness;
            }
            next_poll_deadline = after_work + poll_period_milliseconds;
            usleep((useconds_t)(poll_period_milliseconds * 1000U));
        }
    }
}
