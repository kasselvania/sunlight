#import "SLSourceDisplay.h"
#import "CGVirtualDisplayPrivate.h"
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

const NSUInteger SLSourceDisplayBankSlotCount = 2;

@implementation SLSourceDisplay {
    CGVirtualDisplay *_display;
    int _slotLock;
}
- (instancetype)initWithBankSlot:(NSUInteger)bankSlot width:(NSUInteger)width height:(NSUInteger)height
                       scale:(NSUInteger)scale refreshRate:(double)refreshRate {
    if (!(self = [super init])) return nil;
    _slotLock = -1;
    if (bankSlot >= SLSourceDisplayBankSlotCount) return nil;
    if (!NSClassFromString(@"CGVirtualDisplay") || !NSClassFromString(@"CGVirtualDisplayDescriptor")
        || !NSClassFromString(@"CGVirtualDisplayMode") || !NSClassFromString(@"CGVirtualDisplaySettings")) return nil;

    // A random serial here made every launch a new monitor to ColorSync and
    // WindowServer. Keep exactly two identities, also across process restarts.
    // Product IDs and names differ as well so simultaneous banks are distinct.
    const unsigned int vendor = 0x4b56;
    const unsigned int product = 0x5342 + (unsigned int)bankSlot;
    const unsigned int serial = 0x53420001 + (unsigned int)bankSlot;

    // The kernel releases this lease on process death. Never unlink a lock file:
    // replacing its inode could give two processes ownership of the same slot.
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:NULL];
    if (!support) return nil;
    NSURL *folder = [support URLByAppendingPathComponent:@"Sunlight SIP Redesign/Window Bank" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:NULL]) return nil;
    NSURL *lock = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"display-slot-%lu.lock", (unsigned long)bankSlot]];
    _slotLock = open(lock.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    struct stat info;
    if (_slotLock < 0 || fstat(_slotLock, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != geteuid()
        || flock(_slotLock, LOCK_EX | LOCK_NB) != 0) return nil;

    // WindowServer may still be retiring a previous owner's display after its
    // process exited. Refuse that overlap instead of inventing a new identity.
    CGDirectDisplayID ids[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, ids, &count) != kCGErrorSuccess) return nil;
    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayVendorNumber(ids[i]) == vendor && CGDisplayModelNumber(ids[i]) == product
            && CGDisplaySerialNumber(ids[i]) == serial) return nil;
    }
    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = [NSString stringWithFormat:@"Sunlight Window Bank %lu", (unsigned long)bankSlot + 1];
    descriptor.maxPixelsWide = (unsigned int)MAX(8192, width * scale);
    descriptor.maxPixelsHigh = (unsigned int)MAX(8192, height * scale);
    descriptor.sizeInMillimeters = CGSizeMake(width * 0.264, height * 0.264);
    descriptor.vendorID = vendor; descriptor.productID = product; descriptor.serialNum = serial;
    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = scale > 1;
    settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:width height:height refreshRate:refreshRate]];
    if (!_display || ![_display applySettings:settings]) return nil;
    return self;
}
- (CGDirectDisplayID)displayID { return _display.displayID; }
- (void)dealloc {
    _display = nil;
    if (_slotLock >= 0) { flock(_slotLock, LOCK_UN); close(_slotLock); }
}
@end
