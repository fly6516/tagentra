// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef TAGENTRA_PM3_CORE_H
#define TAGENTRA_PM3_CORE_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#if defined(__GNUC__)
#define TAGENTRA_PM3_EXPORT __attribute__((visibility("default")))
#else
#define TAGENTRA_PM3_EXPORT
#endif

#define TAGENTRA_PM3_ABI_MAJOR 2u
#define TAGENTRA_PM3_ABI_MINOR 2u
#define TAGENTRA_PM3_ABI_VERSION ((TAGENTRA_PM3_ABI_MAJOR << 16u) | TAGENTRA_PM3_ABI_MINOR)

enum tagentra_pm3_capability {
    TAGENTRA_PM3_CAP_TCP_ENDPOINT = 1ull << 0,
    TAGENTRA_PM3_CAP_RESOURCE_ROOT = 1ull << 1,
    TAGENTRA_PM3_CAP_STREAMING_OUTPUT = 1ull << 2,
    TAGENTRA_PM3_CAP_COOPERATIVE_CANCEL = 1ull << 3,
    TAGENTRA_PM3_CAP_STORAGE_ROOT = 1ull << 4,
    TAGENTRA_PM3_CAP_MFKEY32V2 = 1ull << 5,
    TAGENTRA_PM3_CAP_FM11_STATICNESTED = 1ull << 6
};

typedef void (*tagentra_pm3_output_callback)(const char *utf8,
                                             size_t length,
                                             void *context);

enum tagentra_pm3_status {
    TAGENTRA_PM3_OK = 0,
    TAGENTRA_PM3_ERROR = -1,
    TAGENTRA_PM3_INVALID_ARGUMENT = -2,
    TAGENTRA_PM3_NOT_INITIALIZED = -3,
    TAGENTRA_PM3_CANCELLED = -4,
    TAGENTRA_PM3_ALREADY_INITIALIZED = -5,
    TAGENTRA_PM3_BUSY = -6,
    TAGENTRA_PM3_CONNECTION_FAILED = -7
};

TAGENTRA_PM3_EXPORT uint32_t tagentra_pm3_abi_version(void);
TAGENTRA_PM3_EXPORT uint32_t tagentra_pm3_abi_major(void);
TAGENTRA_PM3_EXPORT uint32_t tagentra_pm3_abi_minor(void);
TAGENTRA_PM3_EXPORT uint64_t tagentra_pm3_capabilities(void);
TAGENTRA_PM3_EXPORT const char *tagentra_pm3_upstream_revision(void);
TAGENTRA_PM3_EXPORT int tagentra_pm3_initialize(void);
TAGENTRA_PM3_EXPORT int tagentra_pm3_initialize_endpoint(const char *endpoint);
TAGENTRA_PM3_EXPORT int tagentra_pm3_set_resource_root(const char *absolute_path);
TAGENTRA_PM3_EXPORT int tagentra_pm3_set_storage_root(const char *absolute_path);
TAGENTRA_PM3_EXPORT const char *tagentra_pm3_storage_root(void);
TAGENTRA_PM3_EXPORT void tagentra_pm3_set_output_callback(
    tagentra_pm3_output_callback callback,
    void *context);
TAGENTRA_PM3_EXPORT int tagentra_pm3_execute(const char *command);
TAGENTRA_PM3_EXPORT int tagentra_pm3_cancel(void);
TAGENTRA_PM3_EXPORT void tagentra_pm3_shutdown(void);
TAGENTRA_PM3_EXPORT const char *tagentra_pm3_last_error(void);

/* Offline Crypto1 recovery. Returns OK only when a key was found. */
TAGENTRA_PM3_EXPORT int tagentra_pm3_mfkey32v2(
    uint32_t uid, uint32_t nt0, uint32_t nr0_enc, uint32_t ar0_enc,
    uint32_t nt1, uint32_t nr1_enc, uint32_t ar1_enc, uint64_t *key);

/* FM11RF08S stages produce keys_<uid>_<sector>_<nt>.dic in storage_root.
 * Only use authenticated, device-collected nonce/parity data. The results
 * are candidates: verify each key with hf mf fchk before making a dump. */
TAGENTRA_PM3_EXPORT int tagentra_pm3_fm11_candidates(
    uint32_t uid, unsigned sector, uint32_t nt, uint32_t nt_enc,
    const char *parity_errors);
TAGENTRA_PM3_EXPORT int tagentra_pm3_fm11_filter_pair(
    uint32_t uid, unsigned sector, uint32_t nt_a, uint32_t nt_b);
/* Also writes keys_<uid>_<sector>_<target_nt>_matches.dic. */
TAGENTRA_PM3_EXPORT int tagentra_pm3_fm11_filter_known_key(
    uint32_t uid, unsigned sector, uint32_t known_nt, uint64_t known_key,
    uint32_t target_nt, int filtered, uint64_t *first_match,
    uint32_t *match_count);

/* Called only by the checked RRG log overlay. Not application API. */
TAGENTRA_PM3_EXPORT void tagentra_pm3_forward_output(const char *utf8,
                                                     size_t length);

#if defined(__cplusplus)
}
#endif

#endif
