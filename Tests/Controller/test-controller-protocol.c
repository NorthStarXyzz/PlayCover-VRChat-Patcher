#include "../../Controller/pcvr-bundle-identity.h"
#include "../../Controller/pcvr-memory-policy.h"
#include "../../Controller/pcvr-runtime-images.h"
#include "../../Controller/pcvr-status-protocol.h"
#include "../../Controller/pcvr-target.h"
#include "fake-backend.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach-o/loader.h>
#include <membership.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/socket.h>
#include <unistd.h>

static size_t reviewed_index(const char *relative_path);
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
    assert(pcvr_parse_client_command(path_command,
                                     sizeof(path_command) - 1U) ==
           PCVR_CLIENT_COMMAND_INVALID);
    assert(pcvr_parse_client_command(limit_command,
                                     sizeof(limit_command) - 1U) ==
           PCVR_CLIENT_COMMAND_INVALID);
    assert(pcvr_parse_client_command(pid_command,
                                     sizeof(pid_command) - 1U) ==
           PCVR_CLIENT_COMMAND_INVALID);
    assert(pcvr_parse_client_command(wait_command,
                                     sizeof(wait_command) - 1U) ==
           PCVR_CLIENT_COMMAND_INVALID);
    assert(pcvr_parse_client_command(old_cancel,
                                     sizeof(old_cancel) - 1U) ==
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
        {8, 6}, {16, 12}, {20, 15}, {24, 18},
        {32, 24}, {64, 48}
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
    for (size_t index = 0; index < sizeof(invalid) / sizeof(invalid[0]);
         index++) {
        assert(pcvr_policy_resolve(invalid[index], gib(24), &custom) == -1);
    }
    assert(pcvr_policy_resolve(NULL, gib(5), &custom) == -1);
    assert(pcvr_policy_resolve("4", gib(5), &custom) == -1);

    uint32_t safe = 0;
    assert(pcvr_policy_safe_maximum_gib(gib(24) - 1U, &safe) == 0);
    assert(safe == 17);
}

static void test_reviewed_allowlist_constants(void) {
    assert(pcvr_reviewed_macho_count() == 46);
    assert(strcmp(PCVR_REVIEWED_MACHO_ALLOWLIST_SHA256,
                  "60df094badbe3fb9e8f051f07d2a38a54cfb7bd592c3cf62a69e355050ec5109") == 0);
    assert(strcmp(PCVR_REVIEWED_ENTITLEMENTS_CANONICAL_SHA256,
                  "5897ec7c1e895de492424821a7b5dbe4bea2552345244c20029a4083a4bb01f4") == 0);
    size_t main_index = reviewed_index("VRChat");
    const pcvr_reviewed_macho_entry_t *main_entry =
        pcvr_reviewed_macho_entry(main_index);
    assert(main_entry != NULL);
    assert(strcmp(main_entry->normalized_unsigned_sha256,
                  PCVR_REVIEWED_MAIN_NORMALIZED_UNSIGNED_SHA256) == 0);
    assert(strcmp(main_entry->normalized_load_commands_sha256,
                  PCVR_REVIEWED_MAIN_NORMALIZED_LOAD_COMMANDS_SHA256) == 0);
}

static void write_exact(int descriptor, const void *buffer, size_t length) {
    const uint8_t *bytes = buffer;
    size_t completed = 0;
    while (completed < length) {
        ssize_t amount = write(descriptor, bytes + completed,
                               length - completed);
        assert(amount > 0);
        completed += (size_t)amount;
    }
}

