// SPDX-License-Identifier: GPL-3.0-or-later
#include "TagentraPM3Core.h"

#include <stdbool.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#include "pm3.h"
#include "fileutils.h"
#include "crapto1/crapto1.h"

#ifndef TAGENTRA_PM3_REVISION
#define TAGENTRA_PM3_REVISION "unknown"
#endif

static pm3 *tagentra_device;
static atomic_bool tagentra_initialized;
static tagentra_pm3_output_callback tagentra_output_callback;
static void *tagentra_output_context;
static atomic_bool tagentra_cancel_requested;
static pthread_mutex_t tagentra_lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t tagentra_execution_lock = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local char tagentra_error[512];
static char *tagentra_resource_root;
static char *tagentra_storage_root;
static _Thread_local uint64_t tagentra_fm11_first_match;
static _Thread_local uint32_t tagentra_fm11_match_count;
static _Thread_local FILE *tagentra_fm11_match_file;

void tagentra_pm3_fm11_match_internal(uint64_t key) {
    if (tagentra_fm11_match_count++ == 0) tagentra_fm11_first_match = key;
    if (tagentra_fm11_match_file != NULL)
        fprintf(tagentra_fm11_match_file, "%012" PRIx64 "\n", key);
}

static void tagentra_set_error(const char *message);
static int tagentra_apply_storage_root(void);

const char *tagentra_pm3_resource_root_internal(void) {
    return tagentra_resource_root;
}

const char *tagentra_pm3_storage_root(void) {
    return tagentra_storage_root;
}

static bool tagentra_directory_is_writable(const char *path) {
    struct stat details;
    return stat(path, &details) == 0 && S_ISDIR(details.st_mode) &&
           access(path, W_OK) == 0;
}

static int tagentra_set_root(char **target, const char *absolute_path,
                             bool require_writable, bool trailing_slash) {
    if (absolute_path == NULL || absolute_path[0] != '/') {
        tagentra_set_error("root must be an absolute path");
        return TAGENTRA_PM3_INVALID_ARGUMENT;
    }
    if (require_writable && !tagentra_directory_is_writable(absolute_path)) {
        tagentra_set_error("storage root must exist and be writable");
        return TAGENTRA_PM3_INVALID_ARGUMENT;
    }
    const size_t length = strlen(absolute_path);
    if (length == 0) {
        tagentra_set_error("root must not be empty");
        return TAGENTRA_PM3_INVALID_ARGUMENT;
    }
    char *copy = malloc(length + 2);
    if (copy == NULL) {
        tagentra_set_error("root allocation failed");
        return TAGENTRA_PM3_ERROR;
    }
    memcpy(copy, absolute_path, length);
    if (trailing_slash && absolute_path[length - 1] != '/') {
        copy[length] = '/';
        copy[length + 1] = '\0';
    } else if (!trailing_slash && length > 1 && absolute_path[length - 1] == '/') {
        copy[length - 1] = '\0';
    } else {
        copy[length] = '\0';
    }
    free(*target);
    *target = copy;
    tagentra_set_error("");
    return TAGENTRA_PM3_OK;
}

static int tagentra_apply_storage_root(void) {
    if (tagentra_storage_root == NULL) {
        tagentra_set_error("storage root must be configured before initialization");
        return TAGENTRA_PM3_INVALID_ARGUMENT;
    }
    if (!tagentra_directory_is_writable(tagentra_storage_root)) {
        tagentra_set_error("storage root is no longer writable");
        return TAGENTRA_PM3_ERROR;
    }
    if (chdir(tagentra_storage_root) != 0) {
        tagentra_set_error("could not change to storage root");
        return TAGENTRA_PM3_ERROR;
    }
    setDefaultPath(spDefault, tagentra_storage_root);
    setDefaultPath(spDump, tagentra_storage_root);
    setDefaultPath(spTrace, tagentra_storage_root);
    return TAGENTRA_PM3_OK;
}

static void tagentra_set_error(const char *message) {
    snprintf(tagentra_error, sizeof(tagentra_error), "%s",
             message == NULL ? "" : message);
}

uint32_t tagentra_pm3_abi_version(void) {
    return TAGENTRA_PM3_ABI_VERSION;
}

uint32_t tagentra_pm3_abi_major(void) { return TAGENTRA_PM3_ABI_MAJOR; }
uint32_t tagentra_pm3_abi_minor(void) { return TAGENTRA_PM3_ABI_MINOR; }
uint64_t tagentra_pm3_capabilities(void) {
    return TAGENTRA_PM3_CAP_TCP_ENDPOINT | TAGENTRA_PM3_CAP_RESOURCE_ROOT |
           TAGENTRA_PM3_CAP_STREAMING_OUTPUT | TAGENTRA_PM3_CAP_COOPERATIVE_CANCEL |
           TAGENTRA_PM3_CAP_STORAGE_ROOT | TAGENTRA_PM3_CAP_MFKEY32V2 |
           TAGENTRA_PM3_CAP_FM11_STATICNESTED;
}

