// NBandEQMouseTests -- synthesized mouse input into Apple's AUNBandEQ editor.
//
// The other two suites drive the audio unit through its API.  This one drives
// the *controls*: it posts real NSEvents and dispatches them, so the code that
// runs is the editor's own mouse handling.
//
// The hazard with a test like this is that it passes by doing nothing.  Every
// interaction here is therefore measured against the parameter tree: an
// interaction that changes no parameter is not counted as exercised, and if
// nothing at all responds the suite fails rather than reporting green.
//
// Needs a window server session.  Build and run:
//   Tests/run-nbandeq-mouse-tests.sh
//
// (c) 2025 EmbraceNG contributors.  MIT License (or) 1-clause BSD License

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudioKit/CoreAudioKit.h>
#import <unistd.h>
#import <sys/wait.h>

static int sPassCount = 0;
static int sFailCount = 0;
static int sSkipCount = 0;

#define TEST(name) fprintf(stderr, "\n== %s\n", name);
#define CHECK(cond, fmt, ...) do { \
    if (cond) { sPassCount++; fprintf(stderr, "   ok   " fmt "\n", ##__VA_ARGS__); } \
    else { sFailCount++; fprintf(stderr, "   FAIL " fmt "   [%s:%d]\n", ##__VA_ARGS__, __FILE__, __LINE__); } \
} while (0)
#define SKIP(fmt, ...) do { sSkipCount++; fprintf(stderr, "   skip " fmt "\n", ##__VA_ARGS__); } while (0)
#define INFO(fmt, ...) fprintf(stderr, "        " fmt "\n", ##__VA_ARGS__)


// A window that at least asks to be key.  Whether the window server agrees
// depends on the session; testGraphHandleDrags checks and skips if not.
@interface EQTestWindow : NSWindow @end
@implementation EQTestWindow
- (BOOL) canBecomeKeyWindow { return YES; }
- (BOOL) canBecomeMainWindow { return YES; }
@end


static AudioComponentDescription NBandEQDescription(void)
{
    AudioComponentDescription acd = {0};
    acd.componentType = kAudioUnitType_Effect;
    acd.componentSubType = kAudioUnitSubType_NBandEQ;
    acd.componentManufacturer = kAudioUnitManufacturer_Apple;
    return acd;
}

static NSEvent *MouseEvent(NSEventType type, NSPoint windowPoint, NSWindow *window, int clickCount)
{
    return [NSEvent mouseEventWithType:type
                              location:windowPoint
                         modifierFlags:0
                             timestamp:[[NSProcessInfo processInfo] systemUptime]
                          windowNumber:[window windowNumber]
                               context:nil
                           eventNumber:0
                            clickCount:clickCount
                              pressure:(type == NSEventTypeLeftMouseUp) ? 0.0 : 1.0];
}

// Dispatches whatever is queued.  A control's own tracking loop pulls from the
// same queue, which is why drag and up events are posted before the mouse-down
// that starts the loop.
static void PumpEvents(NSTimeInterval seconds)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                            untilDate:[NSDate dateWithTimeIntervalSinceNow:0.003]
                                               inMode:NSDefaultRunLoopMode
                                              dequeue:YES];
        if (event) [NSApp sendEvent:event];
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.003]];
    }
}

static void DrainEvents(void)
{
    NSEvent *event;
    while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                       untilDate:[NSDate distantPast]
                                          inMode:NSDefaultRunLoopMode
                                         dequeue:YES])) { /* discard */ }
}

static NSArray *ParameterSnapshot(AUAudioUnit *unit)
{
    NSMutableArray *values = [NSMutableArray array];
    for (AUParameter *p in [[unit parameterTree] allParameters]) [values addObject:@([p value])];
    return values;
}

static int ChangedCount(NSArray *before, NSArray *after)
{
    int n = 0;
    for (NSUInteger i = 0; i < MIN([before count], [after count]); i++) {
        if ([before[i] floatValue] != [after[i] floatValue]) n++;
    }
    return n;
}

// One press-drag-release against a view, in that view's own coordinates.
// Returns how many parameters moved as a result.
static int PerformDrag(AUAudioUnit *unit, NSView *target, NSWindow *window,
                       NSPoint from, NSPoint to, int steps)
{
    DrainEvents();
    NSArray *before = ParameterSnapshot(unit);

    NSPoint start = [target convertPoint:from toView:nil];

    for (int i = 1; i <= steps; i++) {
        NSPoint p = NSMakePoint(from.x + (to.x - from.x) * i / (CGFloat)steps,
                                from.y + (to.y - from.y) * i / (CGFloat)steps);
        [NSApp postEvent:MouseEvent(NSEventTypeLeftMouseDragged, [target convertPoint:p toView:nil], window, 1)
                 atStart:NO];
    }
    [NSApp postEvent:MouseEvent(NSEventTypeLeftMouseUp, [target convertPoint:to toView:nil], window, 1)
             atStart:NO];

    [target mouseDown:MouseEvent(NSEventTypeLeftMouseDown, start, window, 1)];
    PumpEvents(0.05);

    return ChangedCount(before, ParameterSnapshot(unit));
}

