#ifndef PCVR_BUNDLE_IDENTITY_H
#define PCVR_BUNDLE_IDENTITY_H

#include "pcvr-target.h"
#include "pcvr-reviewed-macho-allowlist.h"

#include <CommonCrypto/CommonDigest.h>
#include <stdint.h>
#include <sys/stat.h>

#define PCVR_REVIEWED_MAIN_NORMALIZED_UNSIGNED_SHA256 \
    "cd6749e212d1ffed0e48a85cbd4d803e419eac8634fa1dcd62e25ea153e5bec3"
#define PCVR_REVIEWED_MAIN_NORMALIZED_LOAD_COMMANDS_SHA256 \
    "664266000f81b937260522d25eda5d81bff3f5d460e5e14512f471c8eaec9afb"
#define PCVR_REVIEWED_ENTITLEMENTS_CANONICAL_SHA256 \
    "5897ec7c1e895de492424821a7b5dbe4bea2552345244c20029a4083a4bb01f4"
typedef struct pcvr_macho_identity {
    char full_sha256[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    char normalized_unsigned_sha256[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    char normalized_load_commands_sha256[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    uint8_t executable_uuid[16];
} pcvr_macho_identity_t;

typedef struct pcvr_reviewed_bundle {
    char home_path[PATH_MAX];
    char app_root[PATH_MAX];
    struct stat macho_stats[PCVR_REVIEWED_MACHO_COUNT];
} pcvr_reviewed_bundle_t;

/* Reads a thin arm64 Mach-O through a no-follow descriptor, verifies stable
 * metadata, and computes both full and code-signature-independent identities.
 * The normalized digests zero LC_CODE_SIGNATURE's dataoff/datasize, zero the
 * signature-size-dependent __LINKEDIT vmsize/filesize, and omit the signature
 * blob itself. */
int pcvr_read_macho_identity(const char *path, uid_t expected_uid,
                             int require_executable,
                             pcvr_macho_identity_t *identity,
                             struct stat *stable_stat);

/* Verifies the complete generated nested Mach-O allowlist. Every entry is
 * bound by UUID plus normalized unsigned/load-command SHA-256, so the gate is
 * stable across the expected per-user ad-hoc signature while still rejecting
 * extra, missing, duplicated, fat, symlinked, or otherwise unreviewed code. */
int pcvr_verify_reviewed_bundle(const pcvr_target_t *target,
                                pcvr_reviewed_bundle_t *reviewed_bundle);

int pcvr_reviewed_bundle_is_same(const pcvr_reviewed_bundle_t *left,
                                 const pcvr_reviewed_bundle_t *right);
int pcvr_reviewed_bundle_disk_is_unchanged(
    const pcvr_reviewed_bundle_t *reviewed_bundle);

size_t pcvr_reviewed_macho_count(void);
const pcvr_reviewed_macho_entry_t *pcvr_reviewed_macho_entry(size_t index);
const struct stat *pcvr_reviewed_macho_stat(
    const pcvr_reviewed_bundle_t *reviewed_bundle, size_t index);
int pcvr_reviewed_macho_absolute_path(
    const pcvr_reviewed_bundle_t *reviewed_bundle, size_t index,
    char output[PATH_MAX]);
int pcvr_reviewed_macho_index_for_absolute_path(
    const pcvr_reviewed_bundle_t *reviewed_bundle, const char *absolute_path,
    size_t *index);

/* Pure metadata predicate plus a component-by-component, no-symlink directory
 * chain gate used by production and non-root tests. */
int pcvr_safe_metadata_accepts(const struct stat *metadata,
                               uid_t expected_uid, mode_t expected_type,
                               int has_extended_acl);
int pcvr_verify_safe_directory_chain(const char *home_path,
                                     const char *directory_path,
                                     uid_t expected_uid);

#endif