int tagentra_pm3_mfkey32v2(uint32_t uid, uint32_t nt0, uint32_t nr0_enc,
                            uint32_t ar0_enc, uint32_t nt1, uint32_t nr1_enc,
                            uint32_t ar1_enc, uint64_t *key) {
    if (key == NULL) return TAGENTRA_PM3_INVALID_ARGUMENT;
    *key = 0;
    const uint32_t ks0 = ar0_enc ^ prng_successor(nt0, 64);
    const uint32_t ks1 = ar1_enc ^ prng_successor(nt1, 64);
    struct Crypto1State *states = lfsr_recovery32(ks0, 0);
    if (states == NULL) return TAGENTRA_PM3_ERROR;
    int result = TAGENTRA_PM3_ERROR;
    for (struct Crypto1State *state = states; state->odd | state->even; ++state) {
        lfsr_rollback_word(state, 0, 0);
        lfsr_rollback_word(state, nr0_enc, 1);
        lfsr_rollback_word(state, uid ^ nt0, 0);
        uint64_t candidate;
        crypto1_get_lfsr(state, &candidate);
        crypto1_word(state, uid ^ nt1, 0);
        crypto1_word(state, nr1_enc, 1);
        if (ks1 == crypto1_word(state, 0, 0)) {
            *key = candidate;
            result = TAGENTRA_PM3_OK;
            break;
        }
    }
    free(states);
    return result;
}

int tagentra_fm11_staticnested_1nt(int argc, char *const argv[]);
int tagentra_fm11_staticnested_pair(int argc, char *const argv[]);
int tagentra_fm11_staticnested_known(int argc, char *const argv[]);

static int tagentra_run_fm11(int (*entry)(int, char *const []),
                             int argc, char *const argv[],
                             const char *required_a, const char *required_b,
                             const char *output_a, const char *output_b) {
    if (!atomic_load(&tagentra_initialized)) return TAGENTRA_PM3_NOT_INITIALIZED;
    if (pthread_mutex_trylock(&tagentra_execution_lock) != 0) return TAGENTRA_PM3_BUSY;
    int result = tagentra_apply_storage_root();
    if (result == TAGENTRA_PM3_OK &&
        ((required_a != NULL && access(required_a, R_OK) != 0) ||
         (required_b != NULL && access(required_b, R_OK) != 0)))
        result = TAGENTRA_PM3_INVALID_ARGUMENT;
    if (result == TAGENTRA_PM3_OK && entry == tagentra_fm11_staticnested_known) {
        tagentra_fm11_match_file = fopen(output_a, "w");
        if (tagentra_fm11_match_file == NULL) result = TAGENTRA_PM3_ERROR;
    }
    if (result == TAGENTRA_PM3_OK) {
        result = entry(argc, argv) == 0 ? TAGENTRA_PM3_OK : TAGENTRA_PM3_ERROR;
    }
    if (tagentra_fm11_match_file != NULL) {
        const bool write_failed = ferror(tagentra_fm11_match_file) != 0;
        if (fclose(tagentra_fm11_match_file) != 0 || write_failed)
            result = TAGENTRA_PM3_ERROR;
        tagentra_fm11_match_file = NULL;
    }
    if (result == TAGENTRA_PM3_OK &&
        ((output_a != NULL && access(output_a, R_OK) != 0) ||
         (output_b != NULL && access(output_b, R_OK) != 0)))
        result = TAGENTRA_PM3_ERROR;
    pthread_mutex_unlock(&tagentra_execution_lock);
    return result;
}

static bool tagentra_valid_sector(unsigned sector) {
    return sector < 16 || (sector >= 32 && sector < 40);
}

static void tagentra_candidate_name(char *buffer, size_t length,
                                    uint32_t uid, unsigned sector, uint32_t nt,
                                    bool filtered) {
    snprintf(buffer, length, "keys_%08x_%02u_%08x%s.dic", uid, sector, nt,
             filtered ? "_filtered" : "");
}

