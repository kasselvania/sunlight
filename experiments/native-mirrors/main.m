// Developer experiment; intentionally independent of Sunlight's application bootstrap.
// API research references are in README.md. No external implementation is copied.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/runtime.h>
#import <signal.h>
#import <unistd.h>

static NSString *const LabPluginType = @"com.apple.WindowServer.CGSWindow";

static NSDictionary *LabInspection(void) {
    Class cls = NSClassFromString(@"CAPluginLayer");
    NSMutableDictionary *selectors = [NSMutableDictionary dictionary];
    for (NSString *name in @[@"setPluginType:", @"setPluginId:", @"setPluginFlags:", @"setPluginGravity:"]) {
        selectors[name] = @(cls && class_getInstanceMethod(cls, NSSelectorFromString(name)) != NULL);
    }
    return @{
        @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"mirror_class_present": @(cls != Nil),
        @"mirror_selectors": selectors,
        @"virtual_display_class_present": @(NSClassFromString(@"CGVirtualDisplay") != Nil),
        @"screen_capture_preflight": @(CGPreflightScreenCaptureAccess()),
        @"rendering_result": @"unverified",
        @"meaning": @"Class and selector availability do not establish live foreign-window rendering."
    };
}

static BOOL LabWriteJSON(NSDictionary *value, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:NULL];
}

static NSTextField *LabLabel(NSString *text, CGFloat size) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size];
    label.textColor = NSColor.labelColor;
    return label;
}

// Only this synthetic view's pixels are used as sources. A timer tick is a source
// sequence; it is never reported as a frame received or presented by a mirror.
@interface LabSourceView : NSView
@property NSUInteger sequence;
@property NSUInteger clicks;
@property NSUInteger sourceIndex;
@end

@implementation LabSourceView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)mouseDown:(NSEvent *)event { (void)event; self.clicks++; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSArray<NSColor *> *colors = @[NSColor.systemBlueColor, NSColor.systemOrangeColor, NSColor.systemGreenColor, NSColor.systemPurpleColor];
    NSColor *color = colors[self.sourceIndex % colors.count];
    [[color colorWithAlphaComponent:0.16] setFill];
    NSRectFill(self.bounds);
    for (NSUInteger x = 0; x < (NSUInteger)self.bounds.size.width; x += 16) {
        [((x / 16) % 2 ? NSColor.blackColor : NSColor.whiteColor) setFill];
        NSRectFill(NSMakeRect(x, 0, 16, 10));
        NSRectFill(NSMakeRect(x, self.bounds.size.height - 10, 16, 10));
    }
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:21 weight:NSFontWeightMedium],
                                 NSForegroundColorAttributeName: NSColor.labelColor};
    NSString *text = [NSString stringWithFormat:@"ORIGINAL %c\nSequence %06lu\nClicks %lu", (int)('A' + self.sourceIndex),
                      (unsigned long)self.sequence, (unsigned long)self.clicks];
    [text drawAtPoint:NSMakePoint(18, 26) withAttributes:attributes];
    CGFloat travel = MAX(1, self.bounds.size.width - 44);
    CGFloat x = 12 + fmod((double)self.sequence * 2, travel);
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x, self.bounds.size.height - 53, 24, 24)] fill];
}
@end

