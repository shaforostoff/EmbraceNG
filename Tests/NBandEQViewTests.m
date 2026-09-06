// NBandEQViewTests -- exercises Apple's AUNBandEQ *editor* (AUNBandEQView),
// which the headless suite in NBandEQTests.m never touches.
//
// EditSystemEffectController asks the audio unit for a view controller and
// embeds whatever it hands back, so every one of these paths runs in the app
// whenever a user opens the Parametric EQ window.  The interesting cases are
// the ones where the model changes underneath a live view: a preset load, a
// band-count change, or the render thread running while sliders move.
//
// Needs a window server session -- it will not run over plain SSH.
//
// Build and run:  Tests/run-nbandeq-view-tests.sh
//
// (c) 2025 EmbraceNG contributors.  MIT License (or) 1-clause BSD License

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudioKit/CoreAudioKit.h>
#import <unistd.h>
#import <sys/wait.h>
#import "../Source/AudioUnitStateValidation.h"

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


static AudioComponentDescription NBandEQDescription(void)
{
    AudioComponentDescription acd = {0};
    acd.componentType = kAudioUnitType_Effect;
    acd.componentSubType = kAudioUnitSubType_NBandEQ;
    acd.componentManufacturer = kAudioUnitManufacturer_Apple;
    return acd;
}

static void PumpRunLoop(NSTimeInterval seconds)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

// Loads the unit's editor, exactly as EditSystemEffectController does.
static NSView *LoadEditor(AUAudioUnit *unit, NSViewController **outController)
{
    __block NSViewController *controller = nil;
    __block BOOL done = NO;

    [unit requestViewControllerWithCompletionHandler:^(AUViewControllerBase *vc) {
        controller = vc;
        done = YES;
    }];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    if (outController) *outController = controller;
    return [controller view];
}

// Hosts the view in an offscreen window so layout and drawing are real.
static NSWindow *HostView(NSView *view)
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:[view frame]
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [[window contentView] addSubview:view];
    [window layoutIfNeeded];
    return window;
}

// Forces a real draw and returns a cheap checksum of the pixels, so a test can
// tell "the view redrew and the picture changed" from "nothing happened".
static uint64_t RenderAndHash(NSView *view)
{
    [view setNeedsDisplay:YES];
    [view displayIfNeeded];

    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:[view bounds]];
    if (!rep) return 0;

    [view cacheDisplayInRect:[view bounds] toBitmapImageRep:rep];

    const unsigned char *bits = [rep bitmapData];
    if (!bits) return 0;

    NSUInteger total = [rep bytesPerRow] * [rep pixelsHigh];
    uint64_t hash = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < total; i += 97) {
        hash = (hash ^ bits[i]) * 1099511628211ULL;
    }
    return hash;
}

static void SetParameter(AUAudioUnit *unit, AudioUnitParameterID pid, AUValue value)
{
    AUParameter *p = [[unit parameterTree] parameterWithID:pid scope:kAudioUnitScope_Global element:0];
    [p setValue:value];
}


// ------------------------------------------------------------------ tests --

static void testEditorLoads(void)
{
    TEST("the EQ editor loads and draws");

    NSError *error = nil;
    AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:NBandEQDescription() error:&error];
    CHECK(unit != nil, "audio unit instantiated");
    if (!unit) return;

    CHECK([unit providesUserInterface], "unit advertises a custom editor");

    NSViewController *controller = nil;
    NSView *view = LoadEditor(unit, &controller);
    CHECK(view != nil, "editor returned a view");
    if (!view) { SKIP("no editor -- remaining view tests cannot run"); return; }

    INFO("%s in %s, %s",
         [NSStringFromClass([view class]) UTF8String],
         [NSStringFromClass([controller class]) UTF8String],
         [NSStringFromRect([view frame]) UTF8String]);

    NSWindow *window = HostView(view);
    uint64_t hash = RenderAndHash(view);
    CHECK(hash != 0, "editor renders offscreen");

    // A blank view hashes the same as a solid fill; make sure it drew content.
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:[view bounds]];
    [view cacheDisplayInRect:[view bounds] toBitmapImageRep:rep];
    const unsigned char *bits = [rep bitmapData];
    NSUInteger row = [rep bytesPerRow] * ([rep pixelsHigh] / 2);
    int transitions = 0;
    for (NSUInteger x = 1; x < [rep pixelsWide]; x++) {
        if (bits[row + x * 4] != bits[row + (x - 1) * 4]) transitions++;
    }
    CHECK(transitions > 1, "editor drew actual content (%d transitions mid-scanline)", transitions);

    [window close];
}

