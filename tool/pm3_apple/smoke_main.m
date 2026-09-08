// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "TagentraPM3Core.h"

#ifndef EXPECTED_REVISION
#define EXPECTED_REVISION ""
#endif

static size_t output_bytes;

static void receive_output(const char *utf8, size_t length, void *context) {
    (void)utf8;
    (void)context;
    output_bytes += length;
}

static int fail(const char *message) {
    fprintf(stderr, "TAGENTRA_PM3_SMOKE_FAILED: %s\n", message);
    return 1;
}

static int run_smoke(void) {
    @autoreleasepool {
        if (tagentra_pm3_abi_version() != TAGENTRA_PM3_ABI_VERSION) return fail("ABI version");
        if (tagentra_pm3_abi_major() != 2 || tagentra_pm3_abi_minor() != 0) return fail("ABI components");
        if ((tagentra_pm3_capabilities() & TAGENTRA_PM3_CAP_TCP_ENDPOINT) == 0) return fail("capabilities");
        if (tagentra_pm3_initialize_endpoint("serial:invalid") != TAGENTRA_PM3_INVALID_ARGUMENT) return fail("endpoint validation");
        if (tagentra_pm3_last_error()[0] == '\0') return fail("last error");
        const char *revision = tagentra_pm3_upstream_revision();
        if (revision == NULL || revision[0] == '\0') return fail("upstream revision");
        if (EXPECTED_REVISION[0] != '\0' && strcmp(revision, EXPECTED_REVISION) != 0) return fail("revision mismatch");
        if (tagentra_pm3_initialize() != TAGENTRA_PM3_OK) return fail("initialize");
        tagentra_pm3_set_output_callback(receive_output, NULL);
        if (tagentra_pm3_execute("help") != TAGENTRA_PM3_OK) return fail("help command");
        if (output_bytes == 0) return fail("help output callback");
        if (tagentra_pm3_execute("") != TAGENTRA_PM3_INVALID_ARGUMENT) return fail("invalid command");
        if (tagentra_pm3_cancel() != TAGENTRA_PM3_OK) return fail("cancel request");
        if (tagentra_pm3_execute("help") != TAGENTRA_PM3_CANCELLED) return fail("cancel consumption");
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
