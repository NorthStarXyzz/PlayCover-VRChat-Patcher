#include "../../Controller/pcvr-bundle-identity.h"
#include "../../Controller/pcvr-memory-policy.h"
#include "../../Controller/pcvr-status-protocol.h"
#include "../../Controller/pcvr-target.h"
#include "fake-backend.h"

#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <membership.h>
#include <stdio.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/socket.h>
#include <unistd.h>

static void add_test_extended_acl(const char *path);

static void expect_line(int descriptor, const char *expected) {
    char buffer[PCVR_STATUS_MAX_LINE] = {0};
    size_t expected_length = strlen(expected);
    ssize_t amount = recv(descriptor, buffer, sizeof(buffer), 0);
    assert(amount == (ssize_t)expected_length);
    assert(memcmp(buffer, expected, expected_length) == 0);
}

static void test_wire_lines(void) {
    int sockets[2] = {-1, -1};
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    pcvr_status_server_t server;
    pcvr_test_fake_status_backend(&server, sockets[0]);

    char hello[PCVR_STATUS_MAX_LINE] = {0};
    assert(pcvr_format_hello(hello) == 0);
    assert(strcmp(hello,
                  "PCVR/2 HELLO capability-vrchat-2026.2.30300-1365-r7\n") == 0);

    assert(pcvr_status_publish_waiting(&server, 18432, 18432) == 0);
    expect_line(sockets[1], "PCVR/2 WAITING 18432 18432\n");
    assert(pcvr_status_publish_target_bound(&server, 4242) == 0);
    expect_line(sockets[1], "PCVR/2 TARGET_BOUND 4242\n");
    assert(pcvr_status_publish_lease_active(&server, 4242, 18432) == 0);
    expect_line(sockets[1], "PCVR/2 LEASE_ACTIVE 4242 18432\n");
    assert(pcvr_status_publish_metrics(
               &server, 4242, 18432,
               5ULL * 1024ULL * 1024ULL * 1024ULL,
               13ULL * 1024ULL * 1024ULL * 1024ULL, 31, 1) == 0);
    expect_line(sockets[1],
                "PCVR/2 METRICS 4242 18432 5120.0 13312.0 31 1\n");
    assert(pcvr_status_publish_completed(&server) == 0);
    expect_line(sockets[1], "PCVR/2 COMPLETED\n");
    assert(pcvr_status_publish_failed(&server, "target_timeout") == 0);
    expect_line(sockets[1], "PCVR/2 FAILED target_timeout\n");
    assert(pcvr_status_publish_failed(&server, "Bad-Code") == -1);
    assert(pcvr_status_publish_waiting(&server, 20480, 18432) == -1);
    assert(pcvr_status_publish_target_bound(&server, 0) == -1);
    assert(pcvr_status_publish_lease_active(&server, 4242, 0) == -1);
    assert(pcvr_status_publish_metrics(&server, 4242, 0, 0, 0, 0, 1) == -1);

    close(sockets[0]);
    close(sockets[1]);
}

static void test_cancel_parser(void) {
    static const char cancel[] = "PCVR/2 CANCEL\n";
    static const char path_command[] = "PCVR/2 CANCEL /tmp/target\n";
    static const char limit_command[] = "PCVR/2 LIMIT 32768\n";
    static const char pid_command[] = "PCVR/2 PID 4242\n";
    static const char wait_command[] = "PCVR/2 WAIT 600\n";
    static const char old_cancel[] = "PCVR/1 CANCEL\n";
    assert(pcvr_parse_client_command(cancel, sizeof(cancel) - 1U) ==
           PCVR_CLIENT_COMMAND_CANCEL);
    assert(pcvr_parse_client_command(cancel, sizeof(cancel) - 2U) ==
           PCVR_CLIENT_COMMAND_INVALID);
    assert(pcvr_parse_client_command(path_command, sizeof(path_command) - 1U) ==
           PCVR_CLIENT_COMMAND_INVALID);
    assert(pcvr_parse_client_command(limit_command, sizeof(limit_command) - 1U) ==
           PCVR_CLIENT_COMMAND_INVALID);
    assert(pcvr_parse_client_command(pid_command, sizeof(pid_command) - 1U) ==
           PCVR_CLIENT_COMMAND_INVALID);
    assert(pcvr_parse_client_command(wait_command, sizeof(wait_command) - 1U) ==
           PCVR_CLIENT_COMMAND_INVALID);
    assert(pcvr_parse_client_command(old_cancel, sizeof(old_cancel) - 1U) ==
           PCVR_CLIENT_COMMAND_INVALID);
}