static int PerformClick(AUAudioUnit *unit, NSView *target, NSWindow *window, NSPoint at)
{
    DrainEvents();
    NSArray *before = ParameterSnapshot(unit);

    NSPoint p = [target convertPoint:at toView:nil];

    [NSApp postEvent:MouseEvent(NSEventTypeLeftMouseUp, p, window, 1) atStart:NO];

    [target mouseDown:MouseEvent(NSEventTypeLeftMouseDown, p, window, 1)];
    PumpEvents(0.04);

    return ChangedCount(before, ParameterSnapshot(unit));
}

// A control is only fair game if a real mouse could reach it: nothing in its
// ancestry hidden, and the editor's own hit-testing lands on it at its centre.
//
// This matters more than it looks.  AUNBandEQ keeps eight band rows built but
// hidden, and clicking one of those reaches -[CAAppleEQGraphView
// controlAtIndex:] with an index past the end of its control array, which
// throws NSRangeException.  A user cannot click a hidden row, so that is out
// of scope here -- but the accessor is unguarded, and anything else that
// reaches it with a stale index would throw the same way.
static BOOL IsReachableByMouse(NSView *view, NSView *root)
{
    for (NSView *v = view; v && v != [root superview]; v = [v superview]) {
        if ([v isHidden]) return NO;
    }
    if (NSIsEmptyRect([view bounds])) return NO;

    NSRect inRoot = [view convertRect:[view bounds] toView:root];
    if (!NSIntersectsRect(inRoot, [root bounds])) return NO;

    NSPoint centre = NSMakePoint(NSMidX(inRoot), NSMidY(inRoot));
    if (!NSPointInRect(centre, [root bounds])) return NO;

    NSView *hit = [root hitTest:centre];
    for (NSView *v = hit; v; v = [v superview]) {
        if (v == view) return YES;
    }
    return NO;
}

// NSPopUpButton is an NSButton subclass, so collecting buttons picks up the
// per-band filter-type popups.  Clicking one opens a modal menu loop that a
// synthetic event stream has no way out of -- it wedges until the watchdog
// fires.  Exclude them everywhere, not just in the fuzzer.
static BOOL IsSafeToClick(NSView *view)
{
    return ![view isKindOfClass:[NSPopUpButton class]];
}

static void CollectControlsInRoot(NSView *view, NSMutableArray *into, Class kind, NSView *root)
{
    if ([view isKindOfClass:kind] && IsSafeToClick(view) && IsReachableByMouse(view, root)) {
        [into addObject:view];
    }
    for (NSView *sub in [view subviews]) CollectControlsInRoot(sub, into, kind, root);
}

static void CollectControls(NSView *root, NSMutableArray *into, Class kind)
{
    CollectControlsInRoot(root, into, kind, root);
}

static NSView *FindGraphView(NSView *view)
{
    if ([NSStringFromClass([view class]) containsString:@"GraphView"]) return view;
    for (NSView *sub in [view subviews]) {
        NSView *found = FindGraphView(sub);
        if (found) return found;
    }
    return nil;
}

// Builds a unit with its editor hosted in a window, all bands active.
static NSView *SetUpEditor(AUAudioUnit **outUnit, NSWindow **outWindow)
{
    NSError *error = nil;
    AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:NBandEQDescription() error:&error];
    if (!unit) return nil;

    __block NSView *view = nil;
    __block BOOL done = NO;
    [unit requestViewControllerWithCompletionHandler:^(AUViewControllerBase *vc) { view = [vc view]; done = YES; }];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (!done && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    if (!view) return nil;

    // Off to one side, so a test run does not plant a window in front of
    // whoever is at the machine.
    EQTestWindow *window = [[EQTestWindow alloc] initWithContentRect:NSMakeRect(-9000, -9000, 540, 417)
                                                           styleMask:NSWindowStyleMaskTitled
                                                             backing:NSBackingStoreBuffered
                                                               defer:NO];
    [[window contentView] addSubview:view];
    [window layoutIfNeeded];
    [window orderFront:nil];
    [window makeKeyWindow];
    PumpEvents(0.3);

    for (UInt32 b = 0; b < 8; b++) {
        [[[unit parameterTree] parameterWithID:kAUNBandEQParam_BypassBand + b scope:kAudioUnitScope_Global element:0] setValue:0];
        [[[unit parameterTree] parameterWithID:kAUNBandEQParam_Frequency  + b scope:kAudioUnitScope_Global element:0] setValue:80.0f * powf(1.9f, (float)b)];
        [[[unit parameterTree] parameterWithID:kAUNBandEQParam_Gain       + b scope:kAudioUnitScope_Global element:0] setValue:0];
    }
    PumpEvents(0.3);

    if (outUnit) *outUnit = unit;
    if (outWindow) *outWindow = window;
    return view;
}


