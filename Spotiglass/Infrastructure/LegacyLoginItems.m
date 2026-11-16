#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>

// Existing user-created login items are not SMAppService registrations. Capture their
// resolved URL before the bundle moves; after the move the old alias may no longer resolve.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
void *WaxCaptureLegacyLoginItems(const char *sourcePath) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    if (!list) return NULL;
    UInt32 seed;
    CFArrayRef items = LSSharedFileListCopySnapshot(list, &seed);
    NSMutableArray *matches = [NSMutableArray new];
    NSString *source = [NSString stringWithUTF8String:sourcePath];
    LSSharedFileListItemRef previous = NULL;
    for (id object in (__bridge NSArray *)items) {
        LSSharedFileListItemRef item = (__bridge LSSharedFileListItemRef)object;
        CFURLRef url = LSSharedFileListItemCopyResolvedURL(item,
            kLSSharedFileListDoNotMountVolumes | kLSSharedFileListNoUserInteraction, NULL);
        if (url && [[(__bridge NSURL *)url path] isEqualToString:source]) {
            CFTypeRef hidden = LSSharedFileListItemCopyProperty(item, kLSSharedFileListLoginItemHidden);
            [matches addObject:@{@"item": object, @"previous": previous ? (__bridge id)previous : [NSNull null], @"source": source, @"hidden": hidden ? (__bridge id)hidden : @NO}];
            if (hidden) CFRelease(hidden);
        }
        if (url) CFRelease(url);
        previous = item;
    }
    if (items) CFRelease(items);
    // Retain the list and item references until the asynchronous relaunch completes.
    return (__bridge_retained void *)@{@"list": (__bridge id)list, @"matches": matches};
}

void WaxFinishLegacyLoginItems(void *snapshot, const char *destinationPath) {
    if (!snapshot) return;
    NSDictionary *state = (__bridge_transfer NSDictionary *)snapshot;
    LSSharedFileListRef list = (__bridge LSSharedFileListRef)state[@"list"];
    if (destinationPath) {
        NSURL *destination = [NSURL fileURLWithPath:[NSString stringWithUTF8String:destinationPath]];
        for (NSDictionary *entry in state[@"matches"]) {
            LSSharedFileListItemRef old = (__bridge LSSharedFileListItemRef)entry[@"item"];
            NSDictionary *properties = @{(__bridge id)kLSSharedFileListLoginItemHidden: entry[@"hidden"]};
            // InsertItemURL deduplicates the same bundle ID and can return the OLD item
            // without changing its alias. Remove that exact item first, then recreate it in
            // the same position. Do not change any other user's login items.
            LSSharedFileListItemRef previous = entry[@"previous"] == [NSNull null]
                ? kLSSharedFileListItemBeforeFirst : (__bridge LSSharedFileListItemRef)entry[@"previous"];
            if (LSSharedFileListItemRemove(list, old) != noErr) continue;
            LSSharedFileListItemRef replacement = LSSharedFileListInsertItemURL(list, previous, NULL, NULL,
                (__bridge CFURLRef)destination, (__bridge CFDictionaryRef)properties, NULL);
            if (replacement) {
                CFRelease(replacement);
            } else {
                NSURL *original = [NSURL fileURLWithPath:entry[@"source"]];
                LSSharedFileListItemRef restored = LSSharedFileListInsertItemURL(list, previous, NULL, NULL,
                    (__bridge CFURLRef)original, (__bridge CFDictionaryRef)properties, NULL);
                if (restored) CFRelease(restored);
                NSLog(@"Wax could not update its existing login item");
            }
        }
    }
    CFRelease(list);
}
#pragma clang diagnostic pop
