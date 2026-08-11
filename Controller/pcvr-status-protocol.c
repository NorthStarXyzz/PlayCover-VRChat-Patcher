#include "pcvr-status-protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/acl.h>
#include <unistd.h>

static void initialize_server(pcvr_status_server_t *server) {
    memset(server, 0, sizeof(*server));
    server->listener_descriptor = -1;
    for (size_t index = 0; index < PCVR_STATUS_MAX_CLIENTS; index++) {
        server->clients[index].descriptor = -1;
    }
}

int pcvr_path_has_no_extended_acl(const char *path) {
    errno = 0;
    acl_t acl = acl_get_file(path, ACL_TYPE_EXTENDED);
    if (acl == NULL) {
        return errno == ENOENT ? 0 : -1;
    }
    if (acl_free(acl) != 0) {
        return -1;
    }
    errno = EPERM;
    return -1;
}

int pcvr_path_must_be_absent(const char *path) {
    if (path == NULL || path[0] == '\0') {
        errno = EINVAL;
        return -1;
    }
    struct stat info = {0};
    if (lstat(path, &info) == 0) {
        errno = EBUSY;
        return -1;
    }
    return errno == ENOENT ? 0 : -1;
}

static int set_descriptor_flags(int descriptor) {
    int descriptor_flags = fcntl(descriptor, F_GETFD);
    int status_flags = fcntl(descriptor, F_GETFL);
    if (descriptor_flags < 0 || status_flags < 0 ||
        fcntl(descriptor, F_SETFD, descriptor_flags | FD_CLOEXEC) != 0 ||
        fcntl(descriptor, F_SETFL, status_flags | O_NONBLOCK) != 0) {
        return -1;
    }
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    if (setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE,
                   &enabled, sizeof(enabled)) != 0) {
        return -1;
    }
#endif
    return 0;
}

int pcvr_prepare_runtime_directory(void) {
    struct stat info = {0};
    if (lstat(PCVR_RUNTIME_DIRECTORY, &info) != 0) {
        if (errno != ENOENT || mkdir(PCVR_RUNTIME_DIRECTORY, 0700) != 0) {
            return -1;
        }
        if (chown(PCVR_RUNTIME_DIRECTORY, 0, 0) != 0 ||
            chmod(PCVR_RUNTIME_DIRECTORY, 0755) != 0 ||
            lstat(PCVR_RUNTIME_DIRECTORY, &info) != 0) {
            return -1;
        }
    }
    if (!S_ISDIR(info.st_mode) || info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & 07777) != 0755 || info.st_flags != 0 ||
        pcvr_path_has_no_extended_acl(PCVR_RUNTIME_DIRECTORY) != 0) {
        errno = EPERM;
        return -1;
    }
    return 0;
}

static int remove_stale_socket(void) {
    struct stat info = {0};
    if (lstat(PCVR_STATUS_SOCKET_PATH, &info) != 0) {
        return errno == ENOENT ? 0 : -1;
    }
    if (!S_ISSOCK(info.st_mode)) {
        errno = EPERM;
        return -1;
    }
    return unlink(PCVR_STATUS_SOCKET_PATH);
}