// Loading a preset with the editor window open, which is what
// -loadAudioPresetAtFileURL: does from the Effects window.
static void testPresetLoadWithLiveEditor(void)
{
    TEST("preset loads while the editor is open");

    NSError *error = nil;
    AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:NBandEQDescription() error:&error];
    NSView *view = LoadEditor(unit, NULL);
    if (!view) { SKIP("no editor"); return; }

    NSWindow *window = HostView(view);
    NSDictionary *baseline = [unit fullState];
    RenderAndHash(view);

    // Alternate between two well-formed presets many times.
    NSMutableDictionary *loud = [baseline mutableCopy];
    for (UInt32 b = 0; b < 8; b++) {
        SetParameter(unit, kAUNBandEQParam_Gain + b, 18.0f);
        SetParameter(unit, kAUNBandEQParam_BypassBand + b, 0);
    }
    loud = [[unit fullState] mutableCopy];

    int loads = 0;
    for (int i = 0; i < 200; i++) {
        [unit setFullState:(i % 2) ? loud : (NSMutableDictionary *)baseline];
        if (i % 20 == 0) PumpRunLoop(0.01);
        RenderAndHash(view);
        loads++;
    }

    CHECK(loads == 200, "%d preset loads with the editor open", loads);
    CHECK([unit fullState] != nil, "unit still reports state afterwards");

    [window close];
}


// The real app: audio rendering on one thread while the editor mutates
// parameters on the main thread.
static void testRenderWhileEditorLive(void)
{
    TEST("audio renders while the editor drives parameters");

    NSError *error = nil;
    AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:NBandEQDescription() error:&error];
    NSView *view = LoadEditor(unit, NULL);
    if (!view) { SKIP("no editor"); return; }

    NSWindow *window = HostView(view);

    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    [unit setMaximumFramesToRender:512];
    [[[unit inputBusses]  objectAtIndexedSubscript:0] setFormat:format error:&error];
    [[[unit outputBusses] objectAtIndexedSubscript:0] setFormat:format error:&error];

    if (![unit allocateRenderResourcesAndReturnError:&error]) {
        SKIP("allocateRenderResources failed: %s", [[error localizedDescription] UTF8String]);
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

    const UInt32 kChannels = 2, kFrames = 512;
    AudioBufferList *abl = calloc(1, sizeof(AudioBufferList) + (kChannels - 1) * sizeof(AudioBuffer));
    abl->mNumberBuffers = kChannels;
    for (UInt32 i = 0; i < kChannels; i++) {
        abl->mBuffers[i].mNumberChannels = 1;
        abl->mBuffers[i].mDataByteSize = kFrames * sizeof(float);
        abl->mBuffers[i].mData = calloc(kFrames, sizeof(float));
    }

    __block int nonFinite = 0;
    __block unsigned long slices = 0;
    __block BOOL stop = NO;

    dispatch_queue_t audio = dispatch_queue_create("render", DISPATCH_QUEUE_SERIAL);
    dispatch_async(audio, ^{
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp ts = {0};
        ts.mFlags = kAudioTimeStampSampleTimeValid;
        while (!stop) {
            ts.mSampleTime = slices * kFrames;
            for (UInt32 b = 0; b < abl->mNumberBuffers; b++) abl->mBuffers[b].mDataByteSize = kFrames * sizeof(float);
            render(&flags, &ts, kFrames, 0, abl, NULL, pull);
            const float *samples = abl->mBuffers[0].mData;
            for (UInt32 j = 0; j < kFrames; j++) if (!isfinite(samples[j])) { nonFinite++; break; }
            slices++;
        }
    });

    // Meanwhile, drive the editor the way a user would.
    for (int i = 0; i < 300; i++) {
        UInt32 band = i % 8;
        SetParameter(unit, kAUNBandEQParam_BypassBand + band, 0);
        SetParameter(unit, kAUNBandEQParam_Gain + band, (float)((i % 48) - 24));
        SetParameter(unit, kAUNBandEQParam_Frequency + band, 40.0f + (float)((i * 137) % 18000));
        if (i % 10 == 0) { PumpRunLoop(0.01); RenderAndHash(view); }
    }

    stop = YES;
    dispatch_sync(audio, ^{});

    CHECK(slices > 0, "%lu slices rendered while the editor was driven", slices);
    CHECK(nonFinite == 0, "no non-finite output during editor interaction (%d)", nonFinite);

    [unit deallocateRenderResources];
    for (UInt32 i = 0; i < kChannels; i++) free(abl->mBuffers[i].mData);
    free(abl);
    [window close];
}



// Repeatedly replacing the band count under a live editor.  Isolated because
// it is a known Apple crash: CAAppleEQGraphView recomputes its geometry from
// controls that the band-count change has already invalidated, and AppKit
// traps on the resulting rect.  Three or four changes are enough.
static int childBandCountChurn(void)
{
    NSError *error = nil;
    AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:NBandEQDescription() error:&error];
    NSView *view = LoadEditor(unit, NULL);
    if (!view) return 90;

    NSWindow *window = HostView(view);
    RenderAndHash(view);

    for (int i = 0; i < 24; i++) {
        NSMutableDictionary *state = [[unit fullState] mutableCopy];
        state[@"numberOfBands"] = @(1 + (i % 16));
        [unit setFullState:state];
        PumpRunLoop(0.01);
        RenderAndHash(view);
    }

    [window close];
    return 0;
}

