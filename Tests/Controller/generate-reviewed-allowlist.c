#include "../../Controller/pcvr-bundle-identity.h"

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fts.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct generated_entry {
    char relative_path[PATH_MAX];
    pcvr_macho_identity_t identity;
} generated_entry_t;

static int compare_entries(const void *left_value, const void *right_value) {
    const generated_entry_t *left = left_value;
    const generated_entry_t *right = right_value;
    return strcmp(left->relative_path, right->relative_path);
}

typedef enum generated_macho_kind {
    GENERATED_NOT_MACHO = 0,
    GENERATED_THIN_64_MACHO = 1,
    GENERATED_UNSUPPORTED_MACHO = 2
} generated_macho_kind_t;

static int classify_macho(const char *path) {
    uint32_t magic = 0;
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return -1;
    }
    size_t amount = fread(&magic, 1, sizeof(magic), file);
    int close_result = fclose(file);
    if (close_result != 0) {
        return -1;
    }
    if (amount != sizeof(magic)) {
        return GENERATED_NOT_MACHO;
    }
    if (magic == MH_MAGIC_64) {
        return GENERATED_THIN_64_MACHO;
    }
    if (magic == MH_MAGIC || magic == MH_CIGAM || magic == MH_CIGAM_64 ||
        magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 ||
        magic == FAT_CIGAM_64) {
        return GENERATED_UNSUPPORTED_MACHO;
    }
    return GENERATED_NOT_MACHO;
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

static void digest_hex(const unsigned char digest[CC_SHA256_DIGEST_LENGTH],
                       char output[CC_SHA256_DIGEST_LENGTH * 2 + 1]) {
    for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        (void)snprintf(output + index * 2U, 3, "%02x", digest[index]);
    }
    output[CC_SHA256_DIGEST_LENGTH * 2] = '\0';
}

static int update_text(CC_SHA256_CTX *context, const char *text) {
    size_t length = strlen(text);
    if (length > UINT32_MAX ||
        CC_SHA256_Update(context, text, (CC_LONG)length) != 1) {
        return -1;
    }
    return 0;
}

static void print_c_string(const char *value) {
    putchar('"');
    for (size_t index = 0; value[index] != '\0'; index++) {
        unsigned char character = (unsigned char)value[index];
        if (character == '\\' || character == '"') {
            putchar('\\');
            putchar((int)character);
        } else if (character >= 0x20U && character <= 0x7eU) {
            putchar((int)character);
        } else {
            printf("\\%03o", (unsigned int)character);
        }
    }
    putchar('"');
}

