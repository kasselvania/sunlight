#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "SLDisplayStream.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT const NSUInteger SLSourceDisplayBankSlotCount;
/// Owns one temporary extended display. Releasing it removes only that display.
/// Slots have permanent identities; a second owner of the same slot is refused.
@interface SLSourceDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable instancetype)initWithBankSlot:(NSUInteger)bankSlot width:(NSUInteger)width height:(NSUInteger)height
                                scale:(NSUInteger)scale refreshRate:(double)refreshRate;
@end
NS_ASSUME_NONNULL_END
