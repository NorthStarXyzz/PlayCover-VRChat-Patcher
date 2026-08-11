#ifndef PCVR_MEMORY_POLICY_H
#define PCVR_MEMORY_POLICY_H

#include <stdint.h>

enum {
    PCVR_POLICY_MINIMUM_GIB = 4,
    PCVR_POLICY_WARNING_BELOW_GIB = 8,
    PCVR_POLICY_MIB_PER_GIB = 1024
};

typedef enum pcvr_memory_policy_mode {
    PCVR_MEMORY_POLICY_AUTOMATIC = 0,
    PCVR_MEMORY_POLICY_CUSTOM = 1
} pcvr_memory_policy_mode_t;

typedef struct pcvr_memory_policy {
    pcvr_memory_policy_mode_t mode;
    uint32_t selected_gib;
    uint32_t safe_maximum_gib;
    uint32_t limit_mib;
    uint32_t safe_maximum_mib;
    int low_limit_warning;
} pcvr_memory_policy_t;

/* Computes floor(75% of physical memory / 1 GiB) without overflowing the
 * 64-bit byte count. */
int pcvr_policy_safe_maximum_gib(uint64_t physical_memory_bytes,
                                 uint32_t *safe_maximum_gib);

/* Accepts only a canonical, non-zero ASCII decimal integer. */
int pcvr_policy_parse_requested_gib(const char *text,
                                    uint32_t *requested_gib);

/* A NULL request selects the automatic 75% ceiling. A non-NULL request must
 * be an integral GiB value in 4 GiB...safeMaximum. Invalid values fail; this
 * function never clamps or substitutes a different custom value. */
int pcvr_policy_resolve(const char *requested_gib,
                        uint64_t physical_memory_bytes,
                        pcvr_memory_policy_t *policy);

#endif