static NSWindow *LabSourceWindow(NSUInteger index, NSRect frame) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = [NSString stringWithFormat:@"ORIGINAL %c — compare with COPY %c in the canvas", (int)('A' + index), (int)('A' + index)];
    window.releasedWhenClosed = NO;
    LabSourceView *view = [[LabSourceView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    view.sourceIndex = index;
    window.contentView = view;
    // No activation or key-window request. The user starts the experiment explicitly.
    [window orderFront:nil];
    return window;
}

@interface LabFixture : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSString *directory;
@property NSString *token;
@property NSMutableArray<NSWindow *> *windows;
@property NSTimer *timer;
@property pid_t viewerPID;
@end

@implementation LabFixture
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.viewerPID = getppid();
    self.windows = [NSMutableArray array];
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    for (NSUInteger i = 0; i < 3; i++) {
        NSRect frame = NSMakeRect(screen.origin.x + 20 + i * 310, NSMaxY(screen) - 235, 290, 190);
        NSWindow *window = LabSourceWindow(i + 1, frame);
        window.delegate = self;
        [self.windows addObject:window];
    }
    [self publish];
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        // The viewer can be force-quit without getting an orderly shutdown callback.
        if (getppid() != self.viewerPID) { [NSApp terminate:nil]; return; }
        for (NSWindow *window in self.windows) {
            LabSourceView *view = (LabSourceView *)window.contentView;
            view.sequence++;
            view.needsDisplay = YES;
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)publish {
    NSMutableArray *sources = [NSMutableArray array];
    for (NSWindow *window in self.windows) {
        LabSourceView *view = (LabSourceView *)window.contentView;
        [sources addObject:@{@"id": @(window.windowNumber), @"width": @(window.frame.size.width),
                             @"height": @(window.frame.size.height), @"index": @(view.sourceIndex)}];
    }
    LabWriteJSON(@{@"pid": @(NSProcessInfo.processInfo.processIdentifier), @"token": self.token,
                   @"sources": sources}, [self.directory stringByAppendingPathComponent:@"sources.json"]);
}
- (void)windowWillClose:(NSNotification *)notification {
    [self.windows removeObject:notification.object];
    [self publish];
    if (self.windows.count == 0) [NSApp terminate:nil];
}
- (void)windowDidResize:(NSNotification *)notification { (void)notification; [self publish]; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.timer invalidate];
}
@end

static CALayer *LabMirror(CGWindowID windowID, NSString **failure) {
    Class cls = NSClassFromString(@"CAPluginLayer");
    if (!cls) {
        if (failure) *failure = @"CAPluginLayer is unavailable on this OS.";
        return nil;
    }
    @try {
        CALayer *layer = [[cls alloc] init];
        [layer setValue:LabPluginType forKey:@"pluginType"];
        [layer setValue:@(windowID) forKey:@"pluginId"];
        [layer setValue:@0 forKey:@"pluginFlags"];
        [layer setValue:kCAGravityResizeAspect forKey:@"pluginGravity"];
        layer.backgroundColor = NSColor.blackColor.CGColor;
        return layer;
    } @catch (NSException *exception) {
        if (failure) *failure = [NSString stringWithFormat:@"Live-mirror setup refused: %@", exception.name];
        return nil;
    }
}

static NSDictionary *LabWindowLookup(CGWindowID windowID, pid_t pid) {
    // Query only the window named by our own source process, never the desktop list.
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowID));
    for (NSDictionary *entry in list) {
        if ([entry[(id)kCGWindowNumber] unsignedIntValue] == windowID &&
            [entry[(id)kCGWindowOwnerPID] intValue] == pid) return @{@"status": @"owner_matched", @"id": @(windowID)};
    }
    return @{@"status": list.count == 0 ? @"window_not_listed" : @"owner_not_matched", @"id": @(windowID),
             @"returned_entries": @(list.count), @"screen_capture_preflight": @(CGPreflightScreenCaptureAccess())};
}

static BOOL LabWindowBelongsTo(CGWindowID windowID, pid_t pid) {
    return [LabWindowLookup(windowID, pid)[@"status"] isEqual:@"owner_matched"];
}

@interface LabCanvas : NSView
@property CGFloat zoom;
@property CGPoint pan;
@property NSArray<NSDictionary *> *sources;
@property NSMutableDictionary<NSNumber *, CALayer *> *mirrors;
@property NSMutableArray<CALayer *> *chrome;
@property NSMutableArray<CALayer *> *tiles;
@property NSPoint lastPoint;
@property(copy) void (^changed)(void);
- (BOOL)bindSources:(NSArray<NSDictionary *> *)sources failure:(NSString **)failure;
- (void)fit;
@end