int pcvr_status_server_open(pcvr_status_server_t *server,
                            uid_t console_uid, gid_t console_gid) {
    initialize_server(server);
    server->console_uid = console_uid;
    server->console_gid = console_gid;
    if (geteuid() != 0 || console_uid == 0 ||
        pcvr_prepare_runtime_directory() != 0 ||
        remove_stale_socket() != 0) {
        return -1;
    }

    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0 || set_descriptor_flags(descriptor) != 0) {
        if (descriptor >= 0) {
            close(descriptor);
        }
        return -1;
    }

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (strlen(PCVR_STATUS_SOCKET_PATH) >= sizeof(address.sun_path)) {
        close(descriptor);
        errno = ENAMETOOLONG;
        return -1;
    }
    (void)snprintf(address.sun_path, sizeof(address.sun_path), "%s",
                   PCVR_STATUS_SOCKET_PATH);

    mode_t previous_umask = umask(077);
    int bind_result = bind(descriptor, (const struct sockaddr *)&address,
                           (socklen_t)sizeof(address));
    (void)umask(previous_umask);
    if (bind_result != 0 ||
        chown(PCVR_STATUS_SOCKET_PATH, console_uid, console_gid) != 0 ||
        chmod(PCVR_STATUS_SOCKET_PATH, 0600) != 0 ||
        listen(descriptor, PCVR_STATUS_MAX_CLIENTS) != 0) {
        int saved_error = errno;
        close(descriptor);
        (void)unlink(PCVR_STATUS_SOCKET_PATH);
        errno = saved_error;
        return -1;
    }

    struct stat socket_info = {0};
    if (lstat(PCVR_STATUS_SOCKET_PATH, &socket_info) != 0 ||
        !S_ISSOCK(socket_info.st_mode) ||
        socket_info.st_uid != console_uid ||
        socket_info.st_gid != console_gid ||
        (socket_info.st_mode & 0777) != 0600 || socket_info.st_flags != 0 ||
        pcvr_path_has_no_extended_acl(PCVR_STATUS_SOCKET_PATH) != 0) {
        int saved_error = errno == 0 ? EPERM : errno;
        close(descriptor);
        (void)unlink(PCVR_STATUS_SOCKET_PATH);
        errno = saved_error;
        return -1;
    }
    server->listener_descriptor = descriptor;
    server->socket_device = socket_info.st_dev;
    server->socket_inode = socket_info.st_ino;
    return 0;
}

static void close_client(pcvr_status_client_t *client) {
    if (client->descriptor >= 0) {
        close(client->descriptor);
    }
    client->descriptor = -1;
    client->input_length = 0;
    memset(client->input, 0, sizeof(client->input));
}

static int send_line(pcvr_status_client_t *client, const char *line) {
    size_t length = strlen(line);
    ssize_t amount = send(client->descriptor, line, length, 0);
    if (amount != (ssize_t)length) {
        close_client(client);
        return -1;
    }
    return 0;
}

static void broadcast_line(pcvr_status_server_t *server, const char *line) {
    for (size_t index = 0; index < PCVR_STATUS_MAX_CLIENTS; index++) {
        if (server->clients[index].descriptor >= 0) {
            (void)send_line(&server->clients[index], line);
        }
    }
}

static int format_line(char output[PCVR_STATUS_MAX_LINE],
                       const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int amount = vsnprintf(output, PCVR_STATUS_MAX_LINE, format, arguments);
    va_end(arguments);
    if (amount < 0 || amount >= PCVR_STATUS_MAX_LINE) {
        errno = EOVERFLOW;
        return -1;
    }
    return 0;
}

int pcvr_format_hello(char output[PCVR_STATUS_MAX_LINE]) {
    return format_line(output, PCVR_PROTOCOL_PREFIX " HELLO %s\n",
                       PCVR_CONTROLLER_BUILD_ID);
}

static int publish_phase(pcvr_status_server_t *server,
                         pcvr_status_phase_t phase,
                         const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int amount = vsnprintf(server->phase_line, sizeof(server->phase_line),
                           format, arguments);
    va_end(arguments);
    if (amount < 0 || amount >= (int)sizeof(server->phase_line)) {
        errno = EOVERFLOW;
        return -1;
    }
    server->phase = phase;
    if (phase != PCVR_STATUS_LEASE_ACTIVE) {
        server->metrics_line[0] = '\0';
    }
    broadcast_line(server, server->phase_line);
    return 0;
}

static int stable_code_is_valid(const char *code) {
    if (code == NULL || code[0] == '\0') {
        return 0;
    }
    for (size_t index = 0; code[index] != '\0'; index++) {
        unsigned char value = (unsigned char)code[index];
        if (!((value >= 'a' && value <= 'z') ||
              (value >= '0' && value <= '9') || value == '_') ||
            index >= 63) {
            return 0;
        }
    }
    return 1;
}

int pcvr_status_publish_waiting(pcvr_status_server_t *server,
                                uint32_t limit_mib,
                                uint32_t safe_maximum_mib) {
    if (limit_mib == 0 || safe_maximum_mib == 0 ||
        limit_mib > safe_maximum_mib) {
        errno = EINVAL;
        return -1;
    }
    return publish_phase(server, PCVR_STATUS_WAITING,
                         PCVR_PROTOCOL_PREFIX " WAITING %u %u\n",
                         limit_mib, safe_maximum_mib);
}