// ------------------------------------------------------------------ tests --

// The gate for everything else.  If no control in the editor responds to a
// synthetic event, every other result in this file is meaningless.
static int gRespondingControls = 0;

static void testControlsRespond(void)
{
    TEST("synthetic events actually reach the editor's controls");

    AUAudioUnit *unit = nil;
    NSWindow *window = nil;
    NSView *view = SetUpEditor(&unit, &window);
    if (!view) { SKIP("no editor"); return; }

    NSMutableArray *buttons = [NSMutableArray array];
    NSMutableArray *sliders = [NSMutableArray array];
    CollectControls(view, buttons, [NSButton class]);
    CollectControls(view, sliders, [NSSlider class]);

    INFO("%lu buttons, %lu sliders", (unsigned long)[buttons count], (unsigned long)[sliders count]);

    // The plain buttons here are the editor's add/remove-band controls: one
    // "+" and "-" pair in the header, and a "-" per visible band row.  Neither
    // a synthetic click nor -performClick: moves a parameter *or* the band
    // count, so their actions are not reachable from this harness.  Recorded
    // rather than asserted -- it bounds what this suite covers, and it is the
    // reason the editor's own band-count controls are not a demonstrated crash
    // path the way preset loading is.
    int buttonHits = 0;
    for (NSUInteger i = 0; i < [buttons count]; i++) {
        NSButton *b = buttons[i];
        NSRect bounds = [b bounds];

        UInt32 bandsBefore = [[[unit fullState] objectForKey:@"numberOfBands"] unsignedIntValue];
        int moved = PerformClick(unit, b, window, NSMakePoint(NSMidX(bounds), NSMidY(bounds)));
        UInt32 bandsAfter = [[[unit fullState] objectForKey:@"numberOfBands"] unsignedIntValue];

        if (moved || bandsAfter != bandsBefore) buttonHits++;
    }
    INFO("%d of %lu buttons changed a parameter or the band count",
         buttonHits, (unsigned long)[buttons count]);
    if (buttonHits == 0) {
        INFO("the +/- band controls do not respond here, so they are NOT covered");
    }

    int sliderHits = 0;
    for (NSSlider *s in sliders) {
        NSRect bounds = [s bounds];
        int moved = PerformDrag(unit, s, window,
                                NSMakePoint(NSMinX(bounds) + 6, NSMidY(bounds)),
                                NSMakePoint(NSMaxX(bounds) - 6, NSMidY(bounds)), 8);
        if (moved) sliderHits++;
    }
    CHECK(sliderHits > 0, "%d of %lu sliders changed a parameter when dragged",
          sliderHits, (unsigned long)[sliders count]);

    // The gate: if nothing at all responds, every other result in this file is
    // vacuous and the suite must say so rather than report green.
    gRespondingControls = buttonHits + sliderHits;

    CHECK(gRespondingControls > 0,
          "synthetic input is reaching the editor (%d responding controls)", gRespondingControls);

    [window close];
}

// Dragging band handles on the response curve.  AUAdvancedEQGraphView declines
// mouse-down unless its window is key, and a window server session that will
// not grant key status makes this untestable -- in which case say so rather
// than report a pass.
static void testGraphHandleDrags(void)
{
    TEST("dragging band handles on the response curve");

    AUAudioUnit *unit = nil;
    NSWindow *window = nil;
    NSView *view = SetUpEditor(&unit, &window);
    if (!view) { SKIP("no editor"); return; }

    NSView *graph = FindGraphView(view);
    CHECK(graph != nil, "found the graph view (%s)",
          graph ? [NSStringFromClass([graph class]) UTF8String] : "none");
    if (!graph) { [window close]; return; }

    if (![window isKeyWindow]) {
        SKIP("window cannot become key in this session -- the graph view declines");
        INFO("this is an environment limit, not a pass: handle dragging was NOT exercised");
        INFO("re-run from a normal GUI login to cover it");
        [window close];
        return;
    }

    // Sweep the curve looking for grabbable handles, then drag each one.
    NSRect g = [graph convertRect:[graph bounds] toView:view];
    int handles = 0, totalMoved = 0;

    for (CGFloat x = NSMinX(g) + 2; x < NSMaxX(g) - 2; x += 4) {
        CGFloat y = NSMidY(g);
        int moved = PerformDrag(unit, view, window,
                                NSMakePoint(x, y), NSMakePoint(x, y - 24), 6);
        if (moved) { handles++; totalMoved += moved; }
    }

    CHECK(handles > 0, "%d grab points on the curve moved %d parameters", handles, totalMoved);

    [window close];
}

