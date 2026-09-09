// SPDX-License-Identifier: GPL-3.0-or-later
#include "TagentraPM3Core.h"

#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#include "pm3.h"
#include "fileutils.h"

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

static void tagentra_set_error(const char *message);

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
           TAGENTRA_PM3_CAP_STORAGE_ROOT;
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