int tagentra_pm3_fm11_candidates(uint32_t uid, unsigned sector, uint32_t nt,
                                  uint32_t nt_enc, const char *parity_errors) {
    if (!tagentra_valid_sector(sector) || parity_errors == NULL ||
        strlen(parity_errors) != 4 || strspn(parity_errors, "01") != 4)
        return TAGENTRA_PM3_INVALID_ARGUMENT;
    char uid_arg[9], sec_arg[4], nt_arg[9], enc_arg[9];
    snprintf(uid_arg, sizeof(uid_arg), "%08x", uid);
    snprintf(sec_arg, sizeof(sec_arg), "%u", sector);
    snprintf(nt_arg, sizeof(nt_arg), "%08x", nt);
    snprintf(enc_arg, sizeof(enc_arg), "%08x", nt_enc);
    char *argv[] = {"staticnested_1nt", uid_arg, sec_arg, nt_arg,
                    enc_arg, (char *)parity_errors};
    char output[48];
    tagentra_candidate_name(output, sizeof(output), uid, sector, nt, false);
    return tagentra_run_fm11(tagentra_fm11_staticnested_1nt, 6, argv,
                            NULL, NULL, output, NULL);
}

int tagentra_pm3_fm11_filter_pair(uint32_t uid, unsigned sector,
                                  uint32_t nt_a, uint32_t nt_b) {
    if (!tagentra_valid_sector(sector) || nt_a == nt_b)
        return TAGENTRA_PM3_INVALID_ARGUMENT;
    char first[48], second[48];
    char filtered_a[48], filtered_b[48];
    tagentra_candidate_name(first, sizeof(first), uid, sector, nt_a, false);
    tagentra_candidate_name(second, sizeof(second), uid, sector, nt_b, false);
    tagentra_candidate_name(filtered_a, sizeof(filtered_a), uid, sector, nt_a, true);
    tagentra_candidate_name(filtered_b, sizeof(filtered_b), uid, sector, nt_b, true);
    char *argv[] = {"staticnested_2x1nt_rf08s", first, second};
    return tagentra_run_fm11(tagentra_fm11_staticnested_pair, 3, argv,
                            first, second, filtered_a, filtered_b);
}

int tagentra_pm3_fm11_filter_known_key(uint32_t uid, unsigned sector,
                                       uint32_t known_nt, uint64_t known_key,
                                       uint32_t target_nt, int filtered,
                                       uint64_t *first_match, uint32_t *match_count) {
    if (!tagentra_valid_sector(sector) || known_nt == target_nt ||
        known_key > UINT64_C(0xffffffffffff) || (filtered != 0 && filtered != 1) ||
        first_match == NULL || match_count == NULL)
        return TAGENTRA_PM3_INVALID_ARGUMENT;
    *first_match = 0;
    *match_count = 0;
    char nonce[9], key[13], target[48];
    char matches[48];
    snprintf(nonce, sizeof(nonce), "%08x", known_nt);
    snprintf(key, sizeof(key), "%012llx", (unsigned long long)known_key);
    tagentra_candidate_name(target, sizeof(target), uid, sector, target_nt, filtered);
    snprintf(matches, sizeof(matches), "keys_%08x_%02u_%08x_matches.dic",
             uid, sector, target_nt);
    char *argv[] = {"staticnested_2x1nt_rf08s_1key", nonce, key, target};
    tagentra_fm11_first_match = 0;
    tagentra_fm11_match_count = 0;
    int result = tagentra_run_fm11(tagentra_fm11_staticnested_known, 4, argv,
                                  target, NULL, matches, NULL);
    if (result == TAGENTRA_PM3_OK) {
        *first_match = tagentra_fm11_first_match;
        *match_count = tagentra_fm11_match_count;
    }
    return result;
}

const char *tagentra_pm3_upstream_revision(void) {
    return TAGENTRA_PM3_REVISION;
}

int tagentra_pm3_initialize(void) {
    return tagentra_pm3_initialize_endpoint(NULL);
}

int tagentra_pm3_initialize_endpoint(const char *endpoint) {
    pthread_mutex_lock(&tagentra_lifecycle_lock);
    if (atomic_load(&tagentra_initialized)) {
        tagentra_set_error("PM3 core is already initialized");
        pthread_mutex_unlock(&tagentra_lifecycle_lock);
        return TAGENTRA_PM3_ALREADY_INITIALIZED;
    }
    if (endpoint != NULL && strncmp(endpoint, "tcp:", 4) != 0) {
        tagentra_set_error("endpoint must use the tcp: scheme");
        pthread_mutex_unlock(&tagentra_lifecycle_lock);
        return TAGENTRA_PM3_INVALID_ARGUMENT;
    }
    if (tagentra_storage_root == NULL ||
        !tagentra_directory_is_writable(tagentra_storage_root)) {
        tagentra_set_error("storage root must exist and be writable before initialization");
        pthread_mutex_unlock(&tagentra_lifecycle_lock);
        return TAGENTRA_PM3_INVALID_ARGUMENT;
    }
    if (chdir(tagentra_storage_root) != 0) {
        tagentra_set_error("could not change to storage root");
        pthread_mutex_unlock(&tagentra_lifecycle_lock);
        return TAGENTRA_PM3_ERROR;
    }
    tagentra_device = pm3_open(endpoint);
    if (endpoint != NULL && tagentra_device == NULL) {
        tagentra_set_error("RRG could not connect to the endpoint");
        pthread_mutex_unlock(&tagentra_lifecycle_lock);
        return TAGENTRA_PM3_CONNECTION_FAILED;
    }
    if (tagentra_apply_storage_root() != TAGENTRA_PM3_OK) {
        pm3_close(tagentra_device);
        tagentra_device = NULL;
        pthread_mutex_unlock(&tagentra_lifecycle_lock);
        return TAGENTRA_PM3_ERROR;
    }
    atomic_store(&tagentra_initialized, true);
    atomic_store(&tagentra_cancel_requested, false);
    tagentra_set_error("");
    pthread_mutex_unlock(&tagentra_lifecycle_lock);
    return TAGENTRA_PM3_OK;
}

