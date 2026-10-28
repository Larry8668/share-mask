// Private CoreGraphics Services / SkyLight calls, resolved with dlsym at runtime so a missing
// symbol degrades to "unknown" instead of a link failure.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES if `CGSIsScreenWatcherPresent` (re-exported from SkyLight's SLSIsScreenWatcherPresent)
/// resolved. Call before trusting SMScreenWatcherPresent().
BOOL SMScreenWatcherAPIAvailable(void);

/// Whether any process currently has a screen-capture ("screen watcher") session open.
/// Note: sharemask's own ScreenCaptureKit stream counts, so this is only meaningful while our
/// capture is stopped. Returns NO when the API is unavailable.
BOOL SMScreenWatcherPresent(void);

/// Spaces ("desktops") API, read-only. YES if the needed SkyLight symbols resolved.
BOOL SMSpacesAPIAvailable(void);
/// The active Space id (0 if unavailable).
uint64_t SMActiveSpace(void);
/// Space ids a window belongs to (empty if none / unavailable).
NSArray<NSNumber *> *SMSpacesForWindow(uint32_t windowID);

NS_ASSUME_NONNULL_END
