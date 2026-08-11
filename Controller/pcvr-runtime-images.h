#ifndef PCVR_RUNTIME_IMAGES_H
#define PCVR_RUNTIME_IMAGES_H

#include "pcvr-bundle-identity.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct pcvr_mapped_image_region {
    uint32_t protection;
    uint64_t device;
    uint64_t inode;
    uint64_t size;
    uid_t uid;
    mode_t mode;
    uint32_t flags;
    int64_t modification_seconds;
    int64_t modification_nanoseconds;
    int64_t change_seconds;
    int64_t change_nanoseconds;
    char path[PATH_MAX];
} pcvr_mapped_image_region_t;

typedef struct pcvr_runtime_image_evaluator {
    const pcvr_reviewed_bundle_t *reviewed_bundle;
    unsigned char seen[PCVR_REVIEWED_MACHO_COUNT];
    int rejected;
    char rejection_reason[64];
    char rejection_path[PATH_MAX];
} pcvr_runtime_image_evaluator_t;

typedef int (*pcvr_runtime_region_visitor_t)(
    const pcvr_mapped_image_region_t *region, void *context);

void pcvr_runtime_image_evaluator_init(
    pcvr_runtime_image_evaluator_t *evaluator,
    const pcvr_reviewed_bundle_t *reviewed_bundle);
int pcvr_runtime_image_evaluator_accept(
    pcvr_runtime_image_evaluator_t *evaluator,
    const pcvr_mapped_image_region_t *region);
int pcvr_runtime_image_evaluator_finish(
    const pcvr_runtime_image_evaluator_t *evaluator,
    int require_core_images);

/* Public libproc enumeration boundary, separately testable without VRChat. */
int pcvr_runtime_enumerate_regions(pid_t pid,
                                   pcvr_runtime_region_visitor_t visitor,
                                   void *context);

/* Production gate: current reviewed disk metadata, every path-bearing
 * executable VM region, and mandatory main/Unity/libloader mappings must all
 * remain authorized. Reviewed images are bound to their preflight vnode and
 * timestamp identity; unreviewed non-system images and any libproc uncertainty
 * fail closed. */
int pcvr_verify_runtime_images(pid_t pid,
                               const pcvr_reviewed_bundle_t *reviewed_bundle,
                               int require_core_images);

/* Launch-time variant. A newly discovered process may not have mapped its
 * reviewed Unity/libloader images yet. Only the ENOENT/missing-core result is
 * retried for the bounded interval; any unreviewed path, vnode mismatch, or
 * enumeration error remains immediately fail-closed. */
int pcvr_verify_runtime_images_until_ready(
    pid_t pid, const pcvr_reviewed_bundle_t *reviewed_bundle,
    int require_core_images, unsigned int settle_milliseconds);

#endif