static void test_peer_credentials(void) {
    int sockets[2] = {-1, -1};
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    assert(pcvr_peer_uid_matches(sockets[0], geteuid()) == 1);
    uid_t different_uid = geteuid() == 0 ? 1U : 0U;
    assert(pcvr_peer_uid_matches(sockets[0], different_uid) == 0);
    assert(errno == EACCES);
    close(sockets[0]);
    close(sockets[1]);
}

static void test_absent_extended_acl_is_accepted(void) {
    char path[] = "/tmp/pcvr-no-acl.XXXXXX";
    assert(mkdtemp(path) != NULL);
    assert(pcvr_path_has_no_extended_acl(path) == 0);
    add_test_extended_acl(path);
    assert(pcvr_path_has_no_extended_acl(path) == -1);
    assert(errno == EPERM);
    assert(rmdir(path) == 0);
}

static void test_cancel_state_gate(void) {
    assert(pcvr_cancel_command_is_allowed(
               PCVR_STATUS_WAITING, PCVR_CLIENT_COMMAND_CANCEL));
    assert(!pcvr_cancel_command_is_allowed(
               PCVR_STATUS_TARGET_BOUND, PCVR_CLIENT_COMMAND_CANCEL));
    assert(!pcvr_cancel_command_is_allowed(
               PCVR_STATUS_LEASE_ACTIVE, PCVR_CLIENT_COMMAND_CANCEL));
    assert(!pcvr_cancel_command_is_allowed(
               PCVR_STATUS_WAITING, PCVR_CLIENT_COMMAND_INVALID));
}

static void test_fake_target_backend(void) {
    pcvr_target_backend_t backend = pcvr_test_fake_target_backend();
    pcvr_target_t target = {0};
    pcvr_test_fake_target_set_uid(501);
    pcvr_test_fake_target_set_home("/Users/Alice/");
    assert(pcvr_resolve_target_with_backend(&backend, &target) == 0);
    assert(target.uid == 501);
    assert(target.gid == 20);
    assert(strcmp(target.executable_path,
                  "/Users/Alice/Library/Containers/"
                  "io.github.northstarxyzz.PlayCoverVRChat/"
                  "Applications/com.vrchat.mobile.app/VRChat") == 0);
    assert(strcmp(target.home_path, "/Users/Alice") == 0);

    pcvr_test_fake_target_set_uid(0);
    assert(pcvr_resolve_target_with_backend(&backend, &target) == -1);
    pcvr_test_fake_target_set_uid(501);
    pcvr_test_fake_target_set_home("relative/home");
    assert(pcvr_resolve_target_with_backend(&backend, &target) == -1);
}

static uint64_t gib(uint64_t amount) {
    return amount * 1024ULL * 1024ULL * 1024ULL;
}

static void test_memory_policy(void) {
    const struct {
        uint64_t physical_gib;
        uint32_t expected_gib;
    } cases[] = {
        {8, 6}, {16, 12}, {20, 15}, {24, 18}, {32, 24}, {64, 48}
    };
    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++) {
        pcvr_memory_policy_t policy = {0};
        assert(pcvr_policy_resolve(NULL, gib(cases[index].physical_gib),
                                   &policy) == 0);
        assert(policy.mode == PCVR_MEMORY_POLICY_AUTOMATIC);
        assert(policy.selected_gib == cases[index].expected_gib);
        assert(policy.safe_maximum_gib == cases[index].expected_gib);
        assert(policy.limit_mib == cases[index].expected_gib * 1024U);
        assert(policy.safe_maximum_mib == policy.limit_mib);
        assert(policy.low_limit_warning == (policy.selected_gib < 8U));
    }

    pcvr_memory_policy_t custom = {0};
    assert(pcvr_policy_resolve("4", gib(24), &custom) == 0);
    assert(custom.mode == PCVR_MEMORY_POLICY_CUSTOM);
    assert(custom.selected_gib == 4);
    assert(custom.safe_maximum_gib == 18);
    assert(custom.limit_mib == 4096);
    assert(custom.low_limit_warning);
    assert(pcvr_policy_resolve("8", gib(24), &custom) == 0);
    assert(!custom.low_limit_warning);

    const char *invalid[] = {
        "", "0", "03", "3", "19", "+4", "-4", "4.0", "4 ",
        " 4", "4294967296", "18446744073709551615"
    };
    for (size_t index = 0; index < sizeof(invalid) / sizeof(invalid[0]); index++) {
        assert(pcvr_policy_resolve(invalid[index], gib(24), &custom) == -1);
    }
    assert(pcvr_policy_resolve(NULL, gib(5), &custom) == -1);
    assert(pcvr_policy_resolve("4", gib(5), &custom) == -1);

    uint32_t safe = 0;
    assert(pcvr_policy_safe_maximum_gib(gib(24) - 1U, &safe) == 0);
    assert(safe == 17);
}