int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] != '/') {
        fprintf(stderr, "Usage: %s /absolute/reviewed.app\n", argv[0]);
        return 64;
    }
    size_t root_length = strlen(argv[1]);
    while (root_length > 1U && argv[1][root_length - 1U] == '/') {
        root_length--;
    }
    struct stat root_stat = {0};
    if (lstat(argv[1], &root_stat) != 0 || !S_ISDIR(root_stat.st_mode)) {
        perror("reviewed app root");
        return 1;
    }

    char *paths[] = {argv[1], NULL};
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (tree == NULL) {
        perror("fts_open");
        return 1;
    }
    generated_entry_t entries[128] = {0};
    size_t count = 0;
    int traversal_error = 0;
    for (;;) {
        errno = 0;
        FTSENT *node = fts_read(tree);
        if (node == NULL) {
            traversal_error = errno;
            break;
        }
        if (node->fts_info == FTS_SL || node->fts_info == FTS_SLNONE ||
            node->fts_info == FTS_DNR || node->fts_info == FTS_ERR ||
            node->fts_info == FTS_NS) {
            fprintf(stderr, "Unsafe object in reviewed app: %s\n",
                    node->fts_path);
            traversal_error = EPERM;
            break;
        }
        if (node->fts_info == FTS_D) {
            int acl_state = path_has_extended_acl(node->fts_path);
            if (node->fts_statp == NULL ||
                !pcvr_safe_metadata_accepts(node->fts_statp,
                                            root_stat.st_uid, S_IFDIR,
                                            acl_state)) {
                fprintf(stderr, "Unsafe directory metadata: %s\n",
                        node->fts_path);
                traversal_error = EPERM;
                break;
            }
        }
        if (node->fts_info != FTS_F) {
            continue;
        }
        int macho = classify_macho(node->fts_path);
        if (macho < 0) {
            perror(node->fts_path);
            (void)fts_close(tree);
            return 1;
        }
        if (macho == GENERATED_UNSUPPORTED_MACHO) {
            fprintf(stderr, "Reviewed code must be thin arm64 Mach-O: %s\n",
                    node->fts_path);
            (void)fts_close(tree);
            return 1;
        }
        if (macho == GENERATED_NOT_MACHO) {
            continue;
        }
        if (count == sizeof(entries) / sizeof(entries[0]) ||
            strncmp(node->fts_path, argv[1], root_length) != 0 ||
            node->fts_path[root_length] != '/') {
            fprintf(stderr, "Unsafe or excessive reviewed Mach-O set.\n");
            (void)fts_close(tree);
            return 1;
        }
        const char *relative = node->fts_path + root_length + 1U;
        if (strlen(relative) >= sizeof(entries[count].relative_path)) {
            fprintf(stderr, "Reviewed relative path is too long.\n");
            (void)fts_close(tree);
            return 1;
        }
        (void)snprintf(entries[count].relative_path,
                       sizeof(entries[count].relative_path), "%s", relative);
        struct stat stable = {0};
        if (pcvr_read_macho_identity(
                node->fts_path, root_stat.st_uid, 0,
                &entries[count].identity, &stable) != 0) {
            perror(node->fts_path);
            (void)fts_close(tree);
            return 1;
        }
        count++;
    }
    int close_result = fts_close(tree);
    if (traversal_error != 0 || close_result != 0 || count == 0) {
        if (traversal_error != 0) {
            errno = traversal_error;
        } else if (count == 0) {
            errno = ENOENT;
        }
        perror("fts_read");
        return 1;
    }
    qsort(entries, count, sizeof(entries[0]), compare_entries);

    CC_SHA256_CTX context;
    if (CC_SHA256_Init(&context) != 1 ||
        update_text(&context, "PCVR-MACHO-ALLOWLIST/1\n") != 0) {
        return 1;
    }
    for (size_t index = 0; index < count; index++) {
        char uuid[33] = {0};
        for (size_t byte = 0; byte < 16; byte++) {
            (void)snprintf(uuid + byte * 2U, 3, "%02x",
                           entries[index].identity.executable_uuid[byte]);
        }
        char line[PATH_MAX + 256] = {0};
        int amount = snprintf(
            line, sizeof(line), "M %zu %s %s %s %s\n",
            strlen(entries[index].relative_path), entries[index].relative_path,
            uuid, entries[index].identity.normalized_unsigned_sha256,
            entries[index].identity.normalized_load_commands_sha256);
        if (amount < 0 || amount >= (int)sizeof(line) ||
            update_text(&context, line) != 0) {
            return 1;
        }
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    char digest_text[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {0};
    if (CC_SHA256_Final(digest, &context) != 1) {
        return 1;
    }
    digest_hex(digest, digest_text);

    puts("/* Generated from the reviewed VRChat 2026.2.30300 (1365) bundle.");
    puts(" * Canonical framing: PCVR-MACHO-ALLOWLIST/1; sorted UTF-8 paths;");
    puts(" * M <pathBytes> <path> <uuidHex> <unsignedSHA> <loadsSHA>. */");
    puts("#ifndef PCVR_REVIEWED_MACHO_ALLOWLIST_H");
    puts("#define PCVR_REVIEWED_MACHO_ALLOWLIST_H");
    puts("");
    puts("#include <stddef.h>");
    puts("#include <stdint.h>");
    puts("");
    printf("#define PCVR_REVIEWED_MACHO_ALLOWLIST_SHA256 \"%s\"\n",
           digest_text);
    puts("");
    puts("typedef struct pcvr_reviewed_macho_entry {");
    puts("    const char *relative_path;");
    puts("    const char *normalized_unsigned_sha256;");
    puts("    const char *normalized_load_commands_sha256;");
    puts("    uint8_t executable_uuid[16];");
    puts("} pcvr_reviewed_macho_entry_t;");
    puts("");
    puts("static const pcvr_reviewed_macho_entry_t");
    puts("pcvr_reviewed_macho_allowlist[] = {");
    for (size_t index = 0; index < count; index++) {
        printf("    { .relative_path = ");
        print_c_string(entries[index].relative_path);
        printf(",\n      .normalized_unsigned_sha256 = \"%s\",\n",
               entries[index].identity.normalized_unsigned_sha256);
        printf("      .normalized_load_commands_sha256 = \"%s\",\n",
               entries[index].identity.normalized_load_commands_sha256);
        printf("      .executable_uuid = {");
        for (size_t byte = 0; byte < 16; byte++) {
            printf("%s0x%02x", byte == 0 ? "" : ", ",
                   entries[index].identity.executable_uuid[byte]);
        }
        puts("} },");
    }
    puts("};");
    puts("");
    puts("#define PCVR_REVIEWED_MACHO_COUNT \\");
    puts("    (sizeof(pcvr_reviewed_macho_allowlist) / \\");
    puts("     sizeof(pcvr_reviewed_macho_allowlist[0]))");
    puts("");
    puts("#endif");
    return 0;
}
