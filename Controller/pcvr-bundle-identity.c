#include "pcvr-bundle-identity.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <limits.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <unistd.h>

static int stat_is_unchanged(const struct stat *before,
                             const struct stat *after) {
    return before->st_dev == after->st_dev &&
           before->st_ino == after->st_ino &&
           before->st_uid == after->st_uid &&
           before->st_gid == after->st_gid &&
           before->st_mode == after->st_mode &&
           before->st_size == after->st_size &&
           before->st_nlink == after->st_nlink &&
           before->st_flags == after->st_flags &&
           before->st_ctimespec.tv_sec == after->st_ctimespec.tv_sec &&
           before->st_ctimespec.tv_nsec == after->st_ctimespec.tv_nsec &&
           before->st_mtimespec.tv_sec == after->st_mtimespec.tv_sec &&
           before->st_mtimespec.tv_nsec == after->st_mtimespec.tv_nsec;
}

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

static int descriptor_has_extended_acl(int descriptor) {
    errno = 0;
    acl_t acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED);
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

static int pread_exact(int descriptor, void *buffer, size_t length,
                       off_t offset) {
    size_t completed = 0;
    while (completed < length) {
        ssize_t amount = pread(descriptor, (uint8_t *)buffer + completed,
                               length - completed,
                               offset + (off_t)completed);
        if (amount == 0) {
            errno = EIO;
            return -1;
        }
        if (amount < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        completed += (size_t)amount;
    }
    return 0;
}

static int sha256_descriptor_range(CC_SHA256_CTX *context, int descriptor,
                                   uint64_t offset, uint64_t length) {
    unsigned char buffer[64U * 1024U];
    while (length > 0) {
        size_t requested = length < sizeof(buffer) ? (size_t)length
                                                   : sizeof(buffer);
        ssize_t amount = pread(descriptor, buffer, requested, (off_t)offset);
        if (amount == 0) {
            errno = EIO;
            return -1;
        }
        if (amount < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (CC_SHA256_Update(context, buffer, (CC_LONG)amount) != 1) {
            errno = EIO;
            return -1;
        }
        offset += (uint64_t)amount;
        length -= (uint64_t)amount;
    }
    return 0;
}

static int finish_sha256(CC_SHA256_CTX *context,
                         char output[CC_SHA256_DIGEST_LENGTH * 2 + 1]) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (CC_SHA256_Final(digest, context) != 1) {
        errno = EIO;
        return -1;
    }
    for (size_t index = 0; index < sizeof(digest); index++) {
        (void)snprintf(output + index * 2U, 3, "%02x", digest[index]);
    }
    output[CC_SHA256_DIGEST_LENGTH * 2] = '\0';
    return 0;
}

int pcvr_read_macho_identity(const char *path, uid_t expected_uid,
                             int require_executable,
                             pcvr_macho_identity_t *identity,
                             struct stat *stable_stat) {
    if (path == NULL || identity == NULL || stable_stat == NULL) {
        errno = EINVAL;
        return -1;
    }
    memset(identity, 0, sizeof(*identity));
    memset(stable_stat, 0, sizeof(*stable_stat));

    int descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return -1;
    }
    struct stat before = {0};
    struct stat after = {0};
    struct mach_header_64 header = {0};
    if (fstat(descriptor, &before) != 0) {
        int saved_error = errno;
        close(descriptor);
        errno = saved_error;
        return -1;
    }
    int acl_state = descriptor_has_extended_acl(descriptor);
    if (!pcvr_safe_metadata_accepts(&before, expected_uid, S_IFREG,
                                    acl_state) ||
        before.st_nlink != 1 ||
        before.st_size < (off_t)sizeof(header) ||
        (require_executable && (before.st_mode & S_IXUSR) == 0)) {
        close(descriptor);
        errno = EINVAL;
        return -1;
    }
    if (pread_exact(descriptor, &header, sizeof(header), 0) != 0) {
        int saved_error = errno;
        close(descriptor);
        errno = saved_error;
        return -1;
    }
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 ||
        header.sizeofcmds > 1024U * 1024U || header.ncmds > 4096U) {
        close(descriptor);
        errno = EINVAL;
        return -1;
    }

    size_t commands_length = sizeof(header) + (size_t)header.sizeofcmds;
    if ((uint64_t)commands_length > (uint64_t)before.st_size) {
        close(descriptor);
        errno = EINVAL;
        return -1;
    }
    uint8_t *commands = malloc(commands_length);
    if (commands == NULL ||
        pread_exact(descriptor, commands, commands_length, 0) != 0) {
        int saved_error = errno;
        free(commands);
        close(descriptor);
        errno = saved_error;
        return -1;
    }

    size_t cursor = sizeof(header);
    size_t code_signature_command_offset = 0;
    uint32_t signature_offset = 0;
    uint32_t signature_size = 0;
    unsigned int uuid_count = 0;
    unsigned int signature_count = 0;
    for (uint32_t index = 0; index < header.ncmds; index++) {
        if (cursor > commands_length ||
            commands_length - cursor < sizeof(struct load_command)) {
            free(commands);
            close(descriptor);
            errno = EINVAL;
            return -1;
        }
        struct load_command *command =
            (struct load_command *)(void *)(commands + cursor);
        if (command->cmdsize < sizeof(*command) ||
            command->cmdsize > commands_length - cursor) {
            free(commands);
            close(descriptor);
            errno = EINVAL;
            return -1;
        }
        if (command->cmd == LC_UUID) {
            if (command->cmdsize != sizeof(struct uuid_command)) {
                free(commands);
                close(descriptor);
                errno = EINVAL;
                return -1;
            }
            struct uuid_command *uuid =
                (struct uuid_command *)(void *)command;
            memcpy(identity->executable_uuid, uuid->uuid,
                   sizeof(identity->executable_uuid));
            uuid_count++;
        } else if (command->cmd == LC_CODE_SIGNATURE) {
            if (command->cmdsize != sizeof(struct linkedit_data_command)) {
                free(commands);
                close(descriptor);
                errno = EINVAL;
                return -1;
            }
            struct linkedit_data_command *signature =
                (struct linkedit_data_command *)(void *)command;
            code_signature_command_offset = cursor;
            signature_offset = signature->dataoff;
            signature_size = signature->datasize;
            signature_count++;
        } else if (command->cmd == LC_SEGMENT_64 &&
                   command->cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 *segment =
                (struct segment_command_64 *)(void *)command;
            if (strncmp(segment->segname, SEG_LINKEDIT,
                        sizeof(segment->segname)) == 0) {
                segment->vmsize = 0;
                segment->filesize = 0;
            }
        }
        cursor += command->cmdsize;
    }
    uint64_t signature_end =
        (uint64_t)signature_offset + (uint64_t)signature_size;
    if (cursor != commands_length || uuid_count != 1 ||
        signature_count != 1 || signature_size == 0 ||
        signature_offset < commands_length ||
        signature_end > (uint64_t)before.st_size) {
        free(commands);
        close(descriptor);
        errno = EINVAL;
        return -1;
    }

    struct linkedit_data_command *normalized_signature =
        (struct linkedit_data_command *)(void *)(
            commands + code_signature_command_offset);
    normalized_signature->dataoff = 0;
    normalized_signature->datasize = 0;

    CC_SHA256_CTX load_context;
    CC_SHA256_CTX normalized_context;
    CC_SHA256_CTX full_context;
    if (CC_SHA256_Init(&load_context) != 1 ||
        CC_SHA256_Init(&normalized_context) != 1 ||
        CC_SHA256_Init(&full_context) != 1 ||
        CC_SHA256_Update(&load_context, commands,
                         (CC_LONG)commands_length) != 1 ||
        CC_SHA256_Update(&normalized_context, commands,
                         (CC_LONG)commands_length) != 1 ||
        sha256_descriptor_range(
            &normalized_context, descriptor, commands_length,
            (uint64_t)signature_offset - (uint64_t)commands_length) != 0 ||
        sha256_descriptor_range(
            &normalized_context, descriptor, signature_end,
            (uint64_t)before.st_size - signature_end) != 0 ||
        sha256_descriptor_range(&full_context, descriptor, 0,
                                (uint64_t)before.st_size) != 0 ||
        finish_sha256(&load_context,
                      identity->normalized_load_commands_sha256) != 0 ||
        finish_sha256(&normalized_context,
                      identity->normalized_unsigned_sha256) != 0 ||
        finish_sha256(&full_context, identity->full_sha256) != 0 ||
        fstat(descriptor, &after) != 0 ||
        !stat_is_unchanged(&before, &after)) {
        free(commands);
        close(descriptor);
        errno = EIO;
        return -1;
    }
    free(commands);
    if (close(descriptor) != 0) {
        return -1;
    }
    *stable_stat = after;
    return 0;
}