int pcvr_status_publish_target_bound(pcvr_status_server_t *server, pid_t pid) {
    if (pid <= 0) {
        errno = EINVAL;
        return -1;
    }
    return publish_phase(server, PCVR_STATUS_TARGET_BOUND,
                         PCVR_PROTOCOL_PREFIX " TARGET_BOUND %d\n", pid);
}

int pcvr_status_publish_lease_active(pcvr_status_server_t *server,
                                     pid_t pid, uint32_t limit_mib) {
    if (pid <= 0 || limit_mib == 0) {
        errno = EINVAL;
        return -1;
    }
    return publish_phase(server, PCVR_STATUS_LEASE_ACTIVE,
                         PCVR_PROTOCOL_PREFIX " LEASE_ACTIVE %d %u\n",
                         pid, limit_mib);
}

int pcvr_status_publish_metrics(pcvr_status_server_t *server, pid_t pid,
                                uint32_t limit_mib,
                                uint64_t footprint_bytes,
                                uint64_t headroom_bytes,
                                uint64_t reapply_count,
                                uint32_t pressure) {
    if (pid <= 0 || limit_mib == 0) {
        errno = EINVAL;
        return -1;
    }
    const uint64_t mib = 1024U * 1024U;
    uint64_t footprint_tenths =
        (footprint_bytes / mib) * 10U +
        ((footprint_bytes % mib) * 10U) / mib;
    uint64_t headroom_tenths =
        (headroom_bytes / mib) * 10U +
        ((headroom_bytes % mib) * 10U) / mib;
    if (format_line(server->metrics_line,
                    PCVR_PROTOCOL_PREFIX
                    " METRICS %d %u %llu.%llu %llu.%llu %llu %u\n",
                    pid, limit_mib,
                    (unsigned long long)(footprint_tenths / 10U),
                    (unsigned long long)(footprint_tenths % 10U),
                    (unsigned long long)(headroom_tenths / 10U),
                    (unsigned long long)(headroom_tenths % 10U),
                    (unsigned long long)reapply_count, pressure) != 0) {
        return -1;
    }
    broadcast_line(server, server->metrics_line);
    return 0;
}

int pcvr_status_publish_completed(pcvr_status_server_t *server) {
    return publish_phase(server, PCVR_STATUS_COMPLETED,
                         PCVR_PROTOCOL_PREFIX " COMPLETED\n");
}

int pcvr_status_publish_failed(pcvr_status_server_t *server,
                               const char *stable_code) {
    if (!stable_code_is_valid(stable_code)) {
        errno = EINVAL;
        return -1;
    }
    return publish_phase(server, PCVR_STATUS_FAILED,
                         PCVR_PROTOCOL_PREFIX " FAILED %s\n", stable_code);
}

pcvr_client_command_t pcvr_parse_client_command(const char *line,
                                                 size_t length) {
    static const char cancel_command[] = PCVR_PROTOCOL_PREFIX " CANCEL\n";
    if (line != NULL && length == sizeof(cancel_command) - 1U &&
        memcmp(line, cancel_command, sizeof(cancel_command) - 1U) == 0) {
        return PCVR_CLIENT_COMMAND_CANCEL;
    }
    return PCVR_CLIENT_COMMAND_INVALID;
}

int pcvr_cancel_command_is_allowed(pcvr_status_phase_t phase,
                                   pcvr_client_command_t command) {
    return phase == PCVR_STATUS_WAITING &&
           command == PCVR_CLIENT_COMMAND_CANCEL;
}

int pcvr_peer_uid_matches(int connected_socket, uid_t expected_uid) {
    uid_t peer_uid = (uid_t)-1;
    gid_t peer_gid = (gid_t)-1;
    if (getpeereid(connected_socket, &peer_uid, &peer_gid) != 0) {
        return -1;
    }
    (void)peer_gid;
    if (peer_uid != expected_uid) {
        errno = EACCES;
        return 0;
    }
    return 1;
}

static pcvr_status_client_t *available_client(pcvr_status_server_t *server) {
    for (size_t index = 0; index < PCVR_STATUS_MAX_CLIENTS; index++) {
        if (server->clients[index].descriptor < 0) {
            return &server->clients[index];
        }
    }
    return NULL;
}

static void send_snapshot(pcvr_status_server_t *server,
                          pcvr_status_client_t *client) {
    char hello[PCVR_STATUS_MAX_LINE] = {0};
    if (pcvr_format_hello(hello) != 0 ||
        send_line(client, hello) != 0) {
        return;
    }
    if (server->phase_line[0] != '\0' &&
        send_line(client, server->phase_line) != 0) {
        return;
    }
    if (server->metrics_line[0] != '\0') {
        (void)send_line(client, server->metrics_line);
    }
}

