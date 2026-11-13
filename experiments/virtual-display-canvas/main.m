#import <AppKit/AppKit.h>
#import "SLSourceDisplay.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#import <unistd.h>

static BOOL WriteJSON(NSDictionary *value, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:NULL];
}
static NSArray<NSNumber *> *Displays(void) {
    CGDirectDisplayID ids[32]; uint32_t count = 0;
    if (CGGetActiveDisplayList(32, ids, &count) != kCGErrorSuccess) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (uint32_t i = 0; i < count; i++) [result addObject:@(ids[i])];
    return result;
}
static NSDictionary *DisplayBounds(NSArray<NSNumber *> *ids) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSNumber *number in ids) result[number.stringValue] = NSStringFromRect(CGDisplayBounds(number.unsignedIntValue));
    return result;
}
static NSTextField *Label(NSString *text, CGFloat size) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size];
    return label;
}

@interface SourceView : NSView
@property NSUInteger sequence;
@property NSUInteger index;
@end
@implementation SourceView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)rect {
    (void)rect;
    NSArray *colors = @[NSColor.systemOrangeColor, NSColor.systemGreenColor, NSColor.systemPurpleColor];
    NSColor *color = colors[(self.index - 1) % 3];
    [[color colorWithAlphaComponent:0.3] setFill]; NSRectFill(self.bounds);
    NSString *text = [NSString stringWithFormat:@"REAL APP WINDOW %lu\nSequence %06lu", (unsigned long)self.index, (unsigned long)self.sequence];
    [text drawAtPoint:NSMakePoint(16, 24) withAttributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:20 weight:NSFontWeightMedium], NSForegroundColorAttributeName:NSColor.labelColor}];
    [color setFill];
    CGFloat x = 12 + fmod(self.sequence * 2, MAX(1, self.bounds.size.width - 40));
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x, 146, 22, 22)] fill];
    // 1010 marker, two source-ID bits, then twelve sequence bits. Readable from
    // captured pixels without OCR, and separate from source-side timer counts.
    unsigned int bits = (10u << 14) | ((unsigned int)self.index << 12) | ((unsigned int)self.sequence & 4095);
    for (unsigned int i = 0; i < 18; i++) {
        [((bits >> (17 - i)) & 1 ? NSColor.whiteColor : NSColor.blackColor) setFill];
        NSRectFill(NSMakeRect(16 + i * 12, 115, 10, 10));
    }
}
@end