@implementation LabCanvas
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layerUsesCoreImageFilters = NO;
        self.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:1].CGColor;
        self.layer.masksToBounds = YES;
        self.mirrors = [NSMutableDictionary dictionary];
        self.chrome = [NSMutableArray array];
        self.tiles = [NSMutableArray array];
        self.zoom = 0.9;
        self.pan = CGPointMake(32, 65);
        [self bindSources:@[] failure:NULL];
    }
    return self;
}
- (BOOL)bindSources:(NSArray<NSDictionary *> *)sources failure:(NSString **)failure {
    NSMutableDictionary *next = [NSMutableDictionary dictionary];
    for (NSDictionary *source in sources) {
        NSNumber *number = source[@"id"];
        CALayer *mirror = self.mirrors[number] ?: LabMirror(number.unsignedIntValue, failure);
        if (!mirror) return NO;
        next[number] = mirror;
    }
    for (CALayer *mirror in self.mirrors.allValues) [mirror removeFromSuperlayer];
    for (CALayer *layer in self.chrome) [layer removeFromSuperlayer];
    for (CALayer *layer in self.tiles) [layer removeFromSuperlayer];
    [self.chrome removeAllObjects];
    [self.tiles removeAllObjects];
    self.sources = sources;
    self.mirrors = next;
    for (NSUInteger index = 0; index < 4; index++) {
        NSDictionary *source = nil;
        for (NSDictionary *candidate in sources) if ([candidate[@"index"] unsignedIntegerValue] == index) source = candidate;
        CALayer *tile = [CALayer layer];
        tile.backgroundColor = [NSColor colorWithWhite:0.20 alpha:1].CGColor;
        tile.borderColor = [NSColor colorWithWhite:0.5 alpha:1].CGColor;
        tile.borderWidth = 1;
        CALayer *mirror = source ? self.mirrors[source[@"id"]] : nil;
        if (mirror) {
            [tile addSublayer:mirror];
        } else {
            CATextLayer *pending = [CATextLayer layer];
            pending.string = @"No copy connected";
            pending.fontSize = 16;
            pending.alignmentMode = kCAAlignmentCenter;
            pending.contentsScale = NSScreen.mainScreen.backingScaleFactor;
            pending.foregroundColor = NSColor.whiteColor.CGColor;
            [tile addSublayer:pending];
        }
        [self.tiles addObject:tile];
        [self.layer addSublayer:tile];
        CATextLayer *label = [CATextLayer layer];
        label.string = [NSString stringWithFormat:@"COPY %c — %@", (int)('A' + index), index == 0 ? @"same-app control" : @"separate-app original"];
        label.fontSize = 12;
        label.contentsScale = NSScreen.mainScreen.backingScaleFactor;
        label.foregroundColor = NSColor.whiteColor.CGColor;
        [self.chrome addObject:label];
        [self.layer addSublayer:label];
    }
    [self layoutMirrors];
    return YES;
}
- (void)layoutMirrors {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < self.tiles.count; i++) {
        NSDictionary *source = nil;
        for (NSDictionary *candidate in self.sources) if ([candidate[@"index"] unsignedIntegerValue] == i) source = candidate;
        // Fixed slots describe canvas placement, independent of the sources' native sizes.
        CGFloat x = (i % 2) * 350, y = (i / 2) * 265;
        CGRect frame = CGRectMake(self.pan.x + x * self.zoom, self.pan.y + y * self.zoom,
                                  (source ? [source[@"width"] doubleValue] : 290) * self.zoom,
                                  (source ? [source[@"height"] doubleValue] : 212) * self.zoom);
        CALayer *tile = self.tiles[i];
        tile.frame = frame;
        CALayer *contents = tile.sublayers.firstObject;
        if ([contents isKindOfClass:CATextLayer.class]) {
            contents.frame = CGRectMake(0, MAX(0, tile.bounds.size.height / 2 - 12), tile.bounds.size.width, 28);
        } else {
            contents.frame = tile.bounds;
        }
        self.chrome[i].frame = CGRectMake(frame.origin.x, CGRectGetMaxY(frame) + 8, frame.size.width, 20);
    }
    [CATransaction commit];
    if (self.changed) self.changed();
}
- (void)fit {
    self.zoom = MIN(1.0, MIN(MAX(0.2, (self.bounds.size.width - 64) / 700), MAX(0.2, (self.bounds.size.height - 64) / 530)));
    self.pan = CGPointMake(32, 32);
    [self layoutMirrors];
}
- (void)layout { [super layout]; [self layoutMirrors]; }
- (void)mouseDown:(NSEvent *)event { self.lastPoint = [self convertPoint:event.locationInWindow fromView:nil]; }
- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    self.pan = CGPointMake(self.pan.x + point.x - self.lastPoint.x, self.pan.y + point.y - self.lastPoint.y);
    self.lastPoint = point;
    [self layoutMirrors];
}
- (void)zoomBy:(CGFloat)factor around:(CGPoint)point {
    CGFloat next = MAX(0.2, MIN(2.0, self.zoom * factor));
    CGFloat ratio = next / self.zoom;
    self.pan = CGPointMake(point.x - (point.x - self.pan.x) * ratio, point.y - (point.y - self.pan.y) * ratio);
    self.zoom = next;
    [self layoutMirrors];
}
- (void)magnifyWithEvent:(NSEvent *)event {
    [self zoomBy:1 + event.magnification around:[self convertPoint:event.locationInWindow fromView:nil]];
}
- (void)scrollWheel:(NSEvent *)event {
    if (event.modifierFlags & (NSEventModifierFlagOption | NSEventModifierFlagCommand)) {
        [self zoomBy:exp(-event.scrollingDeltaY * 0.015) around:[self convertPoint:event.locationInWindow fromView:nil]];
    } else {
        self.pan = CGPointMake(self.pan.x - event.scrollingDeltaX, self.pan.y + event.scrollingDeltaY);
        [self layoutMirrors];
    }
}
@end

