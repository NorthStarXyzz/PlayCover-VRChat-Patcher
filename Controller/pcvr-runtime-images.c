#include "pcvr-runtime-images.h"

#include <errno.h>
#include <libproc.h>
#include <mach/vm_prot.h>
#include <stdio.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <time.h>

static int prefix_matches(const char *path, const char *prefix) {
    size_t length = strlen(prefix);
    return strncmp(path, prefix, length) == 0;
}

static int is_trusted_system_image(
    const pcvr_mapped_image_region_t *region) {
    if (region->uid != 0 || (region->mode & S_IFMT) != S_IFREG ||
        (region->mode & 0022) != 0) {
        return 0;
    }
    const char *path = region->path;
    return prefix_matches(path, "/System/") ||
           prefix_matches(path, "/usr/lib/") ||
           prefix_matches(path, "/Library/Apple/System/") ||
           prefix_matches(path, "/private/preboot/Cryptexes/OS/") ||
           prefix_matches(path, "/private/var/db/Cryptexes/OS/") ||
           prefix_matches(path,
                          "/System/Volumes/Preboot/Cryptexes/OS/");
}

static int mapped_metadata_matches(const pcvr_mapped_image_region_t *region,
                                   const struct stat *expected) {
    return region->device == (uint64_t)(uint32_t)expected->st_dev &&
           region->inode == expected->st_ino &&
           region->size == (uint64_t)expected->st_size &&
           region->uid == expected->st_uid &&
           region->mode == expected->st_mode &&
           region->flags == expected->st_flags &&
           region->modification_seconds == expected->st_mtimespec.tv_sec &&
           region->modification_nanoseconds == expected->st_mtimespec.tv_nsec &&
           region->change_seconds == expected->st_ctimespec.tv_sec &&
           region->change_nanoseconds == expected->st_ctimespec.tv_nsec;
}

static int reject_region(pcvr_runtime_image_evaluator_t *evaluator,
                         const pcvr_mapped_image_region_t *region,
                         const char *reason,
                         int error_number) {
    if (!evaluator->rejected) {
        (void)snprintf(evaluator->rejection_reason,
                       sizeof(evaluator->rejection_reason), "%s", reason);
        (void)snprintf(evaluator->rejection_path,
                       sizeof(evaluator->rejection_path), "%s",
                       region != NULL ? region->path : "");
    }
    evaluator->rejected = 1;
    errno = error_number;
    return -1;
}

void pcvr_runtime_image_evaluator_init(
    pcvr_runtime_image_evaluator_t *evaluator,
    const pcvr_reviewed_bundle_t *reviewed_bundle) {
    memset(evaluator, 0, sizeof(*evaluator));
    evaluator->reviewed_bundle = reviewed_bundle;
}

int pcvr_runtime_image_evaluator_accept(
    pcvr_runtime_image_evaluator_t *evaluator,
    const pcvr_mapped_image_region_t *region) {
    if (evaluator == NULL || evaluator->reviewed_bundle == NULL ||
        region == NULL || evaluator->rejected) {
        errno = EINVAL;
        return -1;
    }
    if ((region->protection & VM_PROT_EXECUTE) == 0) {
        return 0;
    }
    if (region->path[0] == '\0') {
        if (region->device != 0 || region->inode != 0) {
            return reject_region(evaluator, region,
                                 "pathless_file_backed", EPERM);
        }
        return 0;
    }

    size_t index = 0;
    int lookup = pcvr_reviewed_macho_index_for_absolute_path(
        evaluator->reviewed_bundle, region->path, &index);
    if (lookup < 0) {
        return reject_region(evaluator, region,
                             "allowlist_lookup", errno == 0 ? EINVAL : errno);
    }
    if (lookup == 1) {
        const struct stat *expected = pcvr_reviewed_macho_stat(
            evaluator->reviewed_bundle, index);
        if (expected == NULL || !mapped_metadata_matches(region, expected)) {
            return reject_region(evaluator, region,
                                 "reviewed_metadata_mismatch", EPERM);
        }
        evaluator->seen[index] = 1;
        return 0;
    }
    if (is_trusted_system_image(region)) {
        return 0;
    }

    return reject_region(evaluator, region, "unreviewed_executable", EPERM);
}