static CFMutableDictionaryRef create_expected_entitlements(const char *home) {
    const CFStringRef boolean_keys[] = {
        CFSTR("com.apple.security.app-sandbox"),
        CFSTR("com.apple.security.assets.movies.read-write"),
        CFSTR("com.apple.security.assets.music.read-write"),
        CFSTR("com.apple.security.assets.pictures.read-write"),
        CFSTR("com.apple.security.device.audio-input"),
        CFSTR("com.apple.security.device.bluetooth"),
        CFSTR("com.apple.security.device.camera"),
        CFSTR("com.apple.security.device.microphone"),
        CFSTR("com.apple.security.device.usb"),
        CFSTR("com.apple.security.files.downloads.read-write"),
        CFSTR("com.apple.security.files.user-selected.read-write"),
        CFSTR("com.apple.security.network.client"),
        CFSTR("com.apple.security.network.server"),
        CFSTR("com.apple.security.personal-information.addressbook"),
        CFSTR("com.apple.security.personal-information.calendars"),
        CFSTR("com.apple.security.personal-information.location"),
        CFSTR("com.apple.security.print")
    };
    const char *static_sbpl[] = {
        "(allow user-preference-write (preference-domain \".GlobalPreferences\"))",
        "(allow user-preference-read (preference-domain \".GlobalPreferences\"))",
        NULL,
        NULL,
        NULL,
        "(allow network* ipc-posix*)",
        "(deny process-fork)",
        "(deny file* file-read* file-read-metadata file-ioctl (literal \"/bin/bash\"))",
        "(deny file* file-read* file-read-metadata file-ioctl (literal \"/usr/sbin/sshd\"))",
        "(deny file* file-read* file-read-metadata file-ioctl (literal \"/usr/libexec/ssh-keysign\"))",
        "(deny file* file-read* file-read-metadata file-ioctl (literal \"/bin/sh\"))",
        "(deny file* file-read* file-read-metadata file-ioctl (literal \"/etc/ssh/sshd_config\"))",
        "(deny file* file-read* file-read-metadata file-ioctl (literal \"/usr/libexec/sftp-server\"))",
        "(deny file* file-read* file-read-metadata file-ioctl (literal \"/usr/bin/ssh\"))"
    };
    char original_container[PATH_MAX + 160] = {0};
    char playtools[PATH_MAX + 160] = {0};
    char group_containers[PATH_MAX + 160] = {0};
    int original_amount = snprintf(
        original_container, sizeof(original_container),
        "(allow file* file-read* file-write* file-write-data file-read-metadata "
        "file-ioctl (subpath \"%s/Library/Containers/io.playcover.PlayCover\"))",
        home);
    int playtools_amount = snprintf(
        playtools, sizeof(playtools),
        "(allow file* file-read* file-read-metadata file-ioctl "
        "(subpath \"%s/Library/Frameworks/PlayTools.framework\"))",
        home);
    int groups_amount = snprintf(
        group_containers, sizeof(group_containers),
        "(allow file* file-read* (subpath \"%s/Library/Group Containers/\"))",
        home);
    if (original_amount < 0 ||
        original_amount >= (int)sizeof(original_container) ||
        playtools_amount < 0 || playtools_amount >= (int)sizeof(playtools) ||
        groups_amount < 0 ||
        groups_amount >= (int)sizeof(group_containers)) {
        errno = EOVERFLOW;
        return NULL;
    }
    static_sbpl[2] = original_container;
    static_sbpl[3] = playtools;
    static_sbpl[4] = group_containers;

    CFMutableDictionaryRef dictionary = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFMutableArrayRef sbpl = CFArrayCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (dictionary == NULL || sbpl == NULL) {
        if (dictionary != NULL) {
            CFRelease(dictionary);
        }
        if (sbpl != NULL) {
            CFRelease(sbpl);
        }
        errno = ENOMEM;
        return NULL;
    }
    for (size_t index = 0;
         index < sizeof(boolean_keys) / sizeof(boolean_keys[0]); index++) {
        CFDictionarySetValue(dictionary, boolean_keys[index], kCFBooleanTrue);
    }
    for (size_t index = 0;
         index < sizeof(static_sbpl) / sizeof(static_sbpl[0]); index++) {
        CFStringRef value = CFStringCreateWithCString(
            kCFAllocatorDefault, static_sbpl[index], kCFStringEncodingUTF8);
        if (value == NULL) {
            CFRelease(sbpl);
            CFRelease(dictionary);
            errno = EINVAL;
            return NULL;
        }
        CFArrayAppendValue(sbpl, value);
        CFRelease(value);
    }
    CFDictionarySetValue(dictionary,
                         CFSTR("com.apple.security.temporary-exception.sbpl"),
                         sbpl);
    CFRelease(sbpl);
    return dictionary;
}