static void make_macho_fixture(char path[PATH_MAX], uint32_t signature_size,
                               uint8_t signature_byte) {
    (void)snprintf(path, PATH_MAX, "/tmp/pcvr-macho.XXXXXX");
    int descriptor = mkstemp(path);
    assert(descriptor >= 0);

    struct mach_header_64 header = {
        .magic = MH_MAGIC_64,
        .cputype = CPU_TYPE_ARM64,
        .cpusubtype = CPU_SUBTYPE_ARM64_ALL,
        .filetype = MH_EXECUTE,
        .ncmds = 3,
        .sizeofcmds =
            (uint32_t)(sizeof(struct segment_command_64) +
                       sizeof(struct uuid_command) +
                       sizeof(struct linkedit_data_command)),
        .flags = MH_NOUNDEFS | MH_DYLDLINK,
        .reserved = 0
    };
    const uint8_t fixture_uuid[16] = {
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    };
    struct uuid_command uuid = {
        .cmd = LC_UUID,
        .cmdsize = sizeof(struct uuid_command)
    };
    memcpy(uuid.uuid, fixture_uuid, sizeof(fixture_uuid));
    const uint8_t payload[] = {0xaa, 0xbb, 0xcc, 0xdd, 0xee};
    struct segment_command_64 linkedit = {
        .cmd = LC_SEGMENT_64,
        .cmdsize = sizeof(struct segment_command_64),
        .vmaddr = 0x1000,
        .vmsize = signature_size,
        .fileoff = (uint64_t)(sizeof(header) + sizeof(linkedit) +
                             sizeof(uuid) + sizeof(struct linkedit_data_command) +
                             sizeof(payload)),
        .filesize = signature_size,
        .maxprot = VM_PROT_READ,
        .initprot = VM_PROT_READ,
        .nsects = 0,
        .flags = 0
    };
    memcpy(linkedit.segname, SEG_LINKEDIT, strlen(SEG_LINKEDIT));
    struct linkedit_data_command signature = {
        .cmd = LC_CODE_SIGNATURE,
        .cmdsize = sizeof(struct linkedit_data_command),
        .dataoff = (uint32_t)(sizeof(header) + sizeof(linkedit) + sizeof(uuid) +
                             sizeof(signature) + sizeof(payload)),
        .datasize = signature_size
    };
    write_exact(descriptor, &header, sizeof(header));
    write_exact(descriptor, &linkedit, sizeof(linkedit));
    write_exact(descriptor, &uuid, sizeof(uuid));
    write_exact(descriptor, &signature, sizeof(signature));
    write_exact(descriptor, payload, sizeof(payload));
    uint8_t *signature_data = calloc(signature_size, 1);
    assert(signature_data != NULL);
    memset(signature_data, signature_byte, signature_size);
    write_exact(descriptor, signature_data, signature_size);
    free(signature_data);
    assert(close(descriptor) == 0);
}

static void test_normalized_macho_identity(void) {
    char first_path[PATH_MAX] = {0};
    char second_path[PATH_MAX] = {0};
    make_macho_fixture(first_path, 16, 0x11);
    make_macho_fixture(second_path, 48, 0x99);
    pcvr_macho_identity_t first = {0};
    pcvr_macho_identity_t second = {0};
    struct stat first_stat = {0};
    struct stat second_stat = {0};
    assert(pcvr_read_macho_identity(first_path, geteuid(), 0,
                                    &first, &first_stat) == 0);
    assert(pcvr_read_macho_identity(second_path, geteuid(), 0,
                                    &second, &second_stat) == 0);
    assert(strcmp(first.full_sha256, second.full_sha256) != 0);
    assert(strcmp(first.normalized_unsigned_sha256,
                  second.normalized_unsigned_sha256) == 0);
    assert(strcmp(first.normalized_load_commands_sha256,
                  second.normalized_load_commands_sha256) == 0);
    assert(memcmp(first.executable_uuid, second.executable_uuid, 16) == 0);
    add_test_extended_acl(first_path);
    assert(pcvr_read_macho_identity(first_path, geteuid(), 0,
                                    &first, &first_stat) == -1);
    assert(unlink(first_path) == 0);
    assert(unlink(second_path) == 0);
}

static void test_optional_reviewed_bundle(void) {
    const char *executable = getenv("PCVR_TEST_REVIEWED_EXECUTABLE");
    const char *home = getenv("HOME");
    if (executable == NULL || executable[0] == '\0') {
        return;
    }
    assert(home != NULL && home[0] == '/');
    pcvr_target_t reviewed = {
        .uid = geteuid(),
        .gid = getegid()
    };
    assert(strlen(home) < sizeof(reviewed.home_path));
    assert(strlen(executable) < sizeof(reviewed.executable_path));
    (void)snprintf(reviewed.home_path, sizeof(reviewed.home_path), "%s", home);
    (void)snprintf(reviewed.executable_path,
                   sizeof(reviewed.executable_path), "%s", executable);
    pcvr_reviewed_bundle_t reviewed_bundle = {0};
    int verify_result = pcvr_verify_reviewed_bundle(&reviewed,
                                                    &reviewed_bundle);
    if (verify_result != 0) {
        perror("optional reviewed bundle gate");
    }
    assert(verify_result == 0);
}

static size_t reviewed_index(const char *relative_path) {
    for (size_t index = 0; index < pcvr_reviewed_macho_count(); index++) {
        const pcvr_reviewed_macho_entry_t *entry =
            pcvr_reviewed_macho_entry(index);
        if (entry != NULL && strcmp(entry->relative_path, relative_path) == 0) {
            return index;
        }
    }
    assert(0 && "required reviewed path missing");
    return 0;
}