static int required_index(const char *relative_path, size_t *index) {
    for (size_t candidate = 0; candidate < pcvr_reviewed_macho_count();
         candidate++) {
        const pcvr_reviewed_macho_entry_t *entry =
            pcvr_reviewed_macho_entry(candidate);
        if (entry != NULL && strcmp(entry->relative_path, relative_path) == 0) {
            *index = candidate;
            return 0;
        }
    }
    errno = EINVAL;
    return -1;
}

int pcvr_runtime_image_evaluator_finish(
    const pcvr_runtime_image_evaluator_t *evaluator,
    int require_core_images) {
    if (evaluator == NULL || evaluator->reviewed_bundle == NULL ||
        evaluator->rejected) {
        errno = EPERM;
        return -1;
    }
    if (!require_core_images) {
        return 0;
    }
    const char *required[] = {
        "VRChat",
        "Frameworks/UnityFramework.framework/UnityFramework",
        "Frameworks/libloader.framework/libloader"
    };
    for (size_t item = 0; item < sizeof(required) / sizeof(required[0]); item++) {
        size_t index = 0;
        if (required_index(required[item], &index) != 0 ||
            !evaluator->seen[index]) {
            errno = ENOENT;
            return -1;
        }
    }
    return 0;
}

int pcvr_runtime_enumerate_regions(pid_t pid,
                                   pcvr_runtime_region_visitor_t visitor,
                                   void *context) {
    if (pid <= 0 || visitor == NULL) {
        errno = EINVAL;
        return -1;
    }
    uint64_t address = 0;
    size_t count = 0;
    enum { maximum_regions = 262144 };
    while (count < maximum_regions) {
        struct proc_regionwithpathinfo info = {0};
        errno = 0;
        int amount = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address,
                                  &info, (int)sizeof(info));
        if (amount == 0 && count > 0 &&
            (errno == 0 || errno == EINVAL || errno == ENOENT)) {
            return 0;
        }
        if (amount != (int)sizeof(info)) {
            if (errno == 0) {
                errno = EIO;
            }
            return -1;
        }
        const struct proc_regioninfo *source = &info.prp_prinfo;
        if (source->pri_size == 0 ||
            source->pri_address > UINT64_MAX - source->pri_size) {
            errno = EOVERFLOW;
            return -1;
        }
        uint64_t next_address = source->pri_address + source->pri_size;
        if (next_address <= address) {
            return count > 0 ? 0 : -1;
        }
        if (memchr(info.prp_vip.vip_path, '\0',
                   sizeof(info.prp_vip.vip_path)) == NULL) {
            errno = EOVERFLOW;
            return -1;
        }
        const struct vinfo_stat *vnode = &info.prp_vip.vip_vi.vi_stat;
        pcvr_mapped_image_region_t region = {
            .protection = source->pri_protection,
            .device = vnode->vst_dev,
            .inode = vnode->vst_ino,
            .size = (uint64_t)vnode->vst_size,
            .uid = vnode->vst_uid,
            .mode = vnode->vst_mode,
            .flags = vnode->vst_flags,
            .modification_seconds = vnode->vst_mtime,
            .modification_nanoseconds = vnode->vst_mtimensec,
            .change_seconds = vnode->vst_ctime,
            .change_nanoseconds = vnode->vst_ctimensec
        };
        (void)snprintf(region.path, sizeof(region.path), "%s",
                       info.prp_vip.vip_path);
        if (visitor(&region, context) != 0) {
            return -1;
        }
        address = next_address;
        count++;
    }
    errno = EOVERFLOW;
    return -1;
}

static int evaluate_region(const pcvr_mapped_image_region_t *region,
                           void *context) {
    return pcvr_runtime_image_evaluator_accept(context, region);
}

