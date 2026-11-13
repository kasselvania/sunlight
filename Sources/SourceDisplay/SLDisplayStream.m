#import "SLDisplayStream.h"
#import <CoreGraphics/CGDisplayStream.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>

// CGDisplayStream is marked obsolete by the SDK. Resolve it as an optional
// backend; missing symbols or a rejected start leave ScreenCaptureKit available.
typedef CGDisplayStreamRef (*CreateStream)(CGDirectDisplayID,size_t,size_t,int32_t,CFDictionaryRef,dispatch_queue_t,CGDisplayStreamFrameAvailableHandler);
typedef CGError (*StreamOperation)(CGDisplayStreamRef);

@interface SLStreamSurfaceLease : NSObject
- (instancetype)initWithSurface:(IOSurfaceRef)surface;
@end
@implementation SLStreamSurfaceLease { IOSurfaceRef _surface; }
- (instancetype)initWithSurface:(IOSurfaceRef)surface {
    if ((self = [super init])) { _surface = (IOSurfaceRef)CFRetain(surface); IOSurfaceIncrementUseCount(surface); }
    return self;
}
- (void)dealloc { IOSurfaceDecrementUseCount(_surface); CFRelease(_surface); }
@end

CVPixelBufferRef SLRetainDisplayFrame(IOSurfaceRef surface) {
    SLStreamSurfaceLease *lease = [[SLStreamSurfaceLease alloc] initWithSurface:surface];
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &buffer) != kCVReturnSuccess) return NULL;
    CVBufferSetAttachment(buffer, CFSTR("SunlightSourceSurfaceLease"), (__bridge CFTypeRef)lease, kCVAttachmentMode_ShouldNotPropagate);
    return buffer;
}

@implementation SLDisplayStream {
    CGDisplayStreamRef _stream;
    StreamOperation _start, _stop;
    BOOL _started;
}
- (instancetype)initWithDisplayID:(CGDirectDisplayID)displayID sourceRect:(CGRect)sourceRect
                       pixelSize:(CGSize)pixelSize queue:(dispatch_queue_t)queue {
    if (!(self = [super init])) return nil;
    CreateStream create = (CreateStream)dlsym(RTLD_DEFAULT, "CGDisplayStreamCreateWithDispatchQueue");
    _start = (StreamOperation)dlsym(RTLD_DEFAULT, "CGDisplayStreamStart");
    _stop = (StreamOperation)dlsym(RTLD_DEFAULT, "CGDisplayStreamStop");
    const CFStringRef *rectKey = dlsym(RTLD_DEFAULT, "kCGDisplayStreamSourceRect");
    const CFStringRef *timeKey = dlsym(RTLD_DEFAULT, "kCGDisplayStreamMinimumFrameTime");
    const CFStringRef *depthKey = dlsym(RTLD_DEFAULT, "kCGDisplayStreamQueueDepth");
    const CFStringRef *cursorKey = dlsym(RTLD_DEFAULT, "kCGDisplayStreamShowCursor");
    if (!create || !_start || !_stop || !rectKey || !timeKey || !depthKey || !cursorKey) return nil;
    NSDictionary *properties = @{(__bridge NSString *)*rectKey: CFBridgingRelease(CGRectCreateDictionaryRepresentation(sourceRect)),
        (__bridge NSString *)*timeKey: @0, (__bridge NSString *)*depthKey: @8, (__bridge NSString *)*cursorKey: @NO};
    __weak SLDisplayStream *owner = self;
    _stream = create(displayID, (size_t)pixelSize.width, (size_t)pixelSize.height, kCVPixelFormatType_32BGRA,
                     (__bridge CFDictionaryRef)properties, queue,
        ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef surface, CGDisplayStreamUpdateRef update) {
            (void)displayTime; (void)update;
            SLDisplayStream *strong = owner;
            if (!strong) return;
            if (status == kCGDisplayStreamFrameStatusStopped) { if (strong.onStopped) strong.onStopped(); return; }
            if (status != kCGDisplayStreamFrameStatusFrameComplete || !surface) return;
            CVPixelBufferRef buffer = SLRetainDisplayFrame(surface);
            if (!buffer) { if (strong.onStopped) strong.onStopped(); return; }
            if (strong.onFrame) strong.onFrame(buffer);
            CVPixelBufferRelease(buffer);
        });
    return _stream ? self : nil;
}
- (BOOL)start { _started = _stream && _start(_stream) == kCGErrorSuccess; return _started; }
- (void)stop { if (_started) { _started = NO; _stop(_stream); } }
- (void)dealloc { [self stop]; if (_stream) CFRelease(_stream); }
@end
