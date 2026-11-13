#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "SLDisplayStream.h"

NS_ASSUME_NONNULL_BEGIN
/// Owns one temporary extended display. Releasing it removes only that display.
@interface SLSourceDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height
                                scale:(NSUInteger)scale refreshRate:(double)refreshRate;
@end
NS_ASSUME_NONNULL_END