static struct stat fake_code_stat(uint32_t device, uint64_t inode,
                                  mode_t permissions) {
    struct stat value = {0};
    value.st_dev = (dev_t)device;
    value.st_ino = inode;
    value.st_uid = 501;
    value.st_gid = 20;
    value.st_mode = S_IFREG | permissions;
    value.st_nlink = 1;
    value.st_size = 4096;
    value.st_flags = 0;
    value.st_mtimespec.tv_sec = 100;
    value.st_mtimespec.tv_nsec = 200;
    value.st_ctimespec.tv_sec = 300;
    value.st_ctimespec.tv_nsec = 400;
    return value;
}

static pcvr_mapped_image_region_t fake_region(
    const pcvr_reviewed_bundle_t *bundle, size_t index, uint32_t protection) {
    pcvr_mapped_image_region_t region = {0};
    const struct stat *source = &bundle->macho_stats[index];
    region.protection = protection;
    region.device = (uint64_t)(uint32_t)source->st_dev;
    region.inode = source->st_ino;
    region.size = (uint64_t)source->st_size;
    region.uid = source->st_uid;
    region.mode = source->st_mode;
    region.flags = source->st_flags;
    region.modification_seconds = source->st_mtimespec.tv_sec;
    region.modification_nanoseconds = source->st_mtimespec.tv_nsec;
    region.change_seconds = source->st_ctimespec.tv_sec;
    region.change_nanoseconds = source->st_ctimespec.tv_nsec;
    assert(pcvr_reviewed_macho_absolute_path(bundle, index, region.path) == 0);
    return region;
}

static pcvr_reviewed_bundle_t fake_reviewed_bundle(void) {
    pcvr_reviewed_bundle_t bundle = {0};
    (void)snprintf(bundle.home_path, sizeof(bundle.home_path), "/Users/Test");
    (void)snprintf(bundle.app_root, sizeof(bundle.app_root),
                   "/Users/Test/Library/Containers/"
                   "io.github.northstarxyzz.PlayCoverVRChat/Applications/"
                   "com.vrchat.mobile.app");
    for (size_t index = 0; index < pcvr_reviewed_macho_count(); index++) {
        bundle.macho_stats[index] =
            fake_code_stat(42, (uint64_t)1000U + index, 0644);
    }
    bundle.macho_stats[reviewed_index("VRChat")].st_mode = S_IFREG | 0755;
    return bundle;
}

static void accept_required_regions(pcvr_runtime_image_evaluator_t *evaluator,
                                    const pcvr_reviewed_bundle_t *bundle,
                                    int include_libloader) {
    const char *required[] = {
        "VRChat",
        "Frameworks/UnityFramework.framework/UnityFramework",
        "Frameworks/libloader.framework/libloader"
    };
    size_t count = include_libloader ? 3U : 2U;
    for (size_t item = 0; item < count; item++) {
        size_t index = reviewed_index(required[item]);
        pcvr_mapped_image_region_t region =
            fake_region(bundle, index, VM_PROT_READ | VM_PROT_EXECUTE);
        assert(pcvr_runtime_image_evaluator_accept(evaluator, &region) == 0);
    }
}

