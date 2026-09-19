// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "TagentraPM3Core.h"

#ifndef EXPECTED_REVISION
#define EXPECTED_REVISION ""
#endif

static size_t output_bytes;
static char output_text[64 * 1024];

static void receive_output(const char *utf8, size_t length, void *context) {
    (void)utf8;
    (void)context;
    output_bytes += length;
    size_t used = strlen(output_text);
    size_t available = sizeof(output_text) - used - 1;
    if (available > 0) {
        size_t copied = length < available ? length : available;
        memcpy(output_text + used, utf8, copied);
        output_text[used + copied] = '\0';
    }
}

static int fail(const char *message) {
    fprintf(stderr, "TAGENTRA_PM3_SMOKE_FAILED: %s\n", message);
    return 1;
}

static size_t occurrence_count(const char *text, const char *needle) {
    size_t count = 0;
    const size_t needle_length = strlen(needle);
    while ((text = strstr(text, needle)) != NULL) {
        count++;
        text += needle_length;
    }
    return count;
}

static bool same_directory(const char *first, const char *second) {
    struct stat first_details;
    struct stat second_details;
    return stat(first, &first_details) == 0 &&
           stat(second, &second_details) == 0 &&
           first_details.st_dev == second_details.st_dev &&
           first_details.st_ino == second_details.st_ino;
}

