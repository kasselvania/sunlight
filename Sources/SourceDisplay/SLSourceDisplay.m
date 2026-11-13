#import "SLSourceDisplay.h"
#import "CGVirtualDisplayPrivate.h"

@implementation SLSourceDisplay {
    CGVirtualDisplay *_display;
}
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height
                       scale:(NSUInteger)scale refreshRate:(double)refreshRate {
    if (!(self = [super init])) return nil;
    if (!NSClassFromString(@"CGVirtualDisplay") || !NSClassFromString(@"CGVirtualDisplayDescriptor")
        || !NSClassFromString(@"CGVirtualDisplayMode") || !NSClassFromString(@"CGVirtualDisplaySettings")) return nil;
    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = @"Sunlight Window Bank";
    descriptor.maxPixelsWide = (unsigned int)MAX(8192, width * scale);
    descriptor.maxPixelsHigh = (unsigned int)MAX(8192, height * scale);
    descriptor.sizeInMillimeters = CGSizeMake(width * 0.264, height * 0.264);
    descriptor.vendorID = 0x4b56; descriptor.productID = 0x5342;
    descriptor.serialNum = arc4random_uniform(UINT32_MAX - 1) + 1;
    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = scale > 1;
    settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:width height:height refreshRate:refreshRate]];
    if (!_display || ![_display applySettings:settings]) return nil;
    return self;
}
- (CGDirectDisplayID)displayID { return _display.displayID; }
@end