static int verify_semantic_entitlements(const char *path, const char *home) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
    SecStaticCodeRef static_code = NULL;
    CFDictionaryRef signing_information = NULL;
    CFMutableDictionaryRef expected = NULL;
    int result = -1;
    if (url == NULL ||
        SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags,
                                    &static_code) != errSecSuccess ||
        SecStaticCodeCheckValidity(
            static_code,
            kSecCSStrictValidate | kSecCSCheckAllArchitectures |
                kSecCSDoNotValidateResources,
            NULL) != errSecSuccess ||
        SecCodeCopySigningInformation(static_code, kSecCSSigningInformation,
                                      &signing_information) != errSecSuccess) {
        errno = EPERM;
        goto cleanup;
    }
    CFTypeRef actual = CFDictionaryGetValue(
        signing_information, kSecCodeInfoEntitlementsDict);
    expected = create_expected_entitlements(home);
    if (actual == NULL || expected == NULL ||
        CFGetTypeID(actual) != CFDictionaryGetTypeID() ||
        !CFEqual(actual, expected)) {
        errno = EPERM;
        goto cleanup;
    }
    result = 0;

cleanup:
    if (expected != NULL) {
        CFRelease(expected);
    }
    if (signing_information != NULL) {
        CFRelease(signing_information);
    }
    if (static_code != NULL) {
        CFRelease(static_code);
    }
    if (url != NULL) {
        CFRelease(url);
    }
    return result;
}