@interface SourceApp : NSObject <NSApplicationDelegate>
@property NSString *directory;
@property NSString *token;
@property CGDirectDisplayID displayID;
@property NSMutableArray<NSWindow *> *windows;
@property NSTimer *timer;
@property pid_t parentPID;
@end
@implementation SourceApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.parentPID = getppid();
    NSScreen *target = nil;
    for (NSScreen *screen in NSScreen.screens) if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == self.displayID) target = screen;
    if (!target) exit(2);
    self.windows = [NSMutableArray array];
    NSMutableArray *sources = [NSMutableArray array];
    for (NSUInteger i = 0; i < 3; i++) {
        NSRect rect = NSMakeRect(target.frame.origin.x + 20 + i * 330, NSMaxY(target.visibleFrame) - 260, 290, 190);
        NSWindow *window = [[NSWindow alloc] initWithContentRect:rect styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO screen:target];
        [window setFrame:NSMakeRect(rect.origin.x,rect.origin.y,290,222) display:NO];
        window.title = [NSString stringWithFormat:@"Virtual source %lu", (unsigned long)(i + 1)];
        window.releasedWhenClosed = NO;
        SourceView *view = [[SourceView alloc] initWithFrame:NSMakeRect(0,0,290,190)];
        view.index = i + 1; window.contentView = view;
        [window orderFront:nil];
        [self.windows addObject:window];
        [sources addObject:@{@"id":@(window.windowNumber), @"index":@(i + 1), @"titlebar":@(window.frame.size.height - view.bounds.size.height), @"appkit_frame":NSStringFromRect(window.frame)}];
    }
    WriteJSON(@{@"pid":@(NSProcessInfo.processInfo.processIdentifier), @"token":self.token, @"display_id":@(self.displayID), @"sources":sources}, [self.directory stringByAppendingPathComponent:@"sources.json"]);
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        if (getppid() != self.parentPID) exit(0);
        for (NSWindow *window in self.windows) {
            SourceView *view = (SourceView *)window.contentView;
            view.sequence++; view.needsDisplay = YES;
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
@end

@interface Canvas : NSView {
    CVPixelBufferRef _displayedBuffer;
}
@property NSArray<NSDictionary *> *sources;
@property NSMutableArray<CALayer *> *tiles;
@property NSMutableArray<CATextLayer *> *labels;
@property CGFloat zoom;
@property CGPoint pan;
@property CGPoint last;
- (void)configure:(NSArray<NSDictionary *> *)sources;
- (void)showBuffer:(CVPixelBufferRef)buffer;
- (void)fit;
@end
@implementation Canvas
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES; self.layerUsesCoreImageFilters = NO;
        self.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:1].CGColor;
        self.layer.masksToBounds = YES;
        self.tiles = [NSMutableArray array]; self.labels = [NSMutableArray array];
        self.zoom = 1; self.pan = CGPointMake(24,24);
    }
    return self;
}
- (void)configure:(NSArray<NSDictionary *> *)sources {
    for (CALayer *layer in self.tiles) [layer removeFromSuperlayer];
    for (CALayer *layer in self.labels) [layer removeFromSuperlayer];
    [self.tiles removeAllObjects]; [self.labels removeAllObjects];
    self.sources = sources;
    for (NSDictionary *source in sources) {
        CALayer *tile = [CALayer layer];
        tile.contentsGravity = kCAGravityResizeAspect;
        tile.contentsRect = NSRectToCGRect(NSRectFromString(source[@"crop"]));
        tile.borderWidth = 1; tile.borderColor = NSColor.grayColor.CGColor;
        [self.layer addSublayer:tile]; [self.tiles addObject:tile];
        CATextLayer *label = [CATextLayer layer];
        label.string = [NSString stringWithFormat:@"WINDOW %@", source[@"index"]];
        label.fontSize = 12; label.foregroundColor = NSColor.whiteColor.CGColor;
        label.contentsScale = NSScreen.mainScreen.backingScaleFactor;
        [self.layer addSublayer:label]; [self.labels addObject:label];
    }
    [self fit];
}
- (void)fit {
    self.zoom=MIN(1,MIN(MAX(0.25,(self.bounds.size.width-48)/680),MAX(0.25,(self.bounds.size.height-48)/540)));
    self.pan=CGPointMake(24,24); [self position];
}
- (void)position {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (NSUInteger i=0; i<self.tiles.count; i++) {
        CGRect frame = CGRectMake(self.pan.x + (i % 2) * 340 * self.zoom, self.pan.y + (i / 2) * 270 * self.zoom, 290 * self.zoom, 222 * self.zoom);
        self.tiles[i].frame = frame;
        self.labels[i].frame = CGRectMake(frame.origin.x, CGRectGetMaxY(frame)+6, 340, 20);
    }
    [CATransaction commit];
}
- (void)showBuffer:(CVPixelBufferRef)buffer {
    IOSurfaceRef surface=buffer?CVPixelBufferGetIOSurface(buffer):NULL;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (CALayer *tile in self.tiles) tile.contents = surface ? (__bridge id)surface : nil;
    [CATransaction commit];
    // Retaining just the IOSurface does not keep the capture pool from reusing
    // its pixels. Keep the pixel-buffer lease while the layers display it.
    CVPixelBufferRef old=_displayedBuffer;
    _displayedBuffer=buffer?CVPixelBufferRetain(buffer):NULL;
    if(old)CVPixelBufferRelease(old);
}
- (void)dealloc { if(_displayedBuffer)CVPixelBufferRelease(_displayedBuffer); }
- (void)mouseDown:(NSEvent *)event { self.last = [self convertPoint:event.locationInWindow fromView:nil]; }
- (void)mouseDragged:(NSEvent *)event {
    CGPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    self.pan = CGPointMake(self.pan.x + point.x-self.last.x, self.pan.y + point.y-self.last.y);
    self.last = point; [self position];
}
- (void)magnifyWithEvent:(NSEvent *)event {
    CGPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat next = MAX(0.25, MIN(2, self.zoom * (1 + event.magnification)));
    CGFloat ratio = next/self.zoom;
    self.pan = CGPointMake(point.x-(point.x-self.pan.x)*ratio, point.y-(point.y-self.pan.y)*ratio);
    self.zoom = next; [self position];
}
- (void)scrollWheel:(NSEvent *)event {
    self.pan = CGPointMake(self.pan.x-event.scrollingDeltaX, self.pan.y+event.scrollingDeltaY); [self position];
}
@end