// The same loop with the band count held fixed, to show that ordinary
// parameter editing under a live editor is not the problem.
static int childParameterChurn(void)
{
    NSError *error = nil;
    AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:NBandEQDescription() error:&error];
    NSView *view = LoadEditor(unit, NULL);
    if (!view) return 90;

    NSWindow *window = HostView(view);
    RenderAndHash(view);

    for (int i = 0; i < 24; i++) {
        for (UInt32 b = 0; b < 8; b++) {
            SetParameter(unit, kAUNBandEQParam_BypassBand + b, 0);
            SetParameter(unit, kAUNBandEQParam_Gain + b, (float)((i % 48) - 24));
            SetParameter(unit, kAUNBandEQParam_Frequency + b, 40.0f * powf(1.6f, (float)b));
        }
        PumpRunLoop(0.01);
        RenderAndHash(view);
    }

    [window close];
    return 0;
}

// Out-of-range values under a live editor.  Neither AUParameter nor
// AudioUnitSetParameter clamps, so a preset can put these in front of the view.
static int childHostileValues(void)
{
    NSError *error = nil;
    AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:NBandEQDescription() error:&error];
    NSView *view = LoadEditor(unit, NULL);
    if (!view) return 90;

    NSWindow *window = HostView(view);
    RenderAndHash(view);

    float values[] = { 0, -1, 1e9f, -1e9f, 22050, 96000, FLT_MAX, -FLT_MAX };
    AudioUnitParameterID bases[] = {
        kAUNBandEQParam_Frequency, kAUNBandEQParam_Gain,
        kAUNBandEQParam_Bandwidth, kAUNBandEQParam_GlobalGain,
    };

    for (size_t b = 0; b < sizeof(bases) / sizeof(bases[0]); b++) {
        for (size_t v = 0; v < sizeof(values) / sizeof(values[0]); v++) {
            SetParameter(unit, bases[b], values[v]);
            PumpRunLoop(0.01);
            RenderAndHash(view);
        }
    }

    [window close];
    return 0;
}

// The mitigation in Source/AudioUnitStateValidation.m: hold the band count at
// whatever the unit already has, so a preset cannot move it under the editor.
static int childBandCountPinned(void)
{
    NSError *error = nil;
    AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:NBandEQDescription() error:&error];
    NSView *view = LoadEditor(unit, NULL);
    if (!view) return 90;

    NSWindow *window = HostView(view);
    RenderAndHash(view);

    for (int i = 0; i < 200; i++) {
        NSMutableDictionary *state = [[unit fullState] mutableCopy];
        state[@"numberOfBands"] = @(1 + (i % 16));

        // Exactly what Effect.m does before handing state to the unit.
        NSDictionary *safe = EmbraceAudioUnitFullStateByPreservingBandCount(state, unit);
        [unit setFullState:safe];

        if (i % 10 == 0) PumpRunLoop(0.01);
        RenderAndHash(view);
    }

    UInt32 finalBands = [[[unit fullState] objectForKey:@"numberOfBands"] unsignedIntValue];
    if (finalBands < 1 || finalBands > 16) return 1;

    [window close];
    return 0;
}

// Editor teardown.  Closing the window destroys the backing layer that
// CoreAudioKit still has a deferred update queued against; releasing the unit
// removes what would have kept it alive.  Either alone is fine, together they
// crash -- which is precisely what -closeEditControllerForEffect: used to do.
static int childTeardown(BOOL closeWindow, BOOL releaseUnit)
{
    NSMutableArray *alive = [NSMutableArray array];

    for (int i = 0; i < 12; i++) @autoreleasepool {
        NSError *error = nil;
        AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:NBandEQDescription() error:&error];
        NSViewController *controller = nil;
        NSView *view = LoadEditor(unit, &controller);
        if (!view) return 90;

        NSWindow *window = HostView(view);
        RenderAndHash(view);

        [view removeFromSuperview];
        if (closeWindow) [window close]; else [window orderOut:nil];
        if (!releaseUnit) {
            [alive addObject:window];
            [alive addObject:unit];
            if (controller) [alive addObject:controller];
        }

        PumpRunLoop(0.03);
    }

    return 0;
}

static int childTeardownAppBehaviour(void) { return childTeardown(NO,  YES); }  // orderOut, as the app now does
static int childTeardownClosePlusRelease(void) { return childTeardown(YES, YES); }  // the old crashing combination

