// (c) 2026 EmbraceNG contributors
// MIT License (or) 1-clause BSD License
//
// Checks the Apple side of the parametric EQ: that the unit registers under the
// name a saved set list stores, that EffectType finds it, that its parameter
// tree says what the core's ranges say, that rendering through the real
// AUInternalRenderBlock matches the curve the editor draws, and that its editor
// builds.
//
// The core's own maths is checked by ParaEQCoreTests, framework-free.  What is
// here is the wiring, which is where this kind of thing actually breaks.

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudioKit/CoreAudioKit.h>

#import "ParametricEQAudioUnit.h"
#import "ParametricEQView.h"
#import "EffectType.h"
#import "EffectAdditions.h"
#import "AudioUnitStateValidation.h"
#import "ParameterFormView.h"    // ParameterDescribing

#include <cmath>
#include <vector>

static int sFail = 0;
static const double kFs = 44100.0;

static void ckTrue(const char *what, BOOL ok)
{
    if (!ok) sFail++;
    printf("   %-4s %s\n", ok ? "ok" : "FAIL", what);
}

static void ckClose(const char *what, double got, double want, double tol)
{
    BOOL ok = fabs(got - want) <= tol;
    if (!ok) sFail++;
    printf("   %-4s %-52s %10.4f (want %.4f +-%.4f)\n",
           ok ? "ok" : "FAIL", what, got, want, tol);
}

static void ckEqualStrings(const char *what, NSString *got, NSString *want)
{
    BOOL ok = [got isEqualToString:want];
    if (!ok) sFail++;
    printf("   %-4s %-40s %s\n", ok ? "ok" : "FAIL", what,
           ok ? "" : [[NSString stringWithFormat:@"got \"%@\", want \"%@\"", got, want] UTF8String]);
}


static AudioComponentDescription sDescription(void)
{
    AudioComponentDescription acd = {0};

    acd.componentType         = kAudioUnitType_Effect;
    acd.componentSubType      = EmbraceParametricEQSubType;
    acd.componentManufacturer = EmbraceParametricEQManufacturer;

    return acd;
}


static void sSetValue(AUAudioUnit *unit, EmbraceParametricEQParameter address, AUValue value)
{
    [[[unit parameterTree] parameterWithAddress:(AUParameterAddress)address] setValue:value];
}


// Gain the unit actually applies at `hz`, driven through its own render block
// with a sine pulled from upstream -- the same path Embrace's graph uses.
static double sMeasuredDb(AUAudioUnit *unit, double hz)
{
    const AUAudioFrameCount kSlice = 512;
    const int kSlices = 200;
    const int kWarmSlices = 100;

    AUInternalRenderBlock render = [unit internalRenderBlock];
    if (!render) return NAN;

    std::vector<float> left(kSlice), right(kSlice);

    UInt32 listSize = sizeof(AudioBufferList) + sizeof(AudioBuffer);
    AudioBufferList *list = (AudioBufferList *)calloc(1, listSize);

    list->mNumberBuffers = 2;
    list->mBuffers[0].mNumberChannels = 1;
    list->mBuffers[1].mNumberChannels = 1;

    __block UInt64 phase = 0;

    AURenderPullInputBlock pull = ^AUAudioUnitStatus(
        AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
        AUAudioFrameCount frames, NSInteger bus, AudioBufferList *data)
    {
        for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
            float *samples = (float *)data->mBuffers[b].mData;

            for (AUAudioFrameCount i = 0; i < frames; i++) {
                samples[i] = (float)sin(2.0 * M_PI * hz * (double)(phase + i) / kFs);
            }
        }

        phase += frames;
        return noErr;
    };

    double sumIn = 0, sumOut = 0;
    AudioTimeStamp ts = {0};
    ts.mFlags = kAudioTimeStampSampleTimeValid;

    for (int slice = 0; slice < kSlices; slice++) {
        list->mBuffers[0].mData = left.data();
        list->mBuffers[1].mData = right.data();
        list->mBuffers[0].mDataByteSize = kSlice * sizeof(float);
        list->mBuffers[1].mDataByteSize = kSlice * sizeof(float);

        UInt64 sliceStart = phase;
        AudioUnitRenderActionFlags flags = 0;

        if (render(&flags, &ts, kSlice, 0, list, NULL, pull) != noErr) {
            free(list);
            return NAN;
        }

        if (slice >= kWarmSlices) {
            for (AUAudioFrameCount i = 0; i < kSlice; i++) {
                double in = sin(2.0 * M_PI * hz * (double)(sliceStart + i) / kFs);
                sumIn  += in * in;
                sumOut += (double)left[i] * left[i];
            }
        }

        ts.mSampleTime += kSlice;
    }

    free(list);

    return 10.0 * log10(sumOut / sumIn);
}


