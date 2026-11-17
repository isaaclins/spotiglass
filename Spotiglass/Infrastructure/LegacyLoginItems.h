// The app's Objective-C bridging header. The login-item list API is only reachable without
// deprecation warnings from Objective-C (LegacyLoginItems.m), so Swift calls it through here.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Snapshots the login items that point at the bundle at `sourcePath`. Pass the result to
/// `WaxFinishLegacyLoginItems` exactly once.
void *_Nullable WaxCaptureLegacyLoginItems(const char *sourcePath);

/// Re-points the snapshotted login items at `destinationPath` and releases the snapshot.
/// With a NULL `destinationPath` it only releases the snapshot and changes nothing.
void WaxFinishLegacyLoginItems(void *_Nullable snapshot, const char *_Nullable destinationPath);

NS_ASSUME_NONNULL_END