static int verify_runtime_images_once(
    pid_t pid, const pcvr_reviewed_bundle_t *reviewed_bundle,
    int require_core_images, int emit_diagnostics) {
    if (reviewed_bundle == NULL ||
        pcvr_reviewed_bundle_disk_is_unchanged(reviewed_bundle) != 1) {
        if (emit_diagnostics) {
            fprintf(stderr,
                    "Runtime image validation failed before enumeration: "
                    "reviewed bundle changed.\n");
        }
        errno = EPERM;
        return -1;
    }
    pcvr_runtime_image_evaluator_t evaluator;
    pcvr_runtime_image_evaluator_init(&evaluator, reviewed_bundle);
    int enumeration_result =
        pcvr_runtime_enumerate_regions(pid, evaluate_region, &evaluator);
    int finish_result = enumeration_result == 0
        ? pcvr_runtime_image_evaluator_finish(&evaluator, require_core_images)
        : -1;
    int disk_result = finish_result == 0
        ? pcvr_reviewed_bundle_disk_is_unchanged(reviewed_bundle)
        : -1;
    if (enumeration_result != 0 || finish_result != 0 || disk_result != 1) {
        if (emit_diagnostics && evaluator.rejected) {
            fprintf(stderr,
                    "Runtime executable image rejected: reason=%s path=%s "
                    "errno=%d (%s).\n",
                    evaluator.rejection_reason[0] != '\0'
                        ? evaluator.rejection_reason : "unknown",
                    evaluator.rejection_path,
                    errno,
                    strerror(errno));
        } else if (emit_diagnostics && enumeration_result != 0) {
            fprintf(stderr,
                    "Runtime image enumeration failed: errno=%d (%s).\n",
                    errno, strerror(errno));
        } else if (emit_diagnostics && finish_result != 0) {
            const char *required[] = {
                "VRChat",
                "Frameworks/UnityFramework.framework/UnityFramework",
                "Frameworks/libloader.framework/libloader"
            };
            const char *missing = "unknown";
            for (size_t item = 0;
                 item < sizeof(required) / sizeof(required[0]); item++) {
                size_t index = 0;
                if (required_index(required[item], &index) != 0 ||
                    !evaluator.seen[index]) {
                    missing = required[item];
                    break;
                }
            }
            fprintf(stderr,
                    "Runtime image set is missing a required core image: %s.\n",
                    missing);
        } else if (emit_diagnostics) {
            fprintf(stderr,
                    "Reviewed bundle changed after runtime image enumeration.\n");
        }
        if (errno == 0) {
            errno = EPERM;
        }
        return -1;
    }
    return 0;
}

int pcvr_verify_runtime_images(pid_t pid,
                               const pcvr_reviewed_bundle_t *reviewed_bundle,
                               int require_core_images) {
    return verify_runtime_images_once(pid, reviewed_bundle,
                                      require_core_images, 1);
}

int pcvr_verify_runtime_images_until_ready(
    pid_t pid, const pcvr_reviewed_bundle_t *reviewed_bundle,
    int require_core_images, unsigned int settle_milliseconds) {
    const unsigned int interval_milliseconds = 10U;
    unsigned int elapsed_milliseconds = 0U;
    for (;;) {
        int result = verify_runtime_images_once(
            pid, reviewed_bundle, require_core_images, 0);
        if (result == 0) {
            return 0;
        }
        int saved_error = errno;
        if (saved_error != ENOENT ||
            elapsed_milliseconds >= settle_milliseconds) {
            int final_result = verify_runtime_images_once(
                pid, reviewed_bundle, require_core_images, 1);
            if (final_result == 0) {
                return 0;
            }
            errno = saved_error;
            return -1;
        }
        struct timespec delay = {
            .tv_sec = 0,
            .tv_nsec = (long)interval_milliseconds * 1000000L
        };
        while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {
        }
        elapsed_milliseconds += interval_milliseconds;
    }
}
