#import "CGSPrivate.h"
#import <dlfcn.h>

typedef bool (*SMBoolFn)(void);

static SMBoolFn SMResolveWatcher(void) {
    static SMBoolFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (SMBoolFn)dlsym(RTLD_DEFAULT, "CGSIsScreenWatcherPresent");
        if (!fn) {
            void *skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
            if (skylight) fn = (SMBoolFn)dlsym(skylight, "SLSIsScreenWatcherPresent");
        }
    });
    return fn;
}

BOOL SMScreenWatcherAPIAvailable(void) { return SMResolveWatcher() != NULL; }

BOOL SMScreenWatcherPresent(void) {
    SMBoolFn fn = SMResolveWatcher();
    return fn ? (BOOL)fn() : NO;
}
