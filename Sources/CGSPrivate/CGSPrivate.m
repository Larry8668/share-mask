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
static CFArrayRef (*smCopyDisplaySpaces)(SMConnectionID);

static void SMResolveSpaces(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (!sl) return;
        smMainConn = dlsym(sl, "SLSMainConnectionID");
        smActiveSpace = dlsym(sl, "SLSGetActiveSpace");
        smCopySpaces = dlsym(sl, "SLSCopySpacesForWindows");
        smCopyDisplaySpaces = dlsym(sl, "SLSCopyManagedDisplaySpaces");
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

NSArray<NSNumber *> *SMCurrentSpaces(void) {
    if (!SMSpacesAPIAvailable()) return @[];
    NSMutableArray *out = [NSMutableArray array];
    if (smCopyDisplaySpaces) {
        NSArray *displays = (__bridge_transfer NSArray *)smCopyDisplaySpaces(smMainConn());
        for (NSDictionary *d in displays) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *cur = d[@"Current Space"];
            id sid = [cur isKindOfClass:[NSDictionary class]] ? (cur[@"ManagedSpaceID"] ?: cur[@"id64"]) : nil;
            if ([sid isKindOfClass:[NSNumber class]]) [out addObject:sid];
        }
    }
    uint64_t active = smActiveSpace(smMainConn());
    if (active != 0 && ![out containsObject:@(active)]) [out addObject:@(active)];
    return out;
}