static int app_root_from_executable(char output[PATH_MAX],
                                    const char *executable_path) {
    const char executable_suffix[] = "/VRChat";
    size_t path_length = strlen(executable_path);
    size_t suffix_length = sizeof(executable_suffix) - 1U;
    if (path_length <= suffix_length ||
        strcmp(executable_path + path_length - suffix_length,
               executable_suffix) != 0) {
        errno = EINVAL;
        return -1;
    }
    int amount = snprintf(output, PATH_MAX, "%.*s",
                          (int)(path_length - suffix_length), executable_path);
    if (amount < 0 || amount >= PATH_MAX) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 0;
}

size_t pcvr_reviewed_macho_count(void) {
    return PCVR_REVIEWED_MACHO_COUNT;
}

const pcvr_reviewed_macho_entry_t *pcvr_reviewed_macho_entry(size_t index) {
    return index < PCVR_REVIEWED_MACHO_COUNT
        ? &pcvr_reviewed_macho_allowlist[index] : NULL;
}

const struct stat *pcvr_reviewed_macho_stat(
    const pcvr_reviewed_bundle_t *reviewed_bundle, size_t index) {
    return reviewed_bundle != NULL && index < PCVR_REVIEWED_MACHO_COUNT
        ? &reviewed_bundle->macho_stats[index] : NULL;
}