@interface LabViewer : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSWindow *window;
@property LabCanvas *canvas;
@property NSTextField *status;
@property NSTextField *zoomLabel;
@property NSTask *fixture;
@property NSWindow *control;
@property NSPanel *floating;
@property NSTimer *poll;
@property NSString *directory;
@property NSString *token;
@property NSString *lastManifest;
@property NSArray<NSDictionary *> *sources;
@property BOOL stopping;
@property NSUInteger generation;
@property CFTimeInterval nextBindingAttempt;
@property BOOL bindingComplete;
@property NSButton *recordButton;
@property NSButton *floatButton;
@property BOOL checkSetup;
@property BOOL injectedLookupFailure;
@property NSUInteger bindingAttempts;
@property BOOL retriedUnchangedManifest;
@end

@implementation LabViewer
- (NSButton *)button:(NSString *)title action:(SEL)action {
    return [NSButton buttonWithTitle:title target:self action:action];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSMenu *menu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [menu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit Native Mirror Lab" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = menu;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 100, 1000, 650)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Sunlight — originals and live copies";
    self.window.minSize = NSMakeSize(960, 520);
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    NSView *content = self.window.contentView;
    NSTextField *title = LabLabel(@"Look for four moving COPIES inside this canvas", 20);
    NSTextField *help = LabLabel(@"The small separate windows are ORIGINALS. Each box below must show its matching original’s moving number and dot.", 12);
    self.recordButton = [self button:@"Record what I see…" action:@selector(observe:)];
    self.recordButton.enabled = NO;
    self.floatButton = [self button:@"Float COPY B" action:@selector(floatMirror:)];
    self.floatButton.enabled = NO;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[
        [self button:@"Start sources" action:@selector(start:)],
        [self button:@"Stop" action:@selector(stop:)],
        [self button:@"Fit" action:@selector(fit:)],
        self.floatButton,
        self.recordButton,
        [self button:@"Allow window access…" action:@selector(requestAccess:)]
    ]];
    buttons.spacing = 8;
    self.zoomLabel = LabLabel(@"100%", 12);
    self.status = LabLabel(@"Click Start sources. Four separate originals will open. The four boxes below must become live copies; moving originals alone do not count. Drag or scroll here to pan; pinch to zoom.", 12);
    self.status.lineBreakMode = NSLineBreakByWordWrapping;
    self.status.maximumNumberOfLines = 3;
    self.canvas = [[LabCanvas alloc] initWithFrame:NSZeroRect];
    __weak LabViewer *weakSelf = self;
    self.canvas.changed = ^{
        NSString *text = [NSString stringWithFormat:@"%.0f%%", weakSelf.canvas.zoom * 100];
        if (![weakSelf.zoomLabel.stringValue isEqual:text]) weakSelf.zoomLabel.stringValue = text;
    };

    for (NSView *view in @[title, help, buttons, self.zoomLabel, self.canvas, self.status]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [help.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [help.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [buttons.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [buttons.topAnchor constraintEqualToAnchor:help.bottomAnchor constant:14],
        [self.zoomLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.zoomLabel.centerYAnchor constraintEqualToAnchor:buttons.centerYAnchor],
        [self.canvas.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [self.canvas.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.canvas.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:12],
        [self.canvas.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-12],
        [self.status.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.status.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.status.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        [self.status.heightAnchor constraintGreaterThanOrEqualToConstant:34]
    ]];
    [self.window makeKeyAndOrderFront:nil];
    if (self.checkSetup) {
        [self start:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSData *data = [NSData dataWithContentsOfFile:[self.directory stringByAppendingPathComponent:@"observation.json"]];
            NSDictionary *observation = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : @{};
            NSUInteger foreignCount = 0;
            for (NSDictionary *source in self.sources) if ([source[@"index"] intValue] != 0) foreignCount++;
            BOOL passed = [observation[@"kind"] isEqual:@"incomplete_setup"] && self.retriedUnchangedManifest && foreignCount == 3;
            NSDictionary *result = @{@"kind": @"setup_regression_check", @"passed": @(passed),
                @"initial_observation_kind": observation[@"kind"] ?: @"missing",
                @"retried_unchanged_manifest": @(self.retriedUnchangedManifest), @"binding_attempts": @(self.bindingAttempts),
                @"foreign_source_count": @(foreignCount), @"rendering_result": @"unverified"};
            NSData *output = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
            fwrite(output.bytes, 1, output.length, stdout);
            fputc('\n', stdout);
            fflush(stdout);
            [self stop:nil];
            // NSApplication's normal terminate route exits with zero. This CLI
            // check must preserve a failing result for the caller.
            exit(passed ? EXIT_SUCCESS : EXIT_FAILURE);
        });
    }
}
- (void)start:(id)sender {
    (void)sender;
    if (self.fixture || self.stopping) return;
    self.token = NSUUID.UUID.UUIDString;
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"sunlight-mirrorlab-" stringByAppendingString:self.token]];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
        self.status.stringValue = @"Could not create the private run directory.";
        return;
    }
    LabWriteJSON(LabInspection(), [self.directory stringByAppendingPathComponent:@"inspection.json"]);
    self.lastManifest = nil;
    self.bindingComplete = NO;
    self.nextBindingAttempt = 0;
    self.bindingAttempts = 0;
    self.retriedUnchangedManifest = NO;
    self.injectedLookupFailure = NO;
    self.generation++;
    NSUInteger generation = self.generation;
    NSString *parent = [NSBundle.mainBundle.bundlePath stringByDeletingLastPathComponent];
    NSString *executable = [parent stringByAppendingPathComponent:@"Native Mirror Fixture.app/Contents/MacOS/NativeMirrorLab"];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[@"--fixture", self.directory, self.token];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    self.fixture = task;
    NSString *runDirectory = self.directory;
    __weak LabViewer *weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        LabWriteJSON(@{@"termination_status": @(finished.terminationStatus), @"termination_reason": @(finished.terminationReason)},
                     [runDirectory stringByAppendingPathComponent:@"fixture-exit.json"]);
        dispatch_async(dispatch_get_main_queue(), ^{
            LabViewer *viewer = weakSelf;
            if (!viewer || viewer.generation != generation) return;
            [viewer clearMirrors];
            viewer.fixture = nil;
            viewer.stopping = NO;
            viewer.status.stringValue = [NSString stringWithFormat:@"Sources ended (status %d). Reports remain at %@", finished.terminationStatus, viewer.directory];
        });
    };
    if (![task launchAndReturnError:&error]) {
        self.fixture = nil;
        self.status.stringValue = @"Could not start the separate fixture app. Rebuild both app bundles.";
        return;
    }
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    self.control = LabSourceWindow(0, NSMakeRect(NSMaxX(screen) - 315, NSMaxY(screen) - 235, 290, 190));
    self.control.delegate = self;
    self.status.stringValue = @"Starting originals A–D. COPY A is the control; copies B, C and D must connect to the separate app.";
    self.poll = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf refreshSources];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.poll forMode:NSRunLoopCommonModes];
    [self refreshSources];
}
- (void)refreshSources {
    LabSourceView *view = (LabSourceView *)self.control.contentView;
    view.sequence++;
    view.needsDisplay = YES;
    if (!self.fixture.running || self.stopping) return;
    NSString *manifestPath = [self.directory stringByAppendingPathComponent:@"sources.json"];
    NSData *data = [NSData dataWithContentsOfFile:manifestPath];
    if (!data) return;
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"token"] isEqual:self.token] ||
        [manifest[@"pid"] intValue] != self.fixture.processIdentifier || ![manifest[@"sources"] isKindOfClass:NSArray.class]) {
        self.status.stringValue = @"Source identity did not match the process this viewer started. Stopping.";
        [self stop:nil];
        return;
    }
    NSString *manifestText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    BOOL unchanged = [manifestText isEqual:self.lastManifest];
    if (unchanged && self.bindingComplete) return;
    if (unchanged && CACurrentMediaTime() < self.nextBindingAttempt) return;
    self.nextBindingAttempt = CACurrentMediaTime() + 1;
    self.bindingAttempts++;
    if (unchanged) self.retriedUnchangedManifest = YES;
    NSMutableArray *sources = [NSMutableArray array];
    NSMutableArray *lookups = [NSMutableArray array];
    if (self.control.visible) {
        [sources addObject:@{@"id": @(self.control.windowNumber), @"width": @(self.control.frame.size.width),
                             @"height": @(self.control.frame.size.height), @"index": @0}];
    }
    for (NSDictionary *source in manifest[@"sources"]) {
        if (![source isKindOfClass:NSDictionary.class] || ![source[@"id"] isKindOfClass:NSNumber.class] ||
            ![source[@"width"] isKindOfClass:NSNumber.class] || ![source[@"height"] isKindOfClass:NSNumber.class]) {
            [lookups addObject:@{@"status": @"invalid_source_description"}];
            continue;
        }
        // The finite regression check makes the first lookup fail, then uses the
        // real window server. Normal launches never inject a failure.
        NSDictionary *lookup = self.checkSetup && !self.injectedLookupFailure
            ? @{@"status": @"injected_initial_lookup_unavailable", @"id": source[@"id"]}
            : LabWindowLookup([source[@"id"] unsignedIntValue], self.fixture.processIdentifier);
        [lookups addObject:lookup];
        if (![lookup[@"status"] isEqual:@"owner_matched"]) {
            // A source can close between publication and the query. Never bind its ID to another owner.
            continue;
        }
        [sources addObject:source];
    }
    NSString *failure = nil;
    [self.floating close];
    self.floating = nil;
    if (![self.canvas bindSources:sources failure:&failure]) {
        NSString *reason = failure ?: @"Live-mirror setup failed.";
        [self stop:nil];
        self.status.stringValue = reason;
        return;
    }
    self.sources = sources;
    self.injectedLookupFailure = YES;
    self.lastManifest = manifestText;
    NSUInteger foreignCount = 0;
    for (NSDictionary *source in sources) if ([source[@"index"] intValue] != 0) foreignCount++;
    self.bindingComplete = sources.count == 4 && foreignCount == 3;
    self.recordButton.enabled = YES;
    self.floatButton.enabled = self.bindingComplete;
    LabWriteJSON(@{@"source_count": @(sources.count), @"foreign_source_count": @(foreignCount),
        @"expected_foreign_source_count": @3, @"setup_complete": @(self.bindingComplete), @"lookups": lookups,
        @"screen_capture_preflight": @(CGPreflightScreenCaptureAccess())},
        [self.directory stringByAppendingPathComponent:@"binding.json"]);
    if (!unchanged) [self.canvas fit];
    if (self.bindingComplete) {
        self.status.stringValue = @"4 copies connected. Check INSIDE the canvas: A, B, C and D must all show moving numbers and dots, even as you drag or pinch here.";
    } else {
        self.status.stringValue = [NSString stringWithFormat:@"SETUP INCOMPLETE: %lu of 3 separate-app copies connected. Empty boxes are not successful mirrors. Screen Recording permission: %@. Missing sources will retry; no permission is requested automatically.",
            (unsigned long)foreignCount, CGPreflightScreenCaptureAccess() ? @"granted" : @"not granted"];
    }
    if (self.checkSetup && self.bindingAttempts == 1) [self observe:nil];
}
- (void)clearMirrors {
    [self.poll invalidate];
    self.poll = nil;
    [self.canvas bindSources:@[] failure:NULL];
    self.sources = @[];
    self.bindingComplete = NO;
    self.recordButton.enabled = NO;
    self.floatButton.enabled = NO;
    [self.floating close];
    self.floating = nil;
    self.control.delegate = nil;
    [self.control close];
    self.control = nil;
}
- (void)stop:(id)sender {
    (void)sender;
    self.stopping = YES;
    [self clearMirrors];
    if (self.fixture.running) {
        [self.fixture terminate];
        self.status.stringValue = @"Stopping the experiment’s source process…";
    } else {
        self.fixture = nil;
        self.stopping = NO;
        self.status.stringValue = @"Stopped. No input was forwarded or other applications moved.";
    }
}
- (void)fit:(id)sender { (void)sender; [self.canvas fit]; }
- (void)requestAccess:(id)sender {
    (void)sender;
    if (CGPreflightScreenCaptureAccess()) {
        self.lastManifest = nil;
        [self refreshSources];
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Allow this viewer to identify the separate app’s windows?";
    alert.informativeText = @"This opens macOS’s normal Screen Recording permission request. The lab still uses only its own synthetic windows. If macOS asks you to quit and reopen the viewer after granting access, do that, then click Start sources again. SIP stays enabled.";
    [alert addButtonWithTitle:@"Open macOS permission request"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            CGRequestScreenCaptureAccess();
            self.lastManifest = nil;
            [self refreshSources];
        }
    }];
}
- (void)floatMirror:(id)sender {
    (void)sender;
    if (!self.fixture.running || !self.bindingComplete) return;
    NSDictionary *source = nil;
    for (NSDictionary *candidate in self.sources) if ([candidate[@"index"] intValue] == 1) source = candidate;
    if (!source) return;
    if (!LabWindowBelongsTo([source[@"id"] unsignedIntValue], self.fixture.processIdentifier)) return;
    [self.floating close];
    NSString *failure = nil;
    CALayer *mirror = LabMirror([source[@"id"] unsignedIntValue], &failure);
    if (!mirror) { self.status.stringValue = failure; return; }
    self.floating = [[NSPanel alloc] initWithContentRect:NSMakeRect(1040, 180, 320, 240)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.floating.title = @"Live mirror — viewing only";
    self.floating.releasedWhenClosed = NO;
    self.floating.level = NSFloatingWindowLevel;
    NSView *content = self.floating.contentView;
    content.wantsLayer = YES;
    content.layerUsesCoreImageFilters = NO;
    mirror.frame = content.bounds;
    mirror.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [content.layer addSublayer:mirror];
    [self.floating orderFront:nil];
    self.status.stringValue = @"The floating mirror belongs to this app. Its native source window’s level has not changed. Input forwarding is not implemented.";
}
- (void)observe:(id)sender {
    (void)sender;
    if (!self.directory || !self.fixture.running) return;
    if (!self.bindingComplete) {
        NSString *path = [self.directory stringByAppendingPathComponent:@"observation.json"];
        NSUInteger foreignCount = 0;
        for (NSDictionary *source in self.sources) if ([source[@"index"] intValue] != 0) foreignCount++;
        LabWriteJSON(@{@"kind": @"incomplete_setup", @"observation": @"cross_app_rendering_unverified",
            @"source_count": @(self.sources.count), @"foreign_source_count": @(foreignCount),
            @"expected_foreign_source_count": @3, @"inspection": LabInspection()}, path);
        self.status.stringValue = @"Recorded an incomplete setup. The app has not connected all three separate-app originals, so there is no cross-app success result to record yet.";
        return;
    }
    NSAlert *alert = [NSAlert new];
    NSUInteger generation = self.generation;
    alert.messageText = @"What moved INSIDE the dark canvas?";
    alert.informativeText = @"Look at COPY A, COPY B, COPY C and COPY D inside this app. Each should show its original’s changing number and moving dot while you pan or zoom. Moving original windows outside this app do not count.";
    for (NSString *title in @[@"All four copies stayed live", @"Only COPY A stayed live", @"Copies blank / frozen", @"Not sure", @"Cancel"]) [alert addButtonWithTitle:title];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        NSInteger index = response - NSAlertFirstButtonReturn;
        if (index < 0 || index > 3) return;
        if (self.generation != generation || !self.fixture.running || self.stopping || !self.bindingComplete) {
            self.status.stringValue = @"The run ended before the observation was recorded.";
            return;
        }
        NSString *observation = @[@"all_four_copies_live", @"same_app_only", @"blank_or_frozen", @"inconclusive"][index];
        NSUInteger foreignCount = 0;
        for (NSDictionary *source in self.sources) if ([source[@"index"] intValue] != 0) foreignCount++;
        NSString *path = [self.directory stringByAppendingPathComponent:@"observation.json"];
        NSDictionary *record = @{@"kind": @"manual_observation", @"observation": observation,
            @"at": @([NSDate.date timeIntervalSince1970]), @"inspection": LabInspection(),
            @"source_count": @(self.sources.count), @"foreign_source_count": @(foreignCount), @"zoom": @(self.canvas.zoom),
            @"input_forwarding": @"not_implemented", @"capture_performance": @"not_measured"};
        self.status.stringValue = LabWriteJSON(record, path) ? [@"Observation saved: " stringByAppendingString:path] : @"Could not save the observation.";
    }];
}
- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.window) [NSApp terminate:nil];
    if (notification.object == self.control) {
        // Removing a source also removes any associated mirrors; no silent ID reuse.
        self.control.delegate = nil;
        self.control = nil;
        self.lastManifest = nil;
        [self refreshSources];
    }
}
- (void)windowDidResize:(NSNotification *)notification {
    if (notification.object == self.control) { self.lastManifest = nil; [self refreshSources]; }
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application { (void)application; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; [self stop:nil]; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--inspect") == 0) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:LabInspection() options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
            if (!data) return 1;
            fwrite(data.bytes, 1, data.length, stdout);
            fputc('\n', stdout);
            return 0;
        }
        BOOL fixture = argc == 4 && strcmp(argv[1], "--fixture") == 0;
        BOOL checkSetup = argc == 2 && strcmp(argv[1], "--check-setup") == 0;
        if (argc > 1 && !fixture && !checkSetup) { fprintf(stderr, "Usage: NativeMirrorLab [--inspect | --check-setup | --fixture DIRECTORY TOKEN]\n"); return 2; }
        [NSApplication sharedApplication];
        if (fixture) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            __attribute__((objc_precise_lifetime)) LabFixture *delegate = [LabFixture new];
            delegate.directory = [NSString stringWithUTF8String:argv[2]];
            delegate.token = [NSString stringWithUTF8String:argv[3]];
            NSApp.delegate = delegate;
            [NSApp run];
        } else {
            __attribute__((objc_precise_lifetime)) LabViewer *delegate = [LabViewer new];
            delegate.checkSetup = checkSetup;
            NSApp.delegate = delegate;
            [NSApp run];
        }
    }
    return 0;
}