int tagentra_pm3_set_resource_root(const char *absolute_path) {
    pthread_mutex_lock(&tagentra_lifecycle_lock);
    const int result = tagentra_set_root(&tagentra_resource_root, absolute_path, false, true);
    pthread_mutex_unlock(&tagentra_lifecycle_lock);
    return result;
}

int tagentra_pm3_set_storage_root(const char *absolute_path) {
    pthread_mutex_lock(&tagentra_lifecycle_lock);
    if (atomic_load(&tagentra_initialized)) {
        tagentra_set_error("storage root cannot change while PM3 core is running");
        pthread_mutex_unlock(&tagentra_lifecycle_lock);
        return TAGENTRA_PM3_ALREADY_INITIALIZED;
    }
    const int result = tagentra_set_root(&tagentra_storage_root, absolute_path, true, false);
    pthread_mutex_unlock(&tagentra_lifecycle_lock);
    return result;
}

void tagentra_pm3_set_output_callback(tagentra_pm3_output_callback callback,
                                      void *context) {
    tagentra_output_callback = callback;
    tagentra_output_context = context;
}

void tagentra_pm3_forward_output(const char *utf8, size_t length) {
    tagentra_pm3_output_callback callback = tagentra_output_callback;
    if (callback != NULL && utf8 != NULL && length != 0) {
        callback(utf8, length, tagentra_output_context);
    }
}

int tagentra_pm3_execute(const char *command) {
    if (!atomic_load(&tagentra_initialized)) {
        return TAGENTRA_PM3_NOT_INITIALIZED;
    }
    if (command == NULL || command[0] == '\0') {
        return TAGENTRA_PM3_INVALID_ARGUMENT;
    }
    if (pthread_mutex_trylock(&tagentra_execution_lock) != 0) {
        tagentra_set_error("another PM3 command is running");
        return TAGENTRA_PM3_BUSY;
    }
    if (atomic_exchange(&tagentra_cancel_requested, false)) {
        pthread_mutex_unlock(&tagentra_execution_lock);
        return TAGENTRA_PM3_CANCELLED;
    }

    if (tagentra_apply_storage_root() != TAGENTRA_PM3_OK) {
        pthread_mutex_unlock(&tagentra_execution_lock);
        return TAGENTRA_PM3_ERROR;
    }

    const int result = pm3_console(tagentra_device, command, false, true);
    const bool was_cancelled = atomic_exchange(&tagentra_cancel_requested, false);
    pthread_mutex_unlock(&tagentra_execution_lock);
    if (result != 0 && !was_cancelled) tagentra_set_error("RRG command failed");
    return was_cancelled ? TAGENTRA_PM3_CANCELLED : result;
}

// Used by the checked RRG util.c overlay. Long-running commands that poll
// kbd_enter_pressed() observe cancellation without exposing RRG globals.
int tagentra_pm3_should_cancel(void) {
    return atomic_load(&tagentra_cancel_requested) ? 1 : 0;
}

int tagentra_pm3_cancel(void) {
    if (!atomic_load(&tagentra_initialized)) {
        return TAGENTRA_PM3_NOT_INITIALIZED;
    }
    atomic_store(&tagentra_cancel_requested, true);
    return TAGENTRA_PM3_OK;
}

void tagentra_pm3_shutdown(void) {
    pthread_mutex_lock(&tagentra_lifecycle_lock);
    if (!atomic_load(&tagentra_initialized)) {
        pthread_mutex_unlock(&tagentra_lifecycle_lock);
        return;
    }
    atomic_store(&tagentra_cancel_requested, true);
    pthread_mutex_lock(&tagentra_execution_lock);
    pm3_close(tagentra_device);
    tagentra_device = NULL;
    atomic_store(&tagentra_initialized, false);
    atomic_store(&tagentra_cancel_requested, false);
    pthread_mutex_unlock(&tagentra_execution_lock);
    pthread_mutex_unlock(&tagentra_lifecycle_lock);
}

const char *tagentra_pm3_last_error(void) { return tagentra_error; }