static int run_smoke(void) {
    @autoreleasepool {
        if (tagentra_pm3_abi_version() != TAGENTRA_PM3_ABI_VERSION) return fail("ABI version");
        if (tagentra_pm3_abi_major() != 2 || tagentra_pm3_abi_minor() != 2) return fail("ABI components");
        if ((tagentra_pm3_capabilities() & TAGENTRA_PM3_CAP_TCP_ENDPOINT) == 0) return fail("capabilities");
        if ((tagentra_pm3_capabilities() & TAGENTRA_PM3_CAP_STORAGE_ROOT) == 0) return fail("storage capability");
        if ((tagentra_pm3_capabilities() & TAGENTRA_PM3_CAP_MFKEY32V2) == 0 ||
            (tagentra_pm3_capabilities() & TAGENTRA_PM3_CAP_FM11_STATICNESTED) == 0) return fail("recovery capabilities");
        uint64_t recovered_key = 0;
        if (tagentra_pm3_mfkey32v2(0x12345678, 0x1ad8df2b, 0x1d316024,
                                    0x620ef048, 0x30d6cb07, 0xc52077e2,
                                    0x837ac61a, &recovered_key) != TAGENTRA_PM3_OK ||
            recovered_key != 0xa0a1a2a3a4a5ULL) return fail("mfkey32v2 reference vector");
        if (tagentra_pm3_mfkey32v2(0, 0, 0, 0, 0, 0, 0, NULL) !=
            TAGENTRA_PM3_INVALID_ARGUMENT) return fail("mfkey32v2 arguments");
        if (tagentra_pm3_fm11_candidates(0, 0, 0, 0, "1111") !=
            TAGENTRA_PM3_NOT_INITIALIZED) return fail("FM11 initialization guard");
        if (tagentra_pm3_fm11_candidates(0, 16, 0, 0, "1111") !=
            TAGENTRA_PM3_INVALID_ARGUMENT) return fail("FM11 sector validation");
        if (tagentra_pm3_initialize_endpoint("serial:invalid") != TAGENTRA_PM3_INVALID_ARGUMENT) return fail("endpoint validation");
        if (tagentra_pm3_set_storage_root("relative") != TAGENTRA_PM3_INVALID_ARGUMENT) return fail("relative storage root");
        if (tagentra_pm3_set_storage_root("/path/that/does/not/exist") != TAGENTRA_PM3_INVALID_ARGUMENT) return fail("missing storage root");
        if (tagentra_pm3_last_error()[0] == '\0') return fail("last error");
        const char *revision = tagentra_pm3_upstream_revision();
        if (revision == NULL || revision[0] == '\0') return fail("upstream revision");
        if (EXPECTED_REVISION[0] != '\0' && strcmp(revision, EXPECTED_REVISION) != 0) return fail("revision mismatch");
        char storage_template[] = "/tmp/tagentra-pm3-smoke.XXXXXX";
        char *storage = mkdtemp(storage_template);
        if (storage == NULL) return fail("create storage root");
        char read_only[4096];
        snprintf(read_only, sizeof(read_only), "%s/read-only", storage);
        if (mkdir(read_only, 0500) != 0) return fail("create read-only root");
        if (tagentra_pm3_set_storage_root(read_only) != TAGENTRA_PM3_INVALID_ARGUMENT) return fail("read-only storage root");
        if (tagentra_pm3_set_storage_root(storage) != TAGENTRA_PM3_OK) return fail("set storage root");
        if (strcmp(tagentra_pm3_storage_root(), storage) != 0) return fail("get storage root");
        if (tagentra_pm3_initialize() != TAGENTRA_PM3_OK) return fail("initialize");
        if (tagentra_pm3_fm11_candidates(0xa13e4902, 15, 0xd14191b3,
                                         0x2e9e49fc, "1111") != TAGENTRA_PM3_OK)
            return fail("FM11 candidate generation");
        FILE *candidates = fopen("keys_a13e4902_15_d14191b3.dic", "r");
        if (candidates == NULL) return fail("FM11 candidate file");
        char first_candidate[32];
        bool valid_candidate = fgets(first_candidate, sizeof(first_candidate), candidates) != NULL &&
                               strcmp(first_candidate, "26b5f452e6c6\n") == 0;
        fclose(candidates);
        if (!valid_candidate) return fail("FM11 candidate vector");
        uint64_t matching_key = 0;
        uint32_t match_count = 0;
        if (tagentra_pm3_fm11_filter_known_key(0xa13e4902, 15,
                                               0xd14191b4, 0x26b5f452e6c6ULL,
                                               0xd14191b3, 0, &matching_key,
                                               &match_count) != TAGENTRA_PM3_OK ||
            matching_key != 0x26b5f452e6c6ULL || match_count != 4)
            return fail("FM11 known-key reference vector");
        FILE *matches = fopen("keys_a13e4902_15_d14191b3_matches.dic", "r");
        if (matches == NULL) return fail("FM11 matching dictionary");
        unsigned match_lines = 0;
        char match_line[32];
        while (fgets(match_line, sizeof(match_line), matches) != NULL) match_lines++;
        fclose(matches);
        if (match_lines != match_count) return fail("FM11 matching dictionary count");
        if (tagentra_pm3_fm11_filter_pair(0x12345678, 0, 1, 2) !=
            TAGENTRA_PM3_INVALID_ARGUMENT) return fail("FM11 missing dictionaries");
        if (tagentra_pm3_set_storage_root("/tmp") != TAGENTRA_PM3_ALREADY_INITIALIZED) return fail("running storage mutation");
        tagentra_pm3_set_output_callback(receive_output, NULL);
        if (tagentra_pm3_execute("help") != TAGENTRA_PM3_OK) return fail("help command");
        if (output_bytes == 0) return fail("help output callback");
        if (tagentra_pm3_execute("") != TAGENTRA_PM3_INVALID_ARGUMENT) return fail("invalid command");
        if (tagentra_pm3_cancel() != TAGENTRA_PM3_OK) return fail("cancel request");
        if (tagentra_pm3_execute("help") != TAGENTRA_PM3_CANCELLED) return fail("cancel consumption");
        if (tagentra_pm3_execute("prefs set savepaths --dump /tmp") != TAGENTRA_PM3_OK) return fail("mutate save path");
        output_text[0] = '\0';
        if (tagentra_pm3_execute("prefs get savepaths") != TAGENTRA_PM3_OK) return fail("get save paths");
        if (occurrence_count(output_text, storage) < 3) return fail("controlled save paths");
        char cwd[4096];
        if (getcwd(cwd, sizeof(cwd)) == NULL || !same_directory(cwd, storage)) return fail("controlled cwd");
        tagentra_pm3_shutdown();
        if (tagentra_pm3_initialize() != TAGENTRA_PM3_OK) return fail("reinitialize");
        tagentra_pm3_shutdown();
        fprintf(stderr, "TAGENTRA_PM3_SMOKE_OK revision=%s output_bytes=%zu\n", revision, output_bytes);
        return 0;
    }
}

@interface SmokeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation SmokeAppDelegate
- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UIViewController alloc] init];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int result = run_smoke();
        fflush(stdout);
        fflush(stderr);
        exit(result);
    });
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SmokeAppDelegate.class));
    }
}
