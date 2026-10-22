#import "CGVirtualDisplayShim.h"
#import <objc/runtime.h>

@interface SMVirtualDisplayHandle ()
@property (strong, nonatomic, nullable) CGVirtualDisplay *display;
@property (nonatomic) CGDirectDisplayID displayID;
@property (nonatomic) unsigned int reportedHiDPI;
@end

@implementation SMVirtualDisplayHandle
- (BOOL)isValid { return self.display != nil; }
- (void)invalidate {
    // Releasing the object is what removes the display; the window server does it asynchronously.
    self.display = nil;
}
- (void)dealloc { self.display = nil; }
@end

static BOOL SMCheck(NSString *className, NSArray<NSString *> *selectors, NSString **missing) {
    Class cls = objc_getClass(className.UTF8String);
    if (!cls) { if (missing) *missing = className; return NO; }
    for (NSString *sel in selectors) {
        if (!class_getInstanceMethod(cls, NSSelectorFromString(sel))) {
            if (missing) *missing = [NSString stringWithFormat:@"%@ -%@", className, sel];
            return NO;
        }
    }
    return YES;
}

BOOL SMVirtualDisplayAPIAvailable(NSString **missing) {
    if (missing) *missing = nil;
    return SMCheck(@"CGVirtualDisplayMode",
                   @[@"initWithWidth:height:refreshRate:", @"width", @"height", @"refreshRate"], missing)
        && SMCheck(@"CGVirtualDisplaySettings",
                   @[@"init", @"setModes:", @"modes", @"setHiDPI:", @"hiDPI", @"setRotation:"], missing)
        && SMCheck(@"CGVirtualDisplayDescriptor",
                   @[@"init", @"setName:", @"setVendorID:", @"setProductID:", @"setSerialNum:",
                     @"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setSizeInMillimeters:",
                     @"setRedPrimary:", @"setGreenPrimary:", @"setBluePrimary:", @"setWhitePoint:",
                     @"setQueue:", @"setTerminationHandler:"], missing)
        && SMCheck(@"CGVirtualDisplay",
                   @[@"initWithDescriptor:", @"applySettings:", @"displayID", @"hiDPI", @"modes"], missing);
}

SMVirtualDisplayHandle *SMVirtualDisplayCreate(NSString *name, SMVirtualDisplaySpec spec, NSString **error) {
    if (error) *error = nil;
    NSString *missing = nil;
    if (!SMVirtualDisplayAPIAvailable(&missing)) {
        if (error) *error = [NSString stringWithFormat:@"private virtual display API missing: %@", missing];
        return nil;
    }
    if (spec.maxPixelsWide == 0 || spec.maxPixelsHigh == 0 || spec.modeWidth == 0 || spec.modeHeight == 0) {
        if (error) *error = @"virtual display spec has a zero dimension";
        return nil;
    }

    @autoreleasepool {
        CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
        desc.name = name;
        desc.vendorID = spec.vendorID;
        desc.productID = spec.productID;
        desc.serialNum = spec.serial;
        if (class_getInstanceMethod([desc class], @selector(setSerialNumber:))) {
            desc.serialNumber = spec.serial;   // alias backed by the same displayInfo entry
        }
        desc.maxPixelsWide = spec.maxPixelsWide;
        desc.maxPixelsHigh = spec.maxPixelsHigh;
        desc.sizeInMillimeters = CGSizeMake(spec.widthMM, spec.heightMM);
        // sRGB / Rec.709 primaries and D65 white point.
        desc.redPrimary   = CGPointMake(0.64, 0.33);
        desc.greenPrimary = CGPointMake(0.30, 0.60);
        desc.bluePrimary  = CGPointMake(0.15, 0.06);
        desc.whitePoint   = CGPointMake(0.3127, 0.3290);
        desc.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
        desc.terminationHandler = nil;

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
        if (!display) {
            if (error) *error = @"CGVirtualDisplay initWithDescriptor: returned nil";
            return nil;
        }

        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = spec.hiDPI;
        settings.rotation = 0;
        CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:spec.modeWidth
                                                                           height:spec.modeHeight
                                                                      refreshRate:spec.refreshHz];
        settings.modes = @[mode];
        // Synchronous; measured 77–330 ms on macOS 27.0.1. This is the ONLY settings application
        // this process ever performs on the display (see VirtualDisplay.swift invariant 2).
        if (![display applySettings:settings]) {
            if (error) *error = @"CGVirtualDisplay applySettings: returned NO";
            return nil;
        }

        SMVirtualDisplayHandle *handle = [[SMVirtualDisplayHandle alloc] init];
        handle.display = display;
        handle.displayID = display.displayID;
        handle.reportedHiDPI = display.hiDPI;
        return handle;
    }
}