static void test_runtime_image_evaluator(void) {
    pcvr_reviewed_bundle_t bundle = fake_reviewed_bundle();
    pcvr_runtime_image_evaluator_t evaluator;
    pcvr_runtime_image_evaluator_init(&evaluator, &bundle);
    accept_required_regions(&evaluator, &bundle, 1);

    size_t optional_index = reviewed_index(
        "Frameworks/AVProVideo.framework/AVProVideo");
    pcvr_mapped_image_region_t optional = fake_region(
        &bundle, optional_index, VM_PROT_READ | VM_PROT_EXECUTE);
    assert(pcvr_runtime_image_evaluator_accept(&evaluator, &optional) == 0);
    pcvr_mapped_image_region_t system = {
        .protection = VM_PROT_READ | VM_PROT_EXECUTE,
        .device = 1,
        .inode = 2,
        .size = 4096,
        .uid = 0,
        .mode = S_IFREG | 0555
    };
    (void)snprintf(system.path, sizeof(system.path),
                   "/System/Library/Frameworks/AppKit.framework/AppKit");
    assert(pcvr_runtime_image_evaluator_accept(&evaluator, &system) == 0);
    pcvr_mapped_image_region_t anonymous = {
        .protection = VM_PROT_READ | VM_PROT_EXECUTE
    };
    assert(pcvr_runtime_image_evaluator_accept(&evaluator, &anonymous) == 0);
    assert(pcvr_runtime_image_evaluator_finish(&evaluator, 1) == 0);

    pcvr_runtime_image_evaluator_init(&evaluator, &bundle);
    accept_required_regions(&evaluator, &bundle, 0);
    assert(pcvr_runtime_image_evaluator_finish(&evaluator, 1) == -1);

    pcvr_runtime_image_evaluator_init(&evaluator, &bundle);
    pcvr_mapped_image_region_t swapped = fake_region(
        &bundle, reviewed_index("VRChat"),
        VM_PROT_READ | VM_PROT_EXECUTE);
    swapped.inode++;
    assert(pcvr_runtime_image_evaluator_accept(&evaluator, &swapped) == -1);

    pcvr_runtime_image_evaluator_init(&evaluator, &bundle);
    pcvr_mapped_image_region_t modified = fake_region(
        &bundle, reviewed_index("VRChat"),
        VM_PROT_READ | VM_PROT_EXECUTE);
    modified.change_nanoseconds++;
    assert(pcvr_runtime_image_evaluator_accept(&evaluator, &modified) == -1);

    pcvr_runtime_image_evaluator_init(&evaluator, &bundle);
    pcvr_mapped_image_region_t tampered_nested = fake_region(
        &bundle, optional_index, VM_PROT_READ | VM_PROT_EXECUTE);
    tampered_nested.inode++;
    assert(pcvr_runtime_image_evaluator_accept(&evaluator,
                                               &tampered_nested) == -1);

    pcvr_runtime_image_evaluator_init(&evaluator, &bundle);
    pcvr_mapped_image_region_t unexpected = {
        .protection = VM_PROT_READ | VM_PROT_EXECUTE,
        .uid = 501,
        .mode = S_IFREG | 0755
    };
    (void)snprintf(unexpected.path, sizeof(unexpected.path),
                   "%s/Frameworks/Injected.framework/Injected",
                   bundle.app_root);
    assert(pcvr_runtime_image_evaluator_accept(&evaluator, &unexpected) == -1);

    pcvr_runtime_image_evaluator_init(&evaluator, &bundle);
    pcvr_mapped_image_region_t unlinked_image = {
        .protection = VM_PROT_READ | VM_PROT_EXECUTE,
        .device = 42,
        .inode = 9999
    };
    assert(pcvr_runtime_image_evaluator_accept(&evaluator,
                                               &unlinked_image) == -1);

    pcvr_runtime_image_evaluator_init(&evaluator, &bundle);
    pcvr_mapped_image_region_t not_executable = fake_region(
        &bundle, reviewed_index("VRChat"), VM_PROT_READ);
    assert(pcvr_runtime_image_evaluator_accept(&evaluator,
                                               &not_executable) == 0);
    assert(pcvr_runtime_image_evaluator_finish(&evaluator, 1) == -1);
}

typedef struct region_test_context {
    size_t count;
    int executable_found;
    char executable_path[PROC_PIDPATHINFO_MAXSIZE];
    struct stat executable_stat;
} region_test_context_t;

static int count_region(const pcvr_mapped_image_region_t *region,
                        void *opaque_context) {
    region_test_context_t *context = opaque_context;
    context->count++;
    if (strcmp(region->path, context->executable_path) == 0 &&
        (region->protection & VM_PROT_EXECUTE) != 0) {
        assert(region->device ==
               (uint64_t)(uint32_t)context->executable_stat.st_dev);
        assert(region->inode == context->executable_stat.st_ino);
        assert(region->size == (uint64_t)context->executable_stat.st_size);
        assert(region->uid == context->executable_stat.st_uid);
        assert(region->mode == context->executable_stat.st_mode);
        assert(region->modification_seconds ==
               context->executable_stat.st_mtimespec.tv_sec);
        assert(region->modification_nanoseconds ==
               context->executable_stat.st_mtimespec.tv_nsec);
        assert(region->change_seconds ==
               context->executable_stat.st_ctimespec.tv_sec);
        assert(region->change_nanoseconds ==
               context->executable_stat.st_ctimespec.tv_nsec);
        context->executable_found = 1;
    }
    return 0;
}

static void test_public_region_enumerator(void) {
    region_test_context_t context = {0};
    assert(proc_pidpath(getpid(), context.executable_path,
                        (uint32_t)sizeof(context.executable_path)) > 0);
    assert(lstat(context.executable_path, &context.executable_stat) == 0);
    int result = pcvr_runtime_enumerate_regions(getpid(), count_region,
                                                &context);
    if (result != 0) {
        fprintf(stderr, "public region enumerator count=%zu: %s\n",
                context.count, strerror(errno));
    }
    assert(result == 0);
    assert(context.count > 0);
    assert(context.executable_found);
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
    struct stat metadata = fake_code_stat(1, 2, 0755);
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
    test_reviewed_allowlist_constants();
    test_normalized_macho_identity();
    test_runtime_image_evaluator();
    test_public_region_enumerator();
    test_safe_metadata_and_ancestor_symlink();
    test_exact_absence_gate();
    test_optional_reviewed_bundle();
    puts("Controller protocol tests passed.");
    return 0;
}