static int accept_clients(pcvr_status_server_t *server) {
    for (;;) {
        int descriptor = accept(server->listener_descriptor, NULL, NULL);
        if (descriptor < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                return 0;
            }
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (set_descriptor_flags(descriptor) != 0 ||
            pcvr_peer_uid_matches(descriptor, server->console_uid) != 1) {
            close(descriptor);
            continue;
        }
        pcvr_status_client_t *client = available_client(server);
        if (client == NULL) {
            static const char busy[] =
                PCVR_PROTOCOL_PREFIX " REJECTED client_limit\n";
            (void)send(descriptor, busy, sizeof(busy) - 1U, 0);
            close(descriptor);
            continue;
        }
        client->descriptor = descriptor;
        client->input_length = 0;
        send_snapshot(server, client);
    }
}

static void reject_client(pcvr_status_client_t *client, const char *reason) {
    char line[PCVR_STATUS_MAX_LINE] = {0};
    if (format_line(line, PCVR_PROTOCOL_PREFIX " REJECTED %s\n", reason) == 0) {
        (void)send_line(client, line);
    }
}

static int consume_client_input(pcvr_status_client_t *client,
                                pcvr_status_phase_t phase,
                                int cancellation_is_allowed) {
    for (;;) {
        if (client->input_length == sizeof(client->input)) {
            reject_client(client, "line_too_long");
            close_client(client);
            return 0;
        }
        ssize_t amount = recv(client->descriptor,
                              client->input + client->input_length,
                              sizeof(client->input) - client->input_length, 0);
        if (amount == 0) {
            close_client(client);
            return 0;
        }
        if (amount < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                return 0;
            }
            if (errno == EINTR) {
                continue;
            }
            close_client(client);
            return 0;
        }
        client->input_length += (size_t)amount;
        char *newline = memchr(client->input, '\n', client->input_length);
        if (newline == NULL) {
            continue;
        }
        size_t line_length = (size_t)(newline - client->input) + 1U;
        if (line_length != client->input_length ||
            pcvr_parse_client_command(client->input, line_length) !=
                PCVR_CLIENT_COMMAND_CANCEL) {
            reject_client(client, "unsupported_control");
            close_client(client);
            return 0;
        }
        client->input_length = 0;
        memset(client->input, 0, sizeof(client->input));
        if (!cancellation_is_allowed ||
            !pcvr_cancel_command_is_allowed(
                phase, PCVR_CLIENT_COMMAND_CANCEL)) {
            reject_client(client, "cancel_too_late");
            return 0;
        }
        return 1;
    }
}

int pcvr_status_server_pump(pcvr_status_server_t *server,
                            int cancellation_is_allowed) {
    if (server->listener_descriptor < 0 || accept_clients(server) != 0) {
        return -1;
    }
    int cancel_requested = 0;
    for (size_t index = 0; index < PCVR_STATUS_MAX_CLIENTS; index++) {
        if (server->clients[index].descriptor >= 0 &&
            consume_client_input(&server->clients[index],
                                 server->phase,
                                 cancellation_is_allowed) == 1) {
            cancel_requested = 1;
        }
    }
    return cancel_requested;
}

void pcvr_status_server_detach_after_fork(pcvr_status_server_t *server) {
    for (size_t index = 0; index < PCVR_STATUS_MAX_CLIENTS; index++) {
        close_client(&server->clients[index]);
    }
    if (server->listener_descriptor >= 0) {
        close(server->listener_descriptor);
        server->listener_descriptor = -1;
    }
    server->socket_device = 0;
    server->socket_inode = 0;
}

void pcvr_status_server_close(pcvr_status_server_t *server) {
    dev_t socket_device = server->socket_device;
    ino_t socket_inode = server->socket_inode;
    pcvr_status_server_detach_after_fork(server);
    struct stat info = {0};
    if (lstat(PCVR_STATUS_SOCKET_PATH, &info) == 0 &&
        S_ISSOCK(info.st_mode) && info.st_dev == socket_device &&
        info.st_ino == socket_inode) {
        (void)unlink(PCVR_STATUS_SOCKET_PATH);
    }
}
