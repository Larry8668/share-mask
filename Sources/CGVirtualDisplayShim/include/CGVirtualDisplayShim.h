// CGVirtualDisplayShim — the ONLY place in sharemask that touches the private CoreGraphics
// virtual-display classes. Declarations below were verified by runtime introspection on
// macOS 27.0.1 (class_copyMethodList / property attributes); integer fields are `unsigned int`
// (encoding 'I'), not NSUInteger. Swift never sends these selectors directly: it goes through the
// SM* façade, which refuses to run unless SMVirtualDisplayAPIAvailable() has confirmed every
// class and selector exists.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: Private class declarations (do not use from Swift)

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (strong, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic) unsigned int rotation;
- (instancetype)init;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (strong, nonatomic) NSString *name;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int serialNumber;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (strong, nonatomic, nullable) dispatch_queue_t queue;
// Never set: go-macos/virtualdisplay measured intermittent crashes at process exit when the block
// runs during teardown. Declared only so availability checks can verify the selector exists.
@property (copy, nonatomic, nullable) void (^terminationHandler)(id display, id reason);
- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic) unsigned int hiDPI;
@property (readonly, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// MARK: Façade used by Swift

/// Owns the CGVirtualDisplay object. The display exists for as long as this object holds it;
/// `-invalidate` releases it and the window server removes the display asynchronously.
@interface SMVirtualDisplayHandle : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic) BOOL isValid;
/// hiDPI value the display reports after applySettings (observed: 2 even when 1 was requested).
@property (readonly, nonatomic) unsigned int reportedHiDPI;
- (void)invalidate;
@end

/// Everything the façade needs: pixel limits, one advertised mode, identity, physical size.
typedef struct SMVirtualDisplaySpec {
    uint32_t maxPixelsWide, maxPixelsHigh;   // descriptor.maxPixelsWide/High
    uint32_t modeWidth, modeHeight;          // the single CGVirtualDisplayMode
    double   refreshHz;
    uint32_t hiDPI;                          // settings.hiDPI (advertises Retina modes)
    double   widthMM, heightMM;              // descriptor.sizeInMillimeters (drives default mode choice)
    uint32_t vendorID, productID, serial;
} SMVirtualDisplaySpec;

/// Verifies with objc_getClass + class_getInstanceMethod that every class/selector above exists.
/// Returns NO and the first missing item (as "Class" or "Class -selector") otherwise.
BOOL SMVirtualDisplayAPIAvailable(NSString * _Nullable * _Nullable missing);

/// Creates the display. Returns nil and an error description on failure. Calls
/// SMVirtualDisplayAPIAvailable() itself and refuses to proceed if anything is missing.
SMVirtualDisplayHandle * _Nullable SMVirtualDisplayCreate(NSString *name,
                                                          SMVirtualDisplaySpec spec,
                                                          NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