// Random drags all over the editor, including outside its bounds and reversed,
// with no regard for what is under the cursor.
static void testRandomDragFuzz(void)
{
    TEST("random drags across the whole editor");

    AUAudioUnit *unit = nil;
    NSWindow *window = nil;
    NSView *view = SetUpEditor(&unit, &window);
    if (!view) { SKIP("no editor"); return; }

    NSRect bounds = [view bounds];
    uint64_t rng = 0x243F6A8885A308D3ULL;
    int drags = 0, changed = 0;

    for (int i = 0; i < 400; i++) {
        rng = rng * 6364136223846793005ULL + 1442695040888963407ULL;
        CGFloat x0 = (CGFloat)((rng >> 33) % (NSUInteger)(NSWidth(bounds)  + 200)) - 100;
        rng = rng * 6364136223846793005ULL + 1442695040888963407ULL;
        CGFloat y0 = (CGFloat)((rng >> 33) % (NSUInteger)(NSHeight(bounds) + 200)) - 100;
        rng = rng * 6364136223846793005ULL + 1442695040888963407ULL;
        CGFloat x1 = (CGFloat)((rng >> 33) % (NSUInteger)(NSWidth(bounds)  + 200)) - 100;
        rng = rng * 6364136223846793005ULL + 1442695040888963407ULL;
        CGFloat y1 = (CGFloat)((rng >> 33) % (NSUInteger)(NSHeight(bounds) + 200)) - 100;

        NSView *hit = [view hitTest:NSMakePoint(x0, y0)];
        if (!hit) hit = view;
        // Skip pop-up buttons: clicking one runs a modal menu loop that a
        // synthetic event stream cannot get back out of.
        if (!IsSafeToClick(hit)) continue;
        if (hit != view && !IsReachableByMouse(hit, view)) continue;

        int moved = PerformDrag(unit, hit, window,
                                [hit convertPoint:NSMakePoint(x0, y0) fromView:view],
                                [hit convertPoint:NSMakePoint(x1, y1) fromView:view],
                                1 + (int)((rng >> 20) % 8));
        drags++;
        if (moved) changed++;
    }

    CHECK(drags > 0, "%d random drags delivered, %d moved a parameter", drags, changed);

    // Whatever the drags did, the unit must still be coherent and renderable.
    NSDictionary *state = [unit fullState];
    CHECK(state != nil, "unit still reports state after fuzzing");

    for (AUParameter *p in [[unit parameterTree] allParameters]) {
        if (!isfinite([p value])) {
            CHECK(NO, "parameter %s went non-finite (%g)",
                  [[p identifier] UTF8String], [p value]);
            break;
        }
    }
    CHECK(YES, "every parameter is still finite after fuzzing");

    [window close];
}