int pcvr_reviewed_macho_absolute_path(
    const pcvr_reviewed_bundle_t *reviewed_bundle, size_t index,
    char output[PATH_MAX]) {
    if (reviewed_bundle == NULL || output == NULL ||
        reviewed_bundle->app_root[0] != '/' ||
        index >= PCVR_REVIEWED_MACHO_COUNT) {
        errno = EINVAL;
        return -1;
    }
    int amount = snprintf(
        output, PATH_MAX, "%s/%s", reviewed_bundle->app_root,
        pcvr_reviewed_macho_allowlist[index].relative_path);
    if (amount < 0 || amount >= PATH_MAX) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 0;
}

int pcvr_reviewed_macho_index_for_absolute_path(
    const pcvr_reviewed_bundle_t *reviewed_bundle, const char *absolute_path,
    size_t *index) {
    if (reviewed_bundle == NULL || absolute_path == NULL || index == NULL) {
        errno = EINVAL;
        return -1;
    }
    char expected[PATH_MAX] = {0};
    for (size_t candidate = 0; candidate < PCVR_REVIEWED_MACHO_COUNT;
         candidate++) {
        if (pcvr_reviewed_macho_absolute_path(reviewed_bundle, candidate,
                                              expected) != 0) {
            return -1;
        }
        if (strcmp(expected, absolute_path) == 0) {
            *index = candidate;
            return 1;
        }
    }
    return 0;
}

static int reviewed_identity_matches(
    const pcvr_macho_identity_t *identity,
    const pcvr_reviewed_macho_entry_t *expected) {
    return strcmp(identity->normalized_unsigned_sha256,
                  expected->normalized_unsigned_sha256) == 0 &&
           strcmp(identity->normalized_load_commands_sha256,
                  expected->normalized_load_commands_sha256) == 0 &&
           memcmp(identity->executable_uuid, expected->executable_uuid,
                  sizeof(identity->executable_uuid)) == 0;
}

static int file_macho_magic(const char *path) {
    uint32_t magic = 0;
    int descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return -1;
    }
    ssize_t amount;
    do {
        amount = read(descriptor, &magic, sizeof(magic));
    } while (amount < 0 && errno == EINTR);
    int saved_error = errno;
    if (close(descriptor) != 0 && amount >= 0) {
        return -1;
    }
    if (amount < 0) {
        errno = saved_error;
        return -1;
    }
    if (amount != (ssize_t)sizeof(magic)) {
        return 0;
    }
    return magic == MH_MAGIC || magic == MH_CIGAM || magic == MH_MAGIC_64 ||
           magic == MH_CIGAM_64 || magic == FAT_MAGIC ||
           magic == FAT_CIGAM || magic == FAT_MAGIC_64 ||
           magic == FAT_CIGAM_64;
}

static int reviewed_index_for_relative(const char *relative,
                                       size_t *index) {
    for (size_t candidate = 0; candidate < PCVR_REVIEWED_MACHO_COUNT;
         candidate++) {
        if (strcmp(relative,
                   pcvr_reviewed_macho_allowlist[candidate].relative_path) == 0) {
            *index = candidate;
            return 1;
        }
    }
    return 0;
}