static int childPresetChurn(void)   { testPresetLoadWithLiveEditor();  return sFailCount ? 1 : 0; }
static int childRenderLive(void)    { testRenderWhileEditorLive();     return sFailCount ? 1 : 0; }

typedef struct {
    const char *name;
    int (*fn)(void);
    BOOL knownDefect;
} IsolatedTest;

static IsolatedTest sIsolated[] = {
    { "parameter edits under a live editor",             childParameterChurn,           NO  },
    { "out-of-range values under a live editor",         childHostileValues,            NO  },
    { "preset loads under a live editor",                childPresetChurn,              NO  },
    { "audio render during editor interaction",          childRenderLive,               NO  },
    { "editor teardown, orderOut + release (the app)",   childTeardownAppBehaviour,     NO  },
    { "band count pinned across 200 preset loads",       childBandCountPinned,          NO  },
    { "band-count changes under a live editor",          childBandCountChurn,           YES },
    { "editor teardown, close + release",                childTeardownClosePlusRelease, YES },
};
static const int sIsolatedCount = sizeof(sIsolated) / sizeof(sIsolated[0]);

static const char *sSelf = NULL;

static NSString *DescribeExit(int rc)
{
    if (rc == 0)   return @"ok";
    if (rc == 90)  return @"no editor";
    if (rc == 132) return @"SIGILL (AppKit trapped on the computed rect)";
    if (rc == 139) return @"SIGSEGV";
    if (rc == 134) return @"SIGABRT";
    if (rc > 128)  return [NSString stringWithFormat:@"signal %d", rc - 128];
    return [NSString stringWithFormat:@"exit %d", rc];
}

static int RunIsolated(int index)
{
    char arg[16];
    snprintf(arg, sizeof(arg), "%d", index);

    pid_t pid = fork();
    if (pid == 0) {
        // exec, never a bare fork: AppKit cannot be used in a forked child.
        execl(sSelf, sSelf, "--child", arg, (char *)NULL);
        _exit(95);
    }

    int status = 0;
    waitpid(pid, &status, 0);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return WEXITSTATUS(status);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        sSelf = argv[0];

        if (argc >= 3 && strcmp(argv[1], "--child") == 0) {
            [NSApplication sharedApplication];
            int index = atoi(argv[2]);
            if (index < 0 || index >= sIsolatedCount) _exit(96);

            int rc = sIsolated[index].fn();

            // _exit, not return: tearing down an AU view controller through
            // the normal atexit path crashes on its own and would be
            // indistinguishable from a real failure inside the test.
            fflush(stderr);
            _exit(rc);
        }

        fprintf(stderr, "AUNBandEQ editor test suite\n");

        NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
        fprintf(stderr, "macOS %ld.%ld.%ld\n",
                (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion);

        const char *guard = getenv("DYLD_INSERT_LIBRARIES");
        fprintf(stderr, "guard malloc: %s\n", (guard && strstr(guard, "libgmalloc")) ? "ON" : "off");

        if (![NSApplication sharedApplication]) {
            fprintf(stderr, "no window server session -- these tests need a GUI login\n");
            return 2;
        }

        // In-process: loading and drawing the editor at all.
        testEditorLoads();

        int knownDefects = 0;

        TEST("editor behaviour under model changes (each in its own process)");
        for (int i = 0; i < sIsolatedCount; i++) {
            int rc = RunIsolated(i);
            NSString *detail = DescribeExit(rc);

            if (sIsolated[i].knownDefect) {
                if (rc == 0) {
                    sPassCount++;
                    fprintf(stderr, "   ok   %s   [previously a known defect -- fixed?]\n", sIsolated[i].name);
                } else {
                    knownDefects++;
                    fprintf(stderr, "   XFAIL %s -> %s\n", sIsolated[i].name, [detail UTF8String]);
                }
            } else {
                CHECK(rc == 0, "%s -> %s", sIsolated[i].name, [detail UTF8String]);
            }
        }

        fprintf(stderr, "\n----------------------------------------\n");
        fprintf(stderr, "%d passed, %d failed, %d known Apple defects, %d skipped\n",
                sPassCount, sFailCount, knownDefects, sSkipCount);

        if (knownDefects) {
            fprintf(stderr,
                "\nXFAIL entries are Apple's editor defects, both mitigated in the app:\n"
                "  - changing numberOfBands with the editor open traps in AppKit, from\n"
                "    -[CAAppleEQGraphView updateGraphFrame]; three or four changes suffice.\n"
                "    Mitigated by EmbraceAudioUnitFullStateByPreservingBandCount().\n"
                "  - closing the editor window while releasing the audio unit crashes on a\n"
                "    deferred update.  Mitigated by ordering the window out instead.\n"
                "See Tests/README.md.\n");
        }

        fflush(stderr);
        _exit(sFailCount == 0 ? 0 : 1);   // same reason as the child above
    }
}