@interface Viewer : NSObject <NSApplicationDelegate, NSWindowDelegate, SCStreamDelegate, SCStreamOutput> {
    CVPixelBufferRef _latest;
    BOOL _deliveryPending;
}
@property NSWindow *window;
@property Canvas *canvas;
@property NSTextField *status;
@property SLSourceDisplay *display;
@property CGDirectDisplayID displayID;
@property NSArray<NSNumber *> *beforeIDs;
@property NSDictionary *beforeBounds;
@property NSTask *fixture;
@property NSTimer *poll;
@property NSString *directory;
@property NSString *token;
@property NSString *failure;
@property SCStream *stream;
@property BOOL streamStarted;
@property BOOL startInFlight;
@property BOOL stopInFlight;
@property BOOL removingDisplay;
@property BOOL preparingCapture;
@property BOOL stopping;
@property BOOL quitWhenStopped;
@property BOOL trial;
@property CFTimeInterval deadline;
@property NSArray<NSDictionary *> *sourceInfo;
@property NSMutableArray<NSMutableSet<NSNumber *> *> *sequences;
@property NSUInteger completeFrames;
@property NSUInteger generation;
@property NSButton *startButton;
@property NSButton *stopButton;
@property NSMutableArray<NSDictionary *> *startupEvents;
@property NSUInteger streamsStarted;
@property NSTextField *notice;
@property NSButton *reopenButton;
@property NSTimer *permissionTimer;
@property BOOL permissionRequested;
@property BOOL liveAnnounced;
@property NSString *launchRecord;
@end