int pcvr_verify_reviewed_bundle(const pcvr_target_t *target,
                                pcvr_reviewed_bundle_t *reviewed_bundle) {
    if (target == NULL || reviewed_bundle == NULL || target->uid == 0 ||
        target->home_path[0] != '/' || target->executable_path[0] != '/') {
        errno = EINVAL;
        return -1;
    }
    memset(reviewed_bundle, 0, sizeof(*reviewed_bundle));
    if (strlen(target->home_path) >= sizeof(reviewed_bundle->home_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    (void)snprintf(reviewed_bundle->home_path,
                   sizeof(reviewed_bundle->home_path), "%s",
                   target->home_path);
    if (app_root_from_executable(reviewed_bundle->app_root,
                                 target->executable_path) != 0) {
        return -1;
    }
    struct stat root_stat = {0};
    if (pcvr_verify_safe_directory_chain(target->home_path,
                                         reviewed_bundle->app_root,
                                         target->uid) != 0 ||
        lstat(reviewed_bundle->app_root, &root_stat) != 0) {
        fprintf(stderr, "Unsafe reviewed bundle directory chain: %s\n",
                reviewed_bundle->app_root);
        errno = EPERM;
        return -1;
    }

    char *paths[] = {reviewed_bundle->app_root, NULL};
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (tree == NULL) {
        return -1;
    }
    int seen[PCVR_REVIEWED_MACHO_COUNT] = {0};
    int failed = 0;
    for (;;) {
        errno = 0;
        FTSENT *node = fts_read(tree);
        if (node == NULL) {
            if (errno != 0) {
                failed = 1;
            }
            break;
        }
        if (node->fts_info == FTS_SL || node->fts_info == FTS_SLNONE ||
            node->fts_info == FTS_DNR || node->fts_info == FTS_ERR ||
            node->fts_info == FTS_NS) {
            errno = EPERM;
            fprintf(stderr, "Unsafe object in reviewed bundle: %s\n",
                    node->fts_path);
            failed = 1;
            break;
        }
        if (node->fts_info == FTS_D) {
            int acl_state = path_has_extended_acl(node->fts_path);
            if (node->fts_statp == NULL ||
                !pcvr_safe_metadata_accepts(node->fts_statp, target->uid,
                                            S_IFDIR, acl_state)) {
                errno = EPERM;
                fprintf(stderr, "Unsafe directory metadata: %s\n",
                        node->fts_path);
                failed = 1;
                break;
            }
        }
        if (node->fts_info != FTS_F) {
            continue;
        }
        int macho = file_macho_magic(node->fts_path);
        if (macho < 0) {
            failed = 1;
            break;
        }
        if (!macho) {
            continue;
        }
        size_t root_length = strlen(reviewed_bundle->app_root);
        if (strncmp(node->fts_path, reviewed_bundle->app_root,
                    root_length) != 0 || node->fts_path[root_length] != '/') {
            errno = EPERM;
            failed = 1;
            break;
        }
        const char *relative = node->fts_path + root_length + 1U;
        size_t index = 0;
        if (reviewed_index_for_relative(relative, &index) != 1 || seen[index]) {
            errno = EPERM;
            fprintf(stderr, "Unreviewed or duplicate Mach-O: %s\n", relative);
            failed = 1;
            break;
        }
        pcvr_macho_identity_t identity = {0};
        if (pcvr_read_macho_identity(
                node->fts_path, target->uid,
                strcmp(relative, "VRChat") == 0,
                &identity, &reviewed_bundle->macho_stats[index]) != 0) {
            fprintf(stderr, "Could not read reviewed Mach-O: %s\n", relative);
            failed = 1;
            break;
        }
        if (!reviewed_identity_matches(
                &identity, &pcvr_reviewed_macho_allowlist[index])) {
            errno = EPERM;
            fprintf(stderr, "Reviewed Mach-O digest failed: %s\n", relative);
            failed = 1;
            break;
        }
        seen[index] = 1;
    }
    int close_result = fts_close(tree);
    if (failed || close_result != 0) {
        if (errno == 0) {
            errno = EPERM;
        }
        return -1;
    }
    for (size_t index = 0; index < PCVR_REVIEWED_MACHO_COUNT; index++) {
        if (!seen[index]) {
            errno = EPERM;
            fprintf(stderr, "Reviewed Mach-O is missing: %s\n",
                    pcvr_reviewed_macho_allowlist[index].relative_path);
            return -1;
        }
    }

    if (verify_semantic_entitlements(target->executable_path,
                                     target->home_path) != 0) {
        fprintf(stderr, "VRChat semantic entitlements are not reviewed.\n");
        return -1;
    }
    return 0;
}

static int reviewed_tree_directories_are_safe(const char *app_root,
                                              uid_t expected_uid) {
    char *paths[] = {(char *)app_root, NULL};
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (tree == NULL) {
        return 0;
    }
    int safe = 1;
    for (;;) {
        errno = 0;
        FTSENT *node = fts_read(tree);
        if (node == NULL) {
            if (errno != 0) {
                safe = 0;
            }
            break;
        }
        if (node->fts_info == FTS_SL || node->fts_info == FTS_SLNONE ||
            node->fts_info == FTS_DNR || node->fts_info == FTS_ERR ||
            node->fts_info == FTS_NS) {
            safe = 0;
            break;
        }
        if (node->fts_info == FTS_D) {
            int acl_state = path_has_extended_acl(node->fts_path);
            if (node->fts_statp == NULL ||
                !pcvr_safe_metadata_accepts(node->fts_statp, expected_uid,
                                            S_IFDIR, acl_state)) {
                safe = 0;
                break;
            }
        }
    }
    if (fts_close(tree) != 0) {
        safe = 0;
    }
    if (!safe) {
        errno = EPERM;
    }
    return safe;
}

int pcvr_reviewed_bundle_disk_is_unchanged(
    const pcvr_reviewed_bundle_t *reviewed_bundle) {
    if (reviewed_bundle == NULL || reviewed_bundle->app_root[0] != '/') {
        errno = EINVAL;
        return 0;
    }
    if (pcvr_verify_safe_directory_chain(reviewed_bundle->home_path,
                                         reviewed_bundle->app_root,
                                         reviewed_bundle->macho_stats[0].st_uid) != 0) {
        return 0;
    }
    if (!reviewed_tree_directories_are_safe(
            reviewed_bundle->app_root,
            reviewed_bundle->macho_stats[0].st_uid)) {
        return 0;
    }
    char path[PATH_MAX] = {0};
    for (size_t index = 0; index < PCVR_REVIEWED_MACHO_COUNT; index++) {
        struct stat current = {0};
        if (pcvr_reviewed_macho_absolute_path(reviewed_bundle, index, path) != 0 ||
            lstat(path, &current) != 0 || !S_ISREG(current.st_mode) ||
            !stat_is_unchanged(&reviewed_bundle->macho_stats[index],
                               &current)) {
            errno = EPERM;
            return 0;
        }
    }
    return 1;
}

int pcvr_reviewed_bundle_is_same(const pcvr_reviewed_bundle_t *left,
                                 const pcvr_reviewed_bundle_t *right) {
    if (left == NULL || right == NULL) {
        return 0;
    }
    if (strcmp(left->home_path, right->home_path) != 0 ||
        strcmp(left->app_root, right->app_root) != 0) {
        return 0;
    }
    for (size_t index = 0; index < PCVR_REVIEWED_MACHO_COUNT; index++) {
        if (!stat_is_unchanged(&left->macho_stats[index],
                               &right->macho_stats[index])) {
            return 0;
        }
    }
    return 1;
}
