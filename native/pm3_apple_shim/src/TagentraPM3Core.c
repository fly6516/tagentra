// SPDX-License-Identifier: GPL-3.0-or-later
#include "TagentraPM3Core.h"

#include <stdbool.h>
#include <stdatomic.h>
#include <string.h>

#include "pm3.h"

#ifndef TAGENTRA_PM3_REVISION
#define TAGENTRA_PM3_REVISION "unknown"
#endif

static pm3 *tagentra_device;
static bool tagentra_initialized;
static tagentra_pm3_output_callback tagentra_output_callback;
static void *tagentra_output_context;
static atomic_bool tagentra_cancel_requested;

uint32_t tagentra_pm3_abi_version(void) {
    return TAGENTRA_PM3_ABI_VERSION;
}

const char *tagentra_pm3_upstream_revision(void) {
    return TAGENTRA_PM3_REVISION;
}

int tagentra_pm3_initialize(void) {
    if (tagentra_initialized) {
        return TAGENTRA_PM3_ALREADY_INITIALIZED;
    }

    tagentra_device = pm3_open(NULL);
    tagentra_initialized = true;
    atomic_store(&tagentra_cancel_requested, false);
    return TAGENTRA_PM3_OK;
}

void tagentra_pm3_set_output_callback(tagentra_pm3_output_callback callback,
                                      void *context) {
    tagentra_output_callback = callback;
    tagentra_output_context = context;
}

int tagentra_pm3_execute(const char *command) {
    if (!tagentra_initialized) {
        return TAGENTRA_PM3_NOT_INITIALIZED;
    }
    if (command == NULL || command[0] == '\0') {
        return TAGENTRA_PM3_INVALID_ARGUMENT;
    }
    if (atomic_exchange(&tagentra_cancel_requested, false)) {
        return TAGENTRA_PM3_CANCELLED;
    }

    const int result = pm3_console(tagentra_device, command, true, true);
    const bool was_cancelled = atomic_exchange(&tagentra_cancel_requested, false);
    const char *output = pm3_grabbed_output_get(tagentra_device);
    if (tagentra_output_callback != NULL && output != NULL && output[0] != '\0') {
        tagentra_output_callback(output, strlen(output), tagentra_output_context);
    }
    return was_cancelled ? TAGENTRA_PM3_CANCELLED : result;
}

// Used by the checked RRG util.c overlay. Long-running commands that poll
// kbd_enter_pressed() observe cancellation without exposing RRG globals.
int tagentra_pm3_should_cancel(void) {
    return atomic_load(&tagentra_cancel_requested) ? 1 : 0;
}

int tagentra_pm3_cancel(void) {
    if (!tagentra_initialized) {
        return TAGENTRA_PM3_NOT_INITIALIZED;
    }
    atomic_store(&tagentra_cancel_requested, true);
    return TAGENTRA_PM3_OK;
}

void tagentra_pm3_shutdown(void) {
    if (!tagentra_initialized) {
        return;
    }
    pm3_close(tagentra_device);
    tagentra_device = NULL;
    tagentra_initialized = false;
    atomic_store(&tagentra_cancel_requested, false);
}
