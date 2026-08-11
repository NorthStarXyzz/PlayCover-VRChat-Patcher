#include "pcvr-memory-policy.h"

#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <string.h>

static const uint64_t bytes_per_gib = UINT64_C(1024) * 1024U * 1024U;

int pcvr_policy_safe_maximum_gib(uint64_t physical_memory_bytes,
                                 uint32_t *safe_maximum_gib) {
    if (safe_maximum_gib == NULL) {
        errno = EINVAL;
        return -1;
    }

    /* floor(3*x/4), written this way so UINT64_MAX is also safe. */
    uint64_t three_quarters =
        (physical_memory_bytes / 4U) * 3U +
        ((physical_memory_bytes % 4U) * 3U) / 4U;
    uint64_t whole_gib = three_quarters / bytes_per_gib;
    const uint64_t maximum_controller_gib =
        (uint64_t)INT32_MAX / PCVR_POLICY_MIB_PER_GIB;
    if (whole_gib > UINT32_MAX || whole_gib > maximum_controller_gib) {
        errno = EOVERFLOW;
        return -1;
    }
    *safe_maximum_gib = (uint32_t)whole_gib;
    return 0;
}

int pcvr_policy_parse_requested_gib(const char *text,
                                    uint32_t *requested_gib) {
    if (text == NULL || requested_gib == NULL || text[0] == '\0' ||
        text[0] == '0') {
        errno = EINVAL;
        return -1;
    }

    uint32_t parsed = 0;
    for (size_t index = 0; text[index] != '\0'; index++) {
        unsigned char character = (unsigned char)text[index];
        if (character < '0' || character > '9') {
            errno = EINVAL;
            return -1;
        }
        uint32_t digit = (uint32_t)(character - '0');
        if (parsed > (UINT32_MAX - digit) / 10U) {
            errno = ERANGE;
            return -1;
        }
        parsed = parsed * 10U + digit;
    }
    *requested_gib = parsed;
    return 0;
}

int pcvr_policy_resolve(const char *requested_gib,
                        uint64_t physical_memory_bytes,
                        pcvr_memory_policy_t *policy) {
    if (policy == NULL) {
        errno = EINVAL;
        return -1;
    }
    memset(policy, 0, sizeof(*policy));

    uint32_t safe_maximum_gib = 0;
    if (pcvr_policy_safe_maximum_gib(physical_memory_bytes,
                                     &safe_maximum_gib) != 0) {
        return -1;
    }
    if (safe_maximum_gib < PCVR_POLICY_MINIMUM_GIB) {
        errno = ERANGE;
        return -1;
    }

    uint32_t selected_gib = safe_maximum_gib;
    pcvr_memory_policy_mode_t mode = PCVR_MEMORY_POLICY_AUTOMATIC;
    if (requested_gib != NULL) {
        if (pcvr_policy_parse_requested_gib(requested_gib,
                                            &selected_gib) != 0) {
            return -1;
        }
        if (selected_gib < PCVR_POLICY_MINIMUM_GIB ||
            selected_gib > safe_maximum_gib) {
            errno = ERANGE;
            return -1;
        }
        mode = PCVR_MEMORY_POLICY_CUSTOM;
    }

    policy->mode = mode;
    policy->selected_gib = selected_gib;
    policy->safe_maximum_gib = safe_maximum_gib;
    policy->limit_mib = selected_gib * PCVR_POLICY_MIB_PER_GIB;
    policy->safe_maximum_mib =
        safe_maximum_gib * PCVR_POLICY_MIB_PER_GIB;
    policy->low_limit_warning =
        selected_gib < PCVR_POLICY_WARNING_BELOW_GIB;
    return 0;
}
