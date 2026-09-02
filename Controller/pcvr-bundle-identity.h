#ifndef PCVR_BUNDLE_IDENTITY_H
#define PCVR_BUNDLE_IDENTITY_H

#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>

/* Filesystem safety helpers used to keep the fixed target below the current
 * user's home directory.  These functions deliberately do not parse or hash
 * VRChat binaries, signatures, entitlements, UUIDs, or framework contents. */
int pcvr_safe_metadata_accepts(const struct stat *metadata,
                               uid_t expected_uid, mode_t expected_type,
                               int has_extended_acl);
int pcvr_verify_safe_directory_chain(const char *home_path,
                                     const char *directory_path,
                                     uid_t expected_uid);

#endif