static void add_test_extended_acl(const char *path) {
    acl_t acl = acl_init(1);
    acl_entry_t entry = NULL;
    acl_permset_t permissions = NULL;
    acl_flagset_t flags = NULL;
    uuid_t qualifier = {0};
    assert(acl != NULL);
    assert(acl_create_entry(&acl, &entry) == 0);
    assert(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0);
    assert(mbr_uid_to_uuid(geteuid(), qualifier) == 0);
    assert(acl_set_qualifier(entry, qualifier) == 0);
    assert(acl_get_permset(entry, &permissions) == 0);
    assert(acl_clear_perms(permissions) == 0);
    assert(acl_add_perm(permissions, ACL_READ_DATA) == 0);
    assert(acl_set_permset(entry, permissions) == 0);
    assert(acl_get_flagset_np(entry, &flags) == 0);
    assert(acl_clear_flags_np(flags) == 0);
    assert(acl_set_flagset_np(entry, flags) == 0);
    assert(acl_valid(acl) == 0);
    assert(acl_set_file(path, ACL_TYPE_EXTENDED, acl) == 0);
    assert(acl_free(acl) == 0);
}

static void test_safe_metadata_and_ancestor_symlink(void) {
    struct stat metadata = {0};
    metadata.st_uid = 501;
    metadata.st_mode = S_IFREG | 0755;
    assert(pcvr_safe_metadata_accepts(&metadata, 501, S_IFREG, 0));
    metadata.st_mode = S_IFREG | 0777;
    assert(!pcvr_safe_metadata_accepts(&metadata, 501, S_IFREG, 0));
    metadata.st_mode = S_IFREG | 0755;
    assert(!pcvr_safe_metadata_accepts(&metadata, 502, S_IFREG, 0));
    assert(!pcvr_safe_metadata_accepts(&metadata, 501, S_IFREG, 1));
    metadata.st_flags = UF_IMMUTABLE;
    assert(!pcvr_safe_metadata_accepts(&metadata, 501, S_IFREG, 0));

    char home[] = "/tmp/pcvr-safe-home.XXXXXX";
    assert(mkdtemp(home) != NULL);
    char real[PATH_MAX] = {0};
    char linked[PATH_MAX] = {0};
    (void)snprintf(real, sizeof(real), "%s/real", home);
    (void)snprintf(linked, sizeof(linked), "%s/linked", home);
    assert(mkdir(real, 0700) == 0);
    assert(symlink(real, linked) == 0);
    assert(pcvr_verify_safe_directory_chain(home, real, geteuid()) == 0);
    assert(pcvr_verify_safe_directory_chain(home, linked, geteuid()) == -1);
    assert(chmod(real, 0777) == 0);
    assert(pcvr_verify_safe_directory_chain(home, real, geteuid()) == -1);
    assert(chmod(real, 0700) == 0);
    add_test_extended_acl(real);
    assert(pcvr_verify_safe_directory_chain(home, real, geteuid()) == -1);
    assert(unlink(linked) == 0);
    assert(rmdir(real) == 0);
    assert(rmdir(home) == 0);
}

static void test_exact_absence_gate(void) {
    char path[] = "/tmp/pcvr-install-gate.XXXXXX";
    int descriptor = mkstemp(path);
    assert(descriptor >= 0);
    assert(close(descriptor) == 0);
    errno = 0;
    assert(pcvr_path_must_be_absent(path) == -1);
    assert(errno == EBUSY);
    assert(unlink(path) == 0);
    assert(pcvr_path_must_be_absent(path) == 0);

    char target[] = "/tmp/pcvr-install-target.XXXXXX";
    descriptor = mkstemp(target);
    assert(descriptor >= 0);
    assert(close(descriptor) == 0);
    assert(symlink(target, path) == 0);
    errno = 0;
    assert(pcvr_path_must_be_absent(path) == -1);
    assert(errno == EBUSY);
    assert(unlink(path) == 0);
    assert(unlink(target) == 0);
    errno = 0;
    assert(pcvr_path_must_be_absent(NULL) == -1);
    assert(errno == EINVAL);
}

int main(void) {
    test_wire_lines();
    test_cancel_parser();
    test_peer_credentials();
    test_absent_extended_acl_is_accepted();
    test_cancel_state_gate();
    test_fake_target_backend();
    test_memory_policy();
    test_safe_metadata_and_ancestor_symlink();
    test_exact_absence_gate();
    puts("Controller protocol tests passed.");
    return 0;
}
