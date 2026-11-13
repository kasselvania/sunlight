#import <AppKit/AppKit.h>
#import <ColorSync/ColorSync.h>
#import "SLSourceDisplay.h"
#import <poll.h>
#import <unistd.h>

static NSArray<NSNumber *> *Online(void) {
    CGDirectDisplayID ids[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, ids, &count) != kCGErrorSuccess) abort();
    NSMutableArray *result = [NSMutableArray array];
    for (uint32_t i = 0; i < count; i++) [result addObject:@(ids[i])];
    return result;
}
static NSString *UUID(CGDirectDisplayID display) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) return @"";
    NSString *result = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
    CFRelease(uuid); return result;
}
static bool Profile(CFDictionaryRef info, void *context) {
    NSDictionary *entry = (__bridge NSDictionary *)info;
    NSString *name = entry[(__bridge NSString *)kColorSyncDeviceDescription];
    if ([name hasPrefix:@"Sunlight "]) {
        CFUUIDRef uuid = (__bridge CFUUIDRef)entry[(__bridge NSString *)kColorSyncDeviceID];
        if (uuid) [(__bridge NSMutableSet *)context addObject:CFBridgingRelease(CFUUIDCreateString(NULL, uuid))];
    }
    return true;
}
static NSDictionary *Snapshot(void) {
    NSMutableDictionary *screens = [NSMutableDictionary dictionary];
    for (NSNumber *number in Online()) {
        CGDirectDisplayID id = number.unsignedIntValue;
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(id);
        screens[number.stringValue] = @{@"uuid":UUID(id), @"bounds":NSStringFromRect(CGDisplayBounds(id)),
            @"pixels":mode ? @[@(CGDisplayModeGetPixelWidth(mode)), @(CGDisplayModeGetPixelHeight(mode))] : @[],
            @"hz":mode ? @(CGDisplayModeGetRefreshRate(mode)) : @0};
        if (mode) CGDisplayModeRelease(mode);
    }
    NSMutableSet *profiles = [NSMutableSet set];
    ColorSyncIterateDeviceProfiles(Profile, (__bridge void *)profiles);
    NSURL *directory = [NSURL fileURLWithPath:@"/Library/ColorSync/Profiles/Displays" isDirectory:YES];
    NSMutableArray *files = [NSMutableArray array];
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
        includingPropertiesForKeys:nil options:0 error:NULL]) {
        if ([url.lastPathComponent hasPrefix:@"Sunlight "]) [files addObject:url.lastPathComponent];
    }
    return @{@"online":screens, @"profile_uuids":[profiles.allObjects sortedArrayUsingSelector:@selector(compare:)],
        @"profile_files":[files sortedArrayUsingSelector:@selector(compare:)]};
}
static void Emit(NSDictionary *value) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String); fflush(stdout);
}
static SLSourceDisplay *Create(NSUInteger slot) {
    return [[SLSourceDisplay alloc] initWithBankSlot:slot width:3072 height:2048 scale:2 refreshRate:100];
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *operation = argc > 1 ? @(argv[1]) : @"--snapshot";
        if ([operation isEqual:@"--snapshot"]) { Emit(Snapshot()); return 0; }
        if ([operation isEqual:@"--busy"]) {
            for (NSUInteger slot = 0; slot < SLSourceDisplayBankSlotCount; slot++) {
                if (Create(slot)) { Emit(@{@"error":@"A second process acquired an occupied slot."}); return 1; }
            }
            Emit(@{@"busy":@YES}); return 0;
        }
        if (![operation isEqual:@"--hold"]) return 2;
        [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (Create(SLSourceDisplayBankSlotCount)) return 1;
        NSMutableArray<SLSourceDisplay *> *displays = [NSMutableArray array];
        NSMutableArray *identities = [NSMutableArray array];
        for (NSUInteger slot = 0; slot < SLSourceDisplayBankSlotCount; slot++) {
            @autoreleasepool {
                SLSourceDisplay *display = Create(slot);
                if (!display) { Emit(@{@"error":@"Could not acquire the source display slot."}); return 1; }
                [displays addObject:display];
                CGDirectDisplayID id = display.displayID;
                [identities addObject:@{@"id":@(id), @"uuid":UUID(id), @"vendor":@(CGDisplayVendorNumber(id)),
                    @"product":@(CGDisplayModelNumber(id)), @"serial":@(CGDisplaySerialNumber(id))}];
                if (Create(slot)) return 1;
            }
        }
        Emit(@{@"state":@"ready", @"slots":identities});
        // No windows, capture streams, animation, focus changes or AX placement.
        // EOF also cleans up if the controller exits unexpectedly.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:12];
        while (deadline.timeIntervalSinceNow > 0) {
            struct pollfd input = {STDIN_FILENO, POLLIN, 0};
            if (poll(&input, 1, 0) > 0) break;
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        [displays removeAllObjects];
        deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (deadline.timeIntervalSinceNow > 0) {
            NSSet *online = [NSSet setWithArray:Online()];
            if (![identities indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger index, BOOL *stop) {
                (void)index; (void)stop; return [online containsObject:item[@"id"]];
            }].count) { Emit(@{@"state":@"stopped", @"snapshot":Snapshot()}); return 0; }
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        Emit(@{@"error":@"Source displays did not disappear after release."}); return 1;
    }
}
