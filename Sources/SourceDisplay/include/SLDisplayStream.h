#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
NS_ASSUME_NONNULL_BEGIN
CVPixelBufferRef _Nullable SLRetainDisplayFrame(IOSurfaceRef surface) CF_RETURNS_RETAINED;
/// A zero-copy feed of an owned source display. Each pixel buffer carries the
/// IOSurface use-count lease required by CGDisplayStream, until its last reader.
@interface SLDisplayStream : NSObject
@property(nonatomic, copy, nullable) void (^onFrame)(CVPixelBufferRef buffer);
@property(nonatomic, copy, nullable) void (^onStopped)(void);
- (nullable instancetype)initWithDisplayID:(CGDirectDisplayID)displayID sourceRect:(CGRect)sourceRect
                               pixelSize:(CGSize)pixelSize queue:(dispatch_queue_t)queue;
- (BOOL)start;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