@implementation Viewer
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSMenu *menu = [NSMenu new]; NSMenuItem *item = [NSMenuItem new]; [menu addItem:item];
    item.submenu = [NSMenu new]; [item.submenu addItemWithTitle:@"Quit Sunlight Canvas Lab" action:@selector(terminate:) keyEquivalent:@"q"];
    NSApp.mainMenu = menu;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(160,100,980,700) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Sunlight Canvas Lab"; self.window.releasedWhenClosed = NO; self.window.delegate = self;
    self.window.minSize=NSMakeSize(900,650);
    NSView *content = self.window.contentView;
    NSTextField *title = Label(@"Real app windows, one live display feed, SIP enabled", 20);
    NSTextField *help = Label(@"Start creates one temporary virtual monitor for three synthetic windows. Drag, scroll or pinch inside the canvas.", 12);
    NSButton *start = [NSButton buttonWithTitle:@"Start virtual canvas" target:self action:@selector(start:)];
    NSButton *stop = [NSButton buttonWithTitle:@"Stop and remove monitor" target:self action:@selector(stop:)];
    self.startButton=start; self.stopButton=stop; stop.enabled=NO;
    NSButton *access = [NSButton buttonWithTitle:@"Permissions…" target:self action:@selector(access:)];
    NSButton *fit = [NSButton buttonWithTitle:@"Fit" target:self action:@selector(fit:)];
    self.reopenButton=[NSButton buttonWithTitle:@"Reopen after allowing" target:self action:@selector(reopen:)];
    self.reopenButton.hidden=YES;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[start,stop,fit,access,self.reopenButton]]; buttons.spacing=10; buttons.detachesHiddenViews=YES;
    self.status=Label(@"Ready. The source windows will live on the virtual monitor; their live contents should appear here.",12);
    self.status.maximumNumberOfLines=3; self.status.lineBreakMode=NSLineBreakByWordWrapping;
    self.canvas=[[Canvas alloc] initWithFrame:NSZeroRect];
    self.notice=Label(@"Starting the canvas…",18);
    self.notice.textColor=NSColor.whiteColor; self.notice.alignment=NSTextAlignmentCenter;
    self.notice.maximumNumberOfLines=5; self.notice.lineBreakMode=NSLineBreakByWordWrapping;
    self.notice.translatesAutoresizingMaskIntoConstraints=NO; [self.canvas addSubview:self.notice];
    [NSLayoutConstraint activateConstraints:@[
        [self.notice.centerXAnchor constraintEqualToAnchor:self.canvas.centerXAnchor],
        [self.notice.centerYAnchor constraintEqualToAnchor:self.canvas.centerYAnchor],
        [self.notice.widthAnchor constraintEqualToConstant:620]
    ]];
    for (NSView *view in @[title,help,buttons,self.canvas,self.status]) { view.translatesAutoresizingMaskIntoConstraints=NO; [content addSubview:view]; }
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20], [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [help.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [help.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [buttons.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [buttons.topAnchor constraintEqualToAnchor:help.bottomAnchor constant:12],
        [self.canvas.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16], [self.canvas.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.canvas.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:12], [self.canvas.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-12],
        [self.status.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [self.status.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.status.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14], [self.status.heightAnchor constraintGreaterThanOrEqualToConstant:35]
    ]];
    [self.window makeKeyAndOrderFront:nil];
    NSString *launchDirectory=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"sunlight-canvas-launch-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:launchDirectory withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL];
    self.launchRecord=[launchDirectory stringByAppendingPathComponent:@"launch.json"];
    if(self.trial || CGPreflightScreenCaptureAccess()) [self start:nil];
    else { [self permissionState]; dispatch_async(dispatch_get_main_queue(),^{[self access:nil];}); }
    if(!self.trial) [NSApp activateIgnoringOtherApps:YES];
}
- (void)recordLaunch:(NSString *)phase {
    WriteJSON(@{@"pid":@(getpid()),@"ppid":@(getppid()),@"window_id":@(self.window.windowNumber),
        @"app_path":NSBundle.mainBundle.bundlePath,@"build":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"],
        @"phase":phase,@"screen_recording":@(CGPreflightScreenCaptureAccess()),@"trial":@(self.trial),
        @"run":self.directory?:@""},self.launchRecord);
}
- (void)permissionState {
    self.startButton.enabled=YES; self.startButton.title=@"Enable Screen Recording";
    self.stopButton.enabled=NO; self.reopenButton.hidden=NO;
    self.notice.hidden=NO;
    self.notice.stringValue=@"One-time macOS permission is needed.\n\nClick Enable Screen Recording and allow Sunlight Canvas Lab.\nIf macOS asks you to quit and reopen, do so.\nThe canvas starts automatically once access is available.";
    self.status.stringValue=@"SIP stays enabled. No virtual monitor is created while permission is pending.";
    [self recordLaunch:@"awaiting_permission"];
}
- (void)access:(id)sender {
    (void)sender;
    if(CGPreflightScreenCaptureAccess()){[self.permissionTimer invalidate];self.permissionTimer=nil;[self start:nil];return;}
    [self permissionState];
    BOOL allowed=NO;
    if(!self.permissionRequested){self.permissionRequested=YES;allowed=CGRequestScreenCaptureAccess();}
    if(!allowed) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
    if(!self.permissionTimer){
        __weak Viewer *weakSelf=self;
        self.permissionTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){
            Viewer *viewer=weakSelf;
            if(!viewer){[timer invalidate];return;}
            if(CGPreflightScreenCaptureAccess()){
                [timer invalidate];viewer.permissionTimer=nil;viewer.reopenButton.hidden=YES;[viewer start:nil];
            }
        }];
    }
}
- (void)reopen:(id)sender {
    (void)sender;
    [self.permissionTimer invalidate];self.permissionTimer=nil;
    self.reopenButton.enabled=NO;self.startButton.enabled=NO;
    NSWorkspaceOpenConfiguration *configuration=[NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance=YES; configuration.activates=YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:configuration completionHandler:^(NSRunningApplication *application,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            if(application && !error)[NSApp terminate:nil];
            else {self.reopenButton.enabled=YES;self.startButton.enabled=YES;self.status.stringValue=@"Could not reopen automatically. Quit and open Sunlight Canvas Lab again.";}
        });
    }];
}
- (void)fit:(id)sender { (void)sender; [self.canvas fit]; }
- (void)recordStartup:(NSString *)stage {
    [self.startupEvents addObject:@{@"stage":stage,@"display_active":@(self.displayID && CGDisplayIsActive(self.displayID)),
        @"display_bounds":self.displayID?NSStringFromRect(CGDisplayBounds(self.displayID)):@"",
        @"screen_recording":@(CGPreflightScreenCaptureAccess()),@"failure":self.failure?:@""}];
    WriteJSON(@{@"pid":@(getpid()),@"ppid":@(getppid()),@"app_path":NSBundle.mainBundle.bundlePath,
        @"display_id":@(self.displayID),@"events":self.startupEvents},[self.directory stringByAppendingPathComponent:@"startup.json"]);
}
- (void)fail:(NSString *)message { self.failure=message; self.status.stringValue=message; [self stop:nil]; }
- (void)start:(id)sender {
    (void)sender;
    if(self.display || self.fixture || self.stopping) return;
    if(!self.trial && !CGPreflightScreenCaptureAccess()){[self access:nil];return;}
    [self.permissionTimer invalidate]; self.permissionTimer=nil; self.reopenButton.hidden=YES;
    self.startButton.title=@"Start virtual canvas"; self.notice.hidden=NO;self.notice.stringValue=@"Starting the virtual monitor and three live windows…";
    self.token=NSUUID.UUID.UUIDString;
    self.directory=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"sunlight-virtual-canvas-" stringByAppendingString:self.token]];
    [NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:NULL];
    self.beforeIDs=Displays(); self.beforeBounds=DisplayBounds(self.beforeIDs);
    self.failure=nil; self.completeFrames=0; self.sequences=[NSMutableArray array];self.liveAnnounced=NO;
    self.startupEvents=[NSMutableArray array]; self.streamsStarted=0;
    self.startButton.enabled=NO; self.stopButton.enabled=YES;
    self.status.stringValue=@"Starting: creating the temporary virtual monitor…";
    self.preparingCapture=NO; self.startInFlight=NO; self.stopInFlight=NO; self.displayID=0; self.sourceInfo=nil;
    for(NSUInteger i=0;i<3;i++) [self.sequences addObject:[NSMutableSet set]];
    self.generation++;
    [self recordStartup:@"permission_check"];
    [self recordLaunch:@"starting"];
    if(!CGPreflightScreenCaptureAccess()) { [self fail:@"Screen Recording is not granted to this app. Use Allow Screen Recording, then reopen if macOS requests it."]; return; }
    self.display=[[SLSourceDisplay alloc] initWithBankSlot:0 width:1280 height:720 scale:1 refreshRate:60];
    if(!self.display) { [self fail:@"The source display slot is unavailable or already in use."]; return; }
    self.displayID=self.display.displayID;
    if([self.beforeIDs containsObject:@(self.displayID)]) { [self fail:@"The new display did not have a distinct identity."]; return; }
    // macOS already arranges a newly created extended display. The canvas and
    // source app use its actual bounds; neither needs it on a particular side.
    // Avoid a global display-configuration transaction entirely.
    [self recordStartup:@"waiting_for_display"];
    self.status.stringValue=@"Starting: waiting for macOS to make the new monitor available…";
    self.deadline=CACurrentMediaTime()+8;
    __weak Viewer *weakSelf=self;
    self.poll=[NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer){(void)timer; [weakSelf prepare];}];
    [NSRunLoop.mainRunLoop addTimer:self.poll forMode:NSRunLoopCommonModes];
}
- (void)prepare {
    if(self.stopping || self.preparingCapture) return;
    if(CACurrentMediaTime()>self.deadline) { [self fail:@"The virtual sources did not become available in time."]; return; }
    if(!CGDisplayIsActive(self.displayID)) return;
    if(!self.fixture) {
        [self recordStartup:@"display_ready"];
        WriteJSON(@{@"display_id":@(self.displayID),@"bounds":NSStringFromRect(CGDisplayBounds(self.displayID)),@"before_bounds":self.beforeBounds,
            @"viewer_pid":@(getpid()),@"viewer_window_id":@(self.window.windowNumber)},[self.directory stringByAppendingPathComponent:@"display.json"]);
        self.status.stringValue=@"Starting: opening the three test windows on the virtual monitor…";
        NSTask *task=[NSTask new]; self.fixture=task;
        task.executableURL=NSBundle.mainBundle.executableURL;
        task.arguments=@[@"--fixture",self.directory,self.token,[@(self.displayID) stringValue]];
        task.standardOutput=NSFileHandle.fileHandleWithNullDevice; task.standardError=NSFileHandle.fileHandleWithNullDevice;
        __weak Viewer *weakSelf=self;
        task.terminationHandler=^(NSTask *finished){ (void)finished; dispatch_async(dispatch_get_main_queue(),^{
            Viewer *viewer=weakSelf; if(!viewer) return;
            viewer.fixture=nil;
            if(viewer.stopping) [viewer removeDisplay];
            else [viewer fail:@"The source app exited."];
        });};
        NSError *error=nil;
        if(![task launchAndReturnError:&error]) { self.fixture=nil; [self fail:@"Could not start the separate source app."]; }
        else [self recordStartup:@"source_started"];
        return;
    }
    NSData *data=[NSData dataWithContentsOfFile:[self.directory stringByAppendingPathComponent:@"sources.json"]];
    if(!data) return;
    NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if(![manifest[@"token"] isEqual:self.token] || [manifest[@"pid"] intValue]!=self.fixture.processIdentifier || [manifest[@"display_id"] unsignedIntValue]!=self.displayID) {
        [self fail:@"Source manifest identity mismatch."]; return;
    }
    self.preparingCapture=YES;
    NSUInteger generation=self.generation;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            if(self.stopping || self.generation!=generation) return;
            self.preparingCapture=NO;
            if(error) { [self fail:[@"Source enumeration failed: " stringByAppendingString:error.localizedDescription]]; return; }
            SCDisplay *display=nil; for(SCDisplay *candidate in content.displays) if(candidate.displayID==self.displayID) display=candidate;
            NSMutableArray<SCWindow *> *windows=[NSMutableArray array]; NSMutableArray *info=[NSMutableArray array]; NSMutableArray *diagnostics=[NSMutableArray array];
            for(NSDictionary *source in manifest[@"sources"]) {
                SCWindow *found=nil;
                for(SCWindow *window in content.windows) if(window.windowID==[source[@"id"] unsignedIntValue] && window.owningApplication.processID==self.fixture.processIdentifier) found=window;
                [diagnostics addObject:@{@"id":source[@"id"],@"found":@(found!=nil),@"window_frame":found?NSStringFromRect(found.frame):@"",@"display_frame":display?NSStringFromRect(display.frame):@""}];
                if(!found || !display) continue;
                CGRect rect=found.frame;
                if(!CGRectContainsRect(display.frame,rect)) continue;
                // Quartz window frames start at the top; this AppKit layer's
                // contentsRect is measured from the bottom of the source image.
                CGRect crop=CGRectMake((rect.origin.x-display.frame.origin.x)/display.frame.size.width,
                    1-(CGRectGetMaxY(rect)-display.frame.origin.y)/display.frame.size.height,
                    rect.size.width/display.frame.size.width,rect.size.height/display.frame.size.height);
                NSMutableDictionary *item=[source mutableCopy]; item[@"crop"]=NSStringFromRect(crop);
                item[@"pixel_x"]=@(rect.origin.x-display.frame.origin.x+21);
                item[@"pixel_y"]=@(rect.origin.y-display.frame.origin.y+[source[@"titlebar"] doubleValue]+120);
                [info addObject:item]; [windows addObject:found];
            }
            WriteJSON(@{@"sources":diagnostics,@"fixture_pid":@(self.fixture.processIdentifier)},[self.directory stringByAppendingPathComponent:@"enumeration.json"]);
            if(windows.count!=3 || !display) return;
            [self.poll invalidate]; self.poll=nil;
            self.sourceInfo=info; [self.canvas configure:info];
            SCContentFilter *filter=[[SCContentFilter alloc] initWithDisplay:display includingWindows:windows];
            SCStreamConfiguration *configuration=[SCStreamConfiguration new];
            configuration.width=1280; configuration.height=720; configuration.pixelFormat=kCVPixelFormatType_32BGRA;
            configuration.queueDepth=3; configuration.minimumFrameInterval=CMTimeMake(1,60);
            configuration.showsCursor=NO; configuration.capturesAudio=NO;
            self.stream=[[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
            NSError *outputError=nil;
            if(![self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_queue_create("sunlight.virtual-canvas.frames",DISPATCH_QUEUE_SERIAL) error:&outputError]) {
                [self fail:@"Could not attach the frame receiver."]; return;
            }
            self.startInFlight=YES;
            [self.stream startCaptureWithCompletionHandler:^(NSError *startError){ dispatch_async(dispatch_get_main_queue(),^{
                self.startInFlight=NO;
                if(startError) { self.stream=nil; [self fail:[@"Capture failed: " stringByAppendingString:startError.localizedDescription]]; return; }
                self.streamStarted=YES;
                self.streamsStarted++;
                [self recordStartup:@"capturing"];
                if(self.stopping) { [self stop:nil]; return; }
                self.status.stringValue=@"One display stream is running. The three tiles should show changing numbers. Drag, scroll or pinch here.";
                if(self.trial) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                        if(self.generation!=generation || self.stopping) return;
                        self.canvas.pan=CGPointMake(50,40); self.canvas.zoom=0.75; [self.canvas position];
                        WriteJSON(@{@"zoom":@0.75,@"pan_x":@50,@"pan_y":@40},[self.directory stringByAppendingPathComponent:@"camera.json"]);
                    });
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC),dispatch_get_main_queue(),^{ if(self.generation==generation) [self stop:nil]; });
                }
            });}];
        });
    }];
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if(type!=SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) return;
    NSArray *attachments=(__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,false);
    NSNumber *frameStatus=attachments.firstObject[SCStreamFrameInfoStatus];
    if(!frameStatus || frameStatus.integerValue!=SCFrameStatusComplete) return;
    CVPixelBufferRef buffer=CMSampleBufferGetImageBuffer(sampleBuffer); if(!buffer) return;
    @synchronized(self) {
        if(self.stopping || stream!=self.stream) return;
        if(_latest) CVPixelBufferRelease(_latest); _latest=CVPixelBufferRetain(buffer);
        if(_deliveryPending) return; _deliveryPending=YES;
    }
    dispatch_async(dispatch_get_main_queue(),^{
        CVPixelBufferRef frame=NULL;
        @synchronized(self){ frame=self->_latest; self->_latest=NULL; self->_deliveryPending=NO; }
        if(!frame) return;
        if(!self.stopping) {
            [self.canvas showBuffer:frame];
            [self inspectFrame:frame];
        }
        CVPixelBufferRelease(frame);
    });
}
- (void)inspectFrame:(CVPixelBufferRef)frame {
    self.completeFrames++;
    CVPixelBufferLockBaseAddress(frame,kCVPixelBufferLock_ReadOnly);
    uint8_t *base=CVPixelBufferGetBaseAddress(frame); size_t row=CVPixelBufferGetBytesPerRow(frame);
    size_t width=CVPixelBufferGetWidth(frame),height=CVPixelBufferGetHeight(frame);
    for(NSDictionary *source in self.sourceInfo) {
        NSInteger x=[source[@"pixel_x"] integerValue], y=[source[@"pixel_y"] integerValue];
        if(x<0 || y<0 || x+17*12>=(NSInteger)width || y>=(NSInteger)height) continue;
        unsigned int bits=0;
        for(int i=0;i<18;i++){ uint8_t *pixel=base+y*row+(x+i*12)*4; bits=(bits<<1)|((pixel[0]+pixel[1]+pixel[2])>384); }
        NSUInteger index=[source[@"index"] unsignedIntegerValue];
        if((bits>>14)==10 && ((bits>>12)&3)==index) [self.sequences[index-1] addObject:@(bits&4095)];
    }
    if(self.trial && self.completeFrames==30) {
        CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
        CGContextRef context=CGBitmapContextCreate(base,width,height,8,row,color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
        CGImageRef image=context?CGBitmapContextCreateImage(context):NULL;
        NSURL *url=[NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"captured-bank.png"]];
        CGImageDestinationRef destination=image?CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL):NULL;
        if(destination){CGImageDestinationAddImage(destination,image,NULL);CGImageDestinationFinalize(destination);CFRelease(destination);}
        if(image)CGImageRelease(image);if(context)CGContextRelease(context);CGColorSpaceRelease(color);
    }
    CVPixelBufferUnlockBaseAddress(frame,kCVPixelBufferLock_ReadOnly);
    if(!self.liveAnnounced){
        BOOL live=YES;for(NSSet *values in self.sequences)if(values.count<2)live=NO;
        if(live){self.liveAnnounced=YES;self.notice.hidden=YES;self.status.stringValue=@"Three live windows. Drag or scroll to pan, pinch to zoom. Stop removes the temporary monitor.";[self recordLaunch:@"live"];}
    }
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(),^{ if(stream==self.stream && !self.stopping){self.streamStarted=NO;[self fail:[@"Capture stopped: " stringByAppendingString:error.localizedDescription]];} });
}
- (void)stop:(id)sender {
    (void)sender;
    if(!self.directory || self.removingDisplay) return;
    if(!self.display && !self.fixture && !self.stream && !self.stopping && !self.failure) return;
    self.stopping=YES; [self.poll invalidate]; self.poll=nil;
    self.stopButton.enabled=NO;
    if(self.startInFlight || self.stopInFlight) return;
    if(self.streamStarted) {
        self.streamStarted=NO;
        self.stopInFlight=YES;
        [self.stream stopCaptureWithCompletionHandler:^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{
            self.stopInFlight=NO;
            if(error && !self.failure) self.failure=[@"Capture stop failed: " stringByAppendingString:error.localizedDescription];
            self.stream=nil; [self stop:nil];
        });}];
        return;
    }
    @synchronized(self){if(_latest){CVPixelBufferRelease(_latest);_latest=NULL;}}
    self.stream=nil;
    [self.canvas showBuffer:NULL];
    if(self.fixture.running){ [self.fixture terminate]; return; }
    self.fixture=nil; [self removeDisplay];
}
- (void)removeDisplay {
    if(self.removingDisplay) return;
    self.removingDisplay=YES;
    self.display=nil;
    CFTimeInterval deadline=CACurrentMediaTime()+5;
    __block NSTimer *wait=nil;
    wait=[NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer){
        BOOL removed=![Displays() containsObject:@(self.displayID)];
        if(!removed && CACurrentMediaTime()<deadline) return;
        [timer invalidate]; wait=nil;
        BOOL unchanged=[self.beforeBounds isEqual:DisplayBounds(self.beforeIDs)];
        NSMutableArray *counts=[NSMutableArray array]; BOOL advancing=YES;
        for(NSSet *values in self.sequences){[counts addObject:@(values.count)]; if(values.count<5) advancing=NO;}
        BOOL passed=!self.failure && advancing && counts.count==3 && removed && unchanged && !self.fixture;
        NSDictionary *result=@{@"kind":@"virtual_display_capture_trial",@"passed":@(passed),@"failure":self.failure?:@"",
            @"stream_count":@(self.streamsStarted),@"foreign_window_count":@(self.sourceInfo.count),@"complete_frames_received":@(self.completeFrames),
            @"distinct_decoded_sequences":counts,@"virtual_display_removed":@(removed),@"existing_display_bounds_unchanged":@(unchanged),
            @"source_process_stopped":@(!self.fixture),@"input_forwarding":@"not_implemented",@"physical_presentation":@"not_measured"};
        WriteJSON(result,[self.directory stringByAppendingPathComponent:@"result.json"]);
        [self recordStartup:@"stopped"];
        self.stopping=NO; self.sourceInfo=nil; self.removingDisplay=NO;
        self.startButton.enabled=YES;
        self.notice.hidden=NO;
        self.notice.stringValue=self.failure?:@"Stopped. Click Start virtual canvas to run again.";
        [self recordLaunch:self.failure?@"failed":@"stopped"];
        if(self.failure) self.status.stringValue=self.failure;
        else self.status.stringValue=[NSString stringWithFormat:@"Stopped. Temporary monitor %@ and source app closed. Report: %@",removed?@"removed":@"removal unconfirmed",self.directory];
        if(self.trial){NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);exit(passed?0:1);}
        if(self.quitWhenStopped) [NSApp replyToApplicationShouldTerminate:YES];
        else if(self.failure) {
            NSAlert *alert=[NSAlert new];
            alert.messageText=self.streamsStarted?@"The canvas stopped":@"The canvas could not start";
            alert.informativeText=self.failure;
            [alert addButtonWithTitle:@"OK"];
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:wait forMode:NSRunLoopCommonModes];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)application {
    (void)application;
    if(self.display || self.fixture || self.stopping || self.startInFlight){self.quitWhenStopped=YES;[self stop:nil];return NSTerminateLater;}
    return NSTerminateNow;
}
- (void)windowWillClose:(NSNotification *)notification {(void)notification;[NSApp terminate:nil];}
@end

int main(int argc,const char *argv[]){@autoreleasepool{
    BOOL fixture=argc==5 && strcmp(argv[1],"--fixture")==0;
    BOOL trial=argc==2 && strcmp(argv[1],"--trial")==0;
    if(argc>1 && !fixture && !trial){fprintf(stderr,"Usage: VirtualDisplayCanvas [--trial | --fixture DIRECTORY TOKEN DISPLAY_ID]\n");return 2;}
    [NSApplication sharedApplication];
    if(fixture){
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __attribute__((objc_precise_lifetime)) SourceApp *app=[SourceApp new];app.directory=@(argv[2]);app.token=@(argv[3]);app.displayID=(CGDirectDisplayID)strtoul(argv[4],NULL,10);NSApp.delegate=app;[NSApp run];
    }else{
        __attribute__((objc_precise_lifetime)) Viewer *app=[Viewer new];app.trial=trial;NSApp.delegate=app;[NSApp run];
    }
}return 0;}