int main(int argc, const char *argv[])
{
    @autoreleasepool {
        printf("Embrace parametric EQ unit tests\n");
        printf("macOS %s\n\n", [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String]);
        printf("== registration\n");

        EmbraceRegisterParametricEQAudioUnit();

        AudioComponentDescription acd = sDescription();
        AudioComponent component = AudioComponentFindNext(NULL, &acd);
        ckTrue("component is found after registration", component != NULL);

        if (component) {
            CFStringRef cfName = NULL;
            AudioComponentCopyName(component, &cfName);
            NSString *name = CFBridgingRelease(cfName);
            ckEqualStrings("registered name", name, @"Embrace: EmbraceParametricEQ");
        }

        printf("\n== EffectType finds it under the name a set list stores\n");
        {
            EffectType *found = nil;

            for (EffectType *type in [EffectType allEffectTypes]) {
                if ([[type name] isEqualToString:EmbraceEffectParametricEQ]) found = type;
            }

            ckTrue("EffectType.allEffectTypes includes it", found != nil);
            ckEqualStrings("stored name", [found name], @"EmbraceParametricEQ");
            ckEqualStrings("manufacturer", [found manufacturer], @"Embrace");
            ckEqualStrings("menu name", [found friendlyName], @"Parametric Equalizer");
            ckTrue("not a mapped type", ![found isMapped]);
        }

        printf("\n== Apple's N-band EQ is still there, under its own name\n");
        {
            [EffectType embrace_registerMappedEffects];

            EffectType *apple = nil;

            for (EffectType *type in [EffectType allEffectTypes]) {
                if ([[type name] isEqualToString:EmbraceMappedEffectAppleParametricEQ]) apple = type;
            }

            ckTrue("AppleParametricEQ is registered", apple != nil);
            ckEqualStrings("its menu name is qualified", [apple friendlyName],
                           @"Parametric Equalizer (Apple)");
        }

        NSError *error = nil;
        AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:sDescription() error:&error];

        printf("\n== the unit instantiates\n");
        ckTrue("instantiated", unit != nil);
        ckTrue("no error", error == nil);
        if (!unit) { printf("\nFAILED early\n"); return 1; }

        printf("\n== the parameter tree agrees with the core's ranges\n");
        {
            NSArray<AUParameter *> *parameters = [[unit parameterTree] allParameters];

            ckTrue("fifteen parameters", [parameters count] == EmbraceParametricEQParameterCount);

            struct { EmbraceParametricEQParameter address; double min; double max; double def; } expected[] = {
                { EmbraceParametricEQParameterFilterFrequency, paraeq::kHpFreqMin,   paraeq::kHpFreqMax,   16   },
                { EmbraceParametricEQParameterFilterSlope,     0,                    2,                    0    },
                { EmbraceParametricEQParameterLFGain,          -paraeq::kGainMaxDb,  paraeq::kGainMaxDb,   0    },
                { EmbraceParametricEQParameterLFFrequency,     paraeq::kLfFreqMin,   paraeq::kLfFreqMax,   100  },
                { EmbraceParametricEQParameterLMFFrequency,    paraeq::kLmfFreqMin,  paraeq::kLmfFreqMax,  1000 },
                { EmbraceParametricEQParameterLMFQ,            paraeq::kQMin,        paraeq::kQMax,        1    },
                { EmbraceParametricEQParameterHMFFrequency,    paraeq::kHmfFreqMin,  paraeq::kHmfFreqMax,  5000 },
                { EmbraceParametricEQParameterHFFrequency,     paraeq::kHfFreqMin,   paraeq::kHfFreqMax,   8000 },
                { EmbraceParametricEQParameterOutputGain,      -paraeq::kOutputMaxDb, paraeq::kOutputMaxDb, 0   }
            };

            for (int i = 0; i < 9; i++) {
                AUParameter *p = [[unit parameterTree] parameterWithAddress:(AUParameterAddress)expected[i].address];

                char label[128];
                snprintf(label, sizeof(label), "%s range and default",
                         [[p displayName] UTF8String]);

                BOOL ok = p &&
                    fabs([p minValue] - expected[i].min) < 0.001 &&
                    fabs([p maxValue] - expected[i].max) < 0.001 &&
                    fabs([p value]    - expected[i].def) < 0.001;

                ckTrue(label, ok);
            }

            AUParameter *slope = [[unit parameterTree]
                parameterWithAddress:EmbraceParametricEQParameterFilterSlope];
            ckTrue("slope is indexed with three names",
                   [slope unit] == kAudioUnitParameterUnit_Indexed &&
                   [[slope valueStrings] count] == 3);

            AUParameter *shape = [[unit parameterTree]
                parameterWithAddress:EmbraceParametricEQParameterHFBell];
            ckTrue("HF shape names its two positions",
                   [[shape valueStrings] count] == 2 &&
                   [[[shape valueStrings] firstObject] isEqualToString:@"Shelf"]);

            // The whole reason this unit exists: the layout is fixed, so there
            // is no band count for a preset to move underneath an editor and
            // the AUNBandEQ trap has no analogue here.  What that means
            // concretely is that no address past the last one resolves.
            BOOL nothingBeyond = YES;

            for (int i = EmbraceParametricEQParameterCount; i < 64; i++) {
                if ([[unit parameterTree] parameterWithAddress:(AUParameterAddress)i]) {
                    nothingBeyond = NO;
                }
            }

            ckTrue("no parameter exists past the fixed layout", nothingBeyond);
        }

        printf("\n== defaults are flat, and the render path proves it\n");
        {
            AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kFs channels:2];
            [[[unit inputBusses]  objectAtIndexedSubscript:0] setFormat:format error:nil];
            [[[unit outputBusses] objectAtIndexedSubscript:0] setFormat:format error:nil];
            [unit setMaximumFramesToRender:512];

            NSError *allocError = nil;
            ckTrue("render resources allocate", [unit allocateRenderResourcesAndReturnError:&allocError]);

            double worst = 0;
            const double probes[] = { 50, 200, 1000, 5000, 12000 };

            for (int i = 0; i < 5; i++) {
                worst = fmax(worst, fabs(sMeasuredDb(unit, probes[i])));
            }

            ckClose("flat at five frequencies", worst, 0.0, 0.01);
        }

        printf("\n== what it renders matches the curve the editor draws\n");
        {
            sSetValue(unit, EmbraceParametricEQParameterFilterSlope,     2);
            sSetValue(unit, EmbraceParametricEQParameterFilterFrequency, 60);
            sSetValue(unit, EmbraceParametricEQParameterLFGain,          5);
            sSetValue(unit, EmbraceParametricEQParameterLMFGain,        -8);
            sSetValue(unit, EmbraceParametricEQParameterLMFQ,            2);
            sSetValue(unit, EmbraceParametricEQParameterHMFGain,         4);
            sSetValue(unit, EmbraceParametricEQParameterHFGain,        -10);
            sSetValue(unit, EmbraceParametricEQParameterOutputGain,      2);

            paraeq::Params params = EmbraceParametricEQParamsFromTree([unit parameterTree]);
            paraeq::Config config;
            config.compute(params, kFs);

            const double probes[] = { 40, 60, 100, 250, 1000, 2000, 5000, 8000, 12000 };

            for (int i = 0; i < 9; i++) {
                char label[96];
                snprintf(label, sizeof(label), "rendered vs drawn at %.0f Hz", probes[i]);
                ckClose(label, sMeasuredDb(unit, probes[i]),
                        paraeq::magnitudeDb(config, probes[i]), 0.08);
            }
        }

        printf("\n== bypass takes the curve to flat\n");
        {
            [unit setShouldBypassEffect:YES];

            double worst = 0;
            const double probes[] = { 50, 200, 1000, 5000, 12000 };

            for (int i = 0; i < 5; i++) {
                worst = fmax(worst, fabs(sMeasuredDb(unit, probes[i])));
            }

            ckClose("flat while bypassed", worst, 0.0, 0.01);
            [unit setShouldBypassEffect:NO];
        }

        printf("\n== control writes racing the render thread\n");
        {
            // The claim being tested is that update() may run on the render
            // thread: it reads fifteen relaxed atomics, designs coefficients
            // and calls retune(), which allocates nothing and cannot fail.  A
            // soak is the only way to find out.
            __block BOOL   writing  = YES;
            __block UInt64 writes   = 0;

            dispatch_queue_t queue = dispatch_queue_create("paraeq.writer", DISPATCH_QUEUE_SERIAL);

            dispatch_async(queue, ^{
                unsigned seed = 12345;

                while (writing) {
                    for (int i = 0; i < 64; i++) {
                        seed = (seed * 1103515245u) + 12345u;

                        int address = (int)((seed >> 16) % EmbraceParametricEQParameterCount);
                        AUParameter *p = [[unit parameterTree]
                            parameterWithAddress:(AUParameterAddress)address];

                        double t = (double)((seed >> 8) & 0xFFFF) / 65535.0;
                        [p setValue:(AUValue)([p minValue] + (t * ([p maxValue] - [p minValue])))];

                        writes++;
                    }
                }
            });

            double worst = 0;
            BOOL   finite = YES;

            for (int round = 0; round < 60; round++) {
                double db = sMeasuredDb(unit, 1000);

                if (!isfinite(db)) finite = NO;
                worst = fmax(worst, fabs(db));
            }

            writing = NO;
            dispatch_sync(queue, ^{ });

            printf("        %llu parameter writes across 60 render passes\n", writes);

            ckTrue("no render pass failed or went non-finite", finite);

            // Gains are being thrown around within +-20 dB on four bands plus
            // the trim, so the worst case is bounded but not small.  What would
            // show a defect is an unbounded one.
            ckTrue("output stays inside what the ranges allow", worst < 120.0);

            [unit reset];

            for (int i = 0; i < EmbraceParametricEQParameterCount; i++) {
                AUParameter *p = [[unit parameterTree] parameterWithAddress:(AUParameterAddress)i];
                [p setValue:[(id<ParameterDescribing>)unit
                    embrace_defaultValueForParameterAddress:(AUParameterAddress)i]];
            }

            ckClose("and it is flat again once the controls are put back",
                    sMeasuredDb(unit, 1000), 0.0, 0.01);
        }

        printf("\n== a preset round-trips, and passes the app's own screening\n");
        {
            NSDictionary *saved = [unit fullState];
            ckTrue("fullState is a dictionary with content", [saved count] > 0);

            ckTrue("passes EmbraceAudioUnitFullStateIsWellFormed",
                   EmbraceAudioUnitFullStateIsWellFormed(saved, [unit componentDescription]));

            ckTrue("band-count preservation leaves ours alone",
                   EmbraceAudioUnitFullStateByPreservingBandCount(saved, unit) == saved);

            AUAudioUnit *other = [[AUAudioUnit alloc]
                initWithComponentDescription:sDescription() error:nil];

            [other setFullState:saved];

            BOOL allMatch = YES;

            for (int i = 0; i < EmbraceParametricEQParameterCount; i++) {
                AUValue mine  = [[[unit  parameterTree] parameterWithAddress:i] value];
                AUValue theirs = [[[other parameterTree] parameterWithAddress:i] value];

                if (fabs(mine - theirs) > 0.001) {
                    printf("        parameter %d: %.4f vs %.4f\n", i, mine, theirs);
                    allMatch = NO;
                }
            }

            ckTrue("every parameter survives the round trip", allMatch);
        }

        printf("\n== the editor builds\n");
        {
            ckTrue("unit says it provides a UI", [unit providesUserInterface]);

            __block NSViewController *viewController = nil;

            [unit requestViewControllerWithCompletionHandler:^(AUViewControllerBase *vc) {
                viewController = vc;
            }];

            ckTrue("a view controller comes back", viewController != nil);

            NSView *view = [viewController view];
            ckTrue("with a view", view != nil);
            ckTrue("of a usable size", view && [view frame].size.width > 600 &&
                                               [view frame].size.height > 200);
            ckTrue("which is our own class", [view isKindOfClass:[ParametricEQView class]]);

            // Twelve knobs, three labels each, six section titles, three
            // switches: what matters is that every parameter got a control, so
            // count the controls that can be driven.
            NSInteger controls = 0;

            for (NSView *subview in [view subviews]) {
                if ([subview isKindOfClass:[NSControl class]] &&
                    ![subview isKindOfClass:[NSTextField class]])
                {
                    controls++;
                }
            }

            ckTrue("fifteen driveable controls, one per parameter", controls == 15);

            // Eyeballing a segmented control's selection from a screenshot is a
            // way to get this wrong, so ask it.
            sSetValue(unit, EmbraceParametricEQParameterLFBell,      0);
            sSetValue(unit, EmbraceParametricEQParameterHFBell,      1);
            sSetValue(unit, EmbraceParametricEQParameterFilterSlope, 2);

            [(ParametricEQView *)view reloadData];

            NSMutableDictionary *selected = [NSMutableDictionary dictionary];

            for (NSView *subview in [view subviews]) {
                if ([subview isKindOfClass:[NSSegmentedControl class]]) {
                    NSSegmentedControl *control = (NSSegmentedControl *)subview;
                    selected[@([control tag])] = @([control selectedSegment]);
                }
            }

            ckTrue("three switches", [selected count] == 3);
            ckTrue("LF shape follows its parameter (Shelf)",
                   [selected[@(EmbraceParametricEQParameterLFBell)] integerValue] == 0);
            ckTrue("HF shape follows its parameter (Bell)",
                   [selected[@(EmbraceParametricEQParameterHFBell)] integerValue] == 1);
            ckTrue("filter slope follows its parameter (24 dB/oct)",
                   [selected[@(EmbraceParametricEQParameterFilterSlope)] integerValue] == 2);

            // Every segment has to say something, or the control is a row of
            // blank buttons -- which is what happened when the section was one
            // column wide and three segments had 17 points each.
            BOOL allLabelled = YES;

            for (NSView *subview in [view subviews]) {
                if (![subview isKindOfClass:[NSSegmentedControl class]]) continue;

                NSSegmentedControl *control = (NSSegmentedControl *)subview;

                for (NSInteger segment = 0; segment < [control segmentCount]; segment++) {
                    NSString *label = [control labelForSegment:segment];
                    CGFloat   width = [control widthForSegment:segment];

                    CGSize needed = [label sizeWithAttributes:@{
                        NSFontAttributeName: [control font] ?: [NSFont systemFontOfSize:9]
                    }];

                    if (![label length] || needed.width > width - 4) {
                        printf("        \"%s\" needs %.0fpt, has %.0fpt\n",
                               [label UTF8String], needed.width, width);
                        allLabelled = NO;
                    }
                }
            }

            ckTrue("every segment label fits in its segment", allLabelled);

            sSetValue(unit, EmbraceParametricEQParameterFilterSlope, 2);
            [(ParametricEQView *)view reloadData];

            // Drawing is where a bad frame or a nil colour shows up, and it is
            // the one thing a headless run can still exercise.  Both
            // appearances, because every colour here is a semantic one and the
            // only way to know they all resolve is to resolve them.
            //
            // The PNGs are written out rather than thrown away: looking at the
            // layout is otherwise the one part of this that cannot be checked
            // without a person, and a file is easier to come by than a running
            // app.
            NSString *directory = NSTemporaryDirectory();

            for (NSString *appearanceName in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
                [view setAppearance:[NSAppearance appearanceNamed:appearanceName]];

                NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:[view bounds]];

                char label[128];
                snprintf(label, sizeof(label), "draws in %s", [appearanceName UTF8String]);

                if (!rep) {
                    ckTrue(label, NO);
                    continue;
                }

                [view cacheDisplayInRect:[view bounds] toBitmapImageRep:rep];

                NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];

                NSString *path = [directory stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"paraeq-editor-%@.png", appearanceName]];

                BOOL wrote = [png writeToFile:path atomically:YES];
                ckTrue(label, wrote && [png length] > 0);

                if (wrote) printf("        %s\n", [path UTF8String]);
            }

            // Reachable, not just implemented: this is the only route to it,
            // since the shared editor window has no Flatten toolbar item.
            NSMenu *menu = [view menu];
            NSMenuItem *flattenItem = [menu numberOfItems] > 0 ? [menu itemAtIndex:0] : nil;

            ckTrue("the view offers Flatten in a context menu",
                   flattenItem != nil &&
                   [flattenItem action] == @selector(flatten) &&
                   [flattenItem target] == view);

            if (flattenItem) {
                [NSApp sendAction:[flattenItem action] to:[flattenItem target] from:flattenItem];
            }

            BOOL flat = YES;
            AUParameterAddress gains[] = {
                EmbraceParametricEQParameterLFGain,
                EmbraceParametricEQParameterLMFGain,
                EmbraceParametricEQParameterHMFGain,
                EmbraceParametricEQParameterHFGain,
                EmbraceParametricEQParameterOutputGain
            };

            for (int i = 0; i < 5; i++) {
                if (fabs([[[unit parameterTree] parameterWithAddress:gains[i]] value]) > 0.001) flat = NO;
            }

            ckTrue("flatten zeroes the gains", flat);

            ckClose("and the frequencies are left alone",
                    [[[unit parameterTree] parameterWithAddress:
                        EmbraceParametricEQParameterLMFFrequency] value], 1000, 0.001);
        }

        printf("\n%s  (%d failures)\n", sFail ? "FAILED" : "all checks passed", sFail);
    }

    return sFail ? 1 : 0;
}
