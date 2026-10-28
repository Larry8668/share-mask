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

typedef int SMConnectionID;
static SMConnectionID (*smMainConn)(void);
static uint64_t (*smActiveSpace)(SMConnectionID);
static CFArrayRef (*smCopySpaces)(SMConnectionID, int, CFArrayRef);

static void SMResolveSpaces(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (!sl) return;
        smMainConn = dlsym(sl, "SLSMainConnectionID");
        smActiveSpace = dlsym(sl, "SLSGetActiveSpace");
        smCopySpaces = dlsym(sl, "SLSCopySpacesForWindows");
    });
}

BOOL SMSpacesAPIAvailable(void) { SMResolveSpaces(); return smMainConn && smActiveSpace && smCopySpaces; }

uint64_t SMActiveSpace(void) { return SMSpacesAPIAvailable() ? smActiveSpace(smMainConn()) : 0; }

NSArray<NSNumber *> *SMSpacesForWindow(uint32_t windowID) {
    if (!SMSpacesAPIAvailable()) return @[];
    NSArray *ids = @[@(windowID)];
    CFArrayRef r = smCopySpaces(smMainConn(), 7 /* all space types */, (__bridge CFArrayRef)ids);
    return r ? (__bridge_transfer NSArray *)r : @[];
}