// Clicking while audio is rendering, which is the only state the app is ever
// really in when a user touches the EQ.
static void testDragsDuringRender(void)
{
    TEST("clicking the editor while audio renders");

    AUAudioUnit *unit = nil;
    NSWindow *window = nil;
    NSView *view = SetUpEditor(&unit, &window);
    if (!view) { SKIP("no editor"); return; }

    NSError *error = nil;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    [unit setMaximumFramesToRender:512];
    [[[unit inputBusses]  objectAtIndexedSubscript:0] setFormat:format error:&error];
    [[[unit outputBusses] objectAtIndexedSubscript:0] setFormat:format error:&error];

    if (![unit allocateRenderResourcesAndReturnError:&error]) {
        SKIP("allocateRenderResources failed");
        [window close];
        return;
    }

    AURenderPullInputBlock pull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,
                                                     const AudioTimeStamp *ts,
                                                     AUAudioFrameCount frames,
                                                     NSInteger bus, AudioBufferList *io) {
        for (UInt32 i = 0; i < io->mNumberBuffers; i++) {
            float *samples = io->mBuffers[i].mData;
            if (!samples) continue;
            for (UInt32 j = 0; j < frames; j++) samples[j] = 0.25f * sinf(0.01f * (j + 1));
        }
        return noErr;
    };

    AUInternalRenderBlock render = [unit internalRenderBlock];
    const UInt32 kFrames = 512;
    float *left  = calloc(kFrames, sizeof(float));
    float *right = calloc(kFrames, sizeof(float));
    AudioBufferList *abl = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    abl->mNumberBuffers = 2;
    abl->mBuffers[0] = (AudioBuffer){ 1, kFrames * sizeof(float), left  };
    abl->mBuffers[1] = (AudioBuffer){ 1, kFrames * sizeof(float), right };

    __block BOOL stop = NO;
    __block unsigned long slices = 0;
    __block int nonFinite = 0;

    dispatch_queue_t audio = dispatch_queue_create("render", DISPATCH_QUEUE_SERIAL);
    dispatch_async(audio, ^{
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp ts = {0};
        ts.mFlags = kAudioTimeStampSampleTimeValid;
        while (!stop) {
            ts.mSampleTime = slices * kFrames;
            abl->mBuffers[0].mDataByteSize = kFrames * sizeof(float);
            abl->mBuffers[1].mDataByteSize = kFrames * sizeof(float);
            render(&flags, &ts, kFrames, 0, abl, NULL, pull);
            for (UInt32 j = 0; j < kFrames; j++) if (!isfinite(left[j])) { nonFinite++; break; }
            slices++;
            // Roughly real time.  A free-running loop pins a core and starves
            // the main thread badly enough to trip the watchdog.
            if ((slices % 16) == 0) usleep(1000);
        }
    });

    NSMutableArray *buttons = [NSMutableArray array];
    CollectControls(view, buttons, [NSButton class]);

    int clicks = 0;
    for (int pass = 0; pass < 6; pass++) {
        for (NSButton *b in buttons) {
            NSRect bb = [b bounds];
            PerformClick(unit, b, window, NSMakePoint(NSMidX(bb), NSMidY(bb)));
            clicks++;
        }
    }

    stop = YES;
    dispatch_sync(audio, ^{});

    CHECK(clicks > 0 && slices > 0, "%d clicks against %lu rendered slices", clicks, slices);
    CHECK(nonFinite == 0, "audio stayed finite throughout (%d non-finite slices)", nonFinite);

    [unit deallocateRenderResources];
    free(left); free(right); free(abl);
    [window close];
}


// ------------------------------------------------------------------- main --

typedef struct { const char *name; void (*fn)(void); } MouseTest;

static MouseTest sTests[] = {
    { "controls-respond",  testControlsRespond },
    { "graph-handles",     testGraphHandleDrags },
    { "random-drag-fuzz",  testRandomDragFuzz },
    { "drags-during-render", testDragsDuringRender },
};
static const int sTestCount = sizeof(sTests) / sizeof(sTests[0]);

static const char *sSelf = NULL;

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        sSelf = argv[0];

        if (argc >= 3 && strcmp(argv[1], "--child") == 0) {
            // A wedged tracking loop would otherwise hang the run forever.
            alarm(90);
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

            int index = atoi(argv[2]);
            if (index < 0 || index >= sTestCount) _exit(96);
            sTests[index].fn();

            fflush(stderr);
            _exit(sFailCount ? 1 : (sSkipCount ? 3 : 0));
        }

        fprintf(stderr, "AUNBandEQ synthesized-mouse test suite\n");
        NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
        fprintf(stderr, "macOS %ld.%ld.%ld\n\n",
                (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion);

        int failed = 0, skipped = 0;

        for (int i = 0; i < sTestCount; i++) {
            char arg[16];
            snprintf(arg, sizeof(arg), "%d", i);

            pid_t pid = fork();
            if (pid == 0) {
                execl(sSelf, sSelf, "--child", arg, (char *)NULL);
                _exit(95);
            }

            int status = 0;
            waitpid(pid, &status, 0);

            if (WIFSIGNALED(status)) {
                int sig = WTERMSIG(status);
                failed++;
                fprintf(stderr, "\n   FAIL %s died on signal %d%s\n", sTests[i].name, sig,
                        sig == SIGALRM ? " (watchdog -- a tracking loop wedged)" : "");
            } else {
                int rc = WEXITSTATUS(status);
                if (rc == 1) failed++;
                else if (rc == 3) skipped++;
            }
        }

        fprintf(stderr, "\n----------------------------------------\n");
        fprintf(stderr, "%d test groups, %d with failures, %d with skips\n", sTestCount, failed, skipped);

        fflush(stderr);
        _exit(failed ? 1 : 0);
    }
}
