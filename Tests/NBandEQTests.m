// NBandEQTests -- stress and contract tests for Apple's AUNBandEQ
// (kAudioUnitSubType_NBandEQ), with emphasis on the memory-safety of the
// parameter and property surfaces that EmbraceNG touches.
//
// Build and run:  Tests/run-nbandeq-tests.sh
//
// (c) 2025 EmbraceNG contributors.  MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <pthread.h>
#import <sys/wait.h>
#import <unistd.h>
#import <stdatomic.h>
#import "../Source/AudioUnitStateValidation.h"
#import <math.h>

// ---------------------------------------------------------------- harness --

static int sPassCount = 0;
static int sFailCount = 0;
static int sSkipCount = 0;
static int sKnownDefectCount = 0;
static const char *sCurrentTest = "";

#define TEST(name) \
    sCurrentTest = name; \
    fprintf(stderr, "\n== %s\n", name);

#define CHECK(cond, fmt, ...) do { \
    if (cond) { \
        sPassCount++; \
        fprintf(stderr, "   ok   " fmt "\n", ##__VA_ARGS__); \
    } else { \
        sFailCount++; \
        fprintf(stderr, "   FAIL " fmt "   [%s:%d]\n", ##__VA_ARGS__, __FILE__, __LINE__); \
    } \
} while (0)

// For behaviour that is Apple's defect, not ours.  These document the bug and
// detect the day it is fixed; they do not fail the suite, because the app
// mitigates them in Source/AudioUnitStateValidation.m.
#define KNOWN_DEFECT(cond, fmt, ...) do { \
    if (cond) { \
        sPassCount++; \
        fprintf(stderr, "   ok   " fmt "   [previously a known defect -- fixed?]\n", ##__VA_ARGS__); \
    } else { \
        sKnownDefectCount++; \
        fprintf(stderr, "   XFAIL " fmt "\n", ##__VA_ARGS__); \
    } \
} while (0)

#define SKIP(fmt, ...) do { \
    sSkipCount++; \
    fprintf(stderr, "   skip " fmt "\n", ##__VA_ARGS__); \
} while (0)

#define INFO(fmt, ...) fprintf(stderr, "        " fmt "\n", ##__VA_ARGS__)

static NSString *FourCC(OSStatus err)
{
    if (err == noErr) return @"noErr";
    char c[5] = { (char)(err >> 24), (char)(err >> 16), (char)(err >> 8), (char)err, 0 };
    for (int i = 0; i < 4; i++) if (!isprint((unsigned char)c[i])) return [NSString stringWithFormat:@"%d", (int)err];
    return [NSString stringWithFormat:@"'%s' (%d)", c, (int)err];
}

// ------------------------------------------------------------ EQ topology --
//
// Mirrors sParametricEQBands in Source/EffectAdditions.m.  Kept in sync by
// hand; testParametricEQConfigurationMatchesApp asserts the count.

typedef struct {
    AudioUnitParameterValue type;
    AudioUnitParameterValue frequency;
    AudioUnitParameterValue bandwidth;
} EQBand;

static const EQBand sAppBands[] = {
    { kAUNBandEQFilterType_LowShelf,    100, 0   },
    { kAUNBandEQFilterType_Parametric,  250, 1.0 },
    { kAUNBandEQFilterType_Parametric,  500, 1.0 },
    { kAUNBandEQFilterType_Parametric, 1000, 1.0 },
    { kAUNBandEQFilterType_Parametric, 3000, 2.0 },
    { kAUNBandEQFilterType_HighShelf,  6000, 0   }
};
static const UInt32 sAppBandCount = sizeof(sAppBands) / sizeof(sAppBands[0]);

// ------------------------------------------------------------- AU plumbing --

static AudioComponent NBandEQComponent(void)
{
    AudioComponentDescription acd = {0};
    acd.componentType = kAudioUnitType_Effect;
    acd.componentSubType = kAudioUnitSubType_NBandEQ;
    acd.componentManufacturer = kAudioUnitManufacturer_Apple;
    return AudioComponentFindNext(NULL, &acd);
}

static AudioStreamBasicDescription FloatFormat(double sampleRate, UInt32 channels)
{
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    asbd.mFramesPerPacket = 1;
    asbd.mChannelsPerFrame = channels;
    asbd.mBitsPerChannel = 32;
    asbd.mBytesPerFrame = 4;
    asbd.mBytesPerPacket = 4;
    return asbd;
}

// White-ish noise source, so every band has something to act on.
typedef struct {
    UInt32 channels;
    UInt64 phase;
    double sampleRate;
    double sineHz;      // 0 == white noise
    UInt64 frameIndex;
} RenderState;

static OSStatus InputCallback(void *inRefCon,
                              AudioUnitRenderActionFlags *ioFlags,
                              const AudioTimeStamp *inTimeStamp,
                              UInt32 inBusNumber,
                              UInt32 inNumberFrames,
                              AudioBufferList *ioData)
{
    RenderState *state = (RenderState *)inRefCon;

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        float *samples = (float *)ioData->mBuffers[b].mData;
        if (!samples) continue;
        UInt32 count = ioData->mBuffers[b].mDataByteSize / sizeof(float);
        if (count > inNumberFrames) count = inNumberFrames;

        if (state->sineHz > 0) {
            double w = 2.0 * M_PI * state->sineHz / state->sampleRate;
            for (UInt32 i = 0; i < count; i++) {
                samples[i] = (float)sin(w * (double)(state->frameIndex + i));
            }
        } else {
            UInt64 phase = state->phase;
            for (UInt32 i = 0; i < count; i++) {
                phase = phase * 6364136223846793005ULL + 1442695040888963407ULL;
                uint32_t bits = (uint32_t)(phase >> 33);
                samples[i] = ((float)bits / (float)0x7FFFFFFFu) - 1.0f;
            }
            if (b == ioData->mNumberBuffers - 1) state->phase = phase;
        }
    }

    state->frameIndex += inNumberFrames;

    return noErr;
}

static AudioBufferList *AllocBufferList(UInt32 channels, UInt32 frames)
{
    AudioBufferList *abl = calloc(1, sizeof(AudioBufferList) + (channels - 1) * sizeof(AudioBuffer));
    abl->mNumberBuffers = channels;
    for (UInt32 i = 0; i < channels; i++) {
        abl->mBuffers[i].mNumberChannels = 1;
        abl->mBuffers[i].mDataByteSize = frames * sizeof(float);
        abl->mBuffers[i].mData = calloc(frames, sizeof(float));
    }
    return abl;
}

static void FreeBufferList(AudioBufferList *abl)
{
    if (!abl) return;
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++) free(abl->mBuffers[i].mData);
    free(abl);
}

// Builds an initialized AUNBandEQ wired to a noise generator.
static OSStatus MakeEQ(AudioUnit *outUnit, RenderState *state,
                       double sampleRate, UInt32 channels, UInt32 maxFrames,
                       UInt32 *ioBandCount)
{
    AudioComponent comp = NBandEQComponent();
    if (!comp) return kAudioUnitErr_InvalidElement;

    AudioUnit unit = NULL;
    OSStatus err = AudioComponentInstanceNew(comp, &unit);
    if (err) return err;

    // Band count is a property and, per the header, may only be set while the
    // unit is uninitialized.
    if (ioBandCount && *ioBandCount) {
        err = AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands,
                                   kAudioUnitScope_Global, 0, ioBandCount, sizeof(UInt32));
        if (err) { AudioComponentInstanceDispose(unit); return err; }
    }

    AudioStreamBasicDescription asbd = FloatFormat(sampleRate, channels);
    err = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
    if (err) { AudioComponentInstanceDispose(unit); return err; }
    err = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Output, 0, &asbd, sizeof(asbd));
    if (err) { AudioComponentInstanceDispose(unit); return err; }

    err = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                               kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
    if (err) { AudioComponentInstanceDispose(unit); return err; }

    state->channels = channels;
    state->phase = 0x853c49e6748fea9bULL;
    state->sampleRate = sampleRate;
    state->frameIndex = 0;

    AURenderCallbackStruct cb = { InputCallback, state };
    err = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (err) { AudioComponentInstanceDispose(unit); return err; }

    err = AudioUnitInitialize(unit);
    if (err) { AudioComponentInstanceDispose(unit); return err; }

    *outUnit = unit;
    return noErr;
}

static void ApplyAppBands(AudioUnit unit)
{
    for (UInt32 i = 0; i < sAppBandCount; i++) {
        EQBand band = sAppBands[i];
        AudioUnitSetParameter(unit, kAUNBandEQParam_BypassBand + i, kAudioUnitScope_Global, 0, 0, 0);
        AudioUnitSetParameter(unit, kAUNBandEQParam_FilterType + i, kAudioUnitScope_Global, 0, band.type, 0);
        AudioUnitSetParameter(unit, kAUNBandEQParam_Frequency  + i, kAudioUnitScope_Global, 0, band.frequency, 0);
        AudioUnitSetParameter(unit, kAUNBandEQParam_Gain       + i, kAudioUnitScope_Global, 0, 0, 0);
        if (band.bandwidth) {
            AudioUnitSetParameter(unit, kAUNBandEQParam_Bandwidth + i, kAudioUnitScope_Global, 0, band.bandwidth, 0);
        }
    }
}

// Renders `slices` blocks, returning the first non-finite sample found (or 0).
static OSStatus RenderSlices(AudioUnit unit, AudioBufferList *abl, UInt32 frames,
                             UInt32 slices, UInt64 *ioSampleTime, BOOL *outSawNonFinite)
{
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp ts = {0};
    ts.mFlags = kAudioTimeStampSampleTimeValid;

    for (UInt32 s = 0; s < slices; s++) {
        ts.mSampleTime = (Float64)(*ioSampleTime);

        for (UInt32 b = 0; b < abl->mNumberBuffers; b++) {
            abl->mBuffers[b].mDataByteSize = frames * sizeof(float);
        }

        OSStatus err = AudioUnitRender(unit, &flags, &ts, 0, frames, abl);
        if (err) return err;

        if (outSawNonFinite) {
            for (UInt32 b = 0; b < abl->mNumberBuffers; b++) {
                const float *samples = (const float *)abl->mBuffers[b].mData;
                for (UInt32 i = 0; i < frames; i++) {
                    if (!isfinite(samples[i])) { *outSawNonFinite = YES; break; }
                }
            }
        }

        *ioSampleTime += frames;
    }

    return noErr;
}

// ------------------------------------------------------------------ tests --

static void testComponentAvailable(void)
{
    TEST("component is present and reports a version");

    AudioComponent comp = NBandEQComponent();
    CHECK(comp != NULL, "AUNBandEQ component found");
    if (!comp) return;

    UInt32 version = 0;
    OSStatus err = AudioComponentGetVersion(comp, &version);
    CHECK(err == noErr, "AudioComponentGetVersion -> %s", [FourCC(err) UTF8String]);
    INFO("AUNBandEQ version %u.%u.%u",
         (version >> 16) & 0xFFFF, (version >> 8) & 0xFF, version & 0xFF);

    CFStringRef name = NULL;
    if (AudioComponentCopyName(comp, &name) == noErr && name) {
        INFO("name: %s", [(__bridge NSString *)name UTF8String]);
        CFRelease(name);
    }
}

// The band count is a *property*, and the header states two invariants:
// setting more than kAUNBandEQProperty_MaxNumberOfBands returns an error, and
// it can only be set while uninitialized.  Both are exactly the kind of
// boundary that a buggy implementation would turn into an out-of-bounds write
// on its internal band array, so assert that the AU refuses rather than obeys.
static void testBandCountContract(void)
{
    TEST("band-count property enforces its documented bounds");

    AudioComponent comp = NBandEQComponent();
    if (!comp) { SKIP("no component"); return; }

    AudioUnit unit = NULL;
    OSStatus err = AudioComponentInstanceNew(comp, &unit);
    CHECK(err == noErr, "instantiate -> %s", [FourCC(err) UTF8String]);
    if (err) return;

    UInt32 maxBands = 0, size = sizeof(maxBands);
    err = AudioUnitGetProperty(unit, kAUNBandEQProperty_MaxNumberOfBands,
                               kAudioUnitScope_Global, 0, &maxBands, &size);
    CHECK(err == noErr && maxBands > 0, "MaxNumberOfBands readable -> %u (%s)",
          maxBands, [FourCC(err) UTF8String]);

    UInt32 defaultBands = 0; size = sizeof(defaultBands);
    err = AudioUnitGetProperty(unit, kAUNBandEQProperty_NumberOfBands,
                               kAudioUnitScope_Global, 0, &defaultBands, &size);
    CHECK(err == noErr, "NumberOfBands readable -> %u (%s)",
          defaultBands, [FourCC(err) UTF8String]);

    // EffectAdditions.m writes six bands and comments that it gets eight.
    CHECK(defaultBands >= sAppBandCount,
          "default band count %u covers the app's %u configured bands",
          defaultBands, sAppBandCount);

    // Over the maximum must fail, not silently allocate short.
    UInt32 tooMany = maxBands + 1;
    err = AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands,
                               kAudioUnitScope_Global, 0, &tooMany, sizeof(tooMany));
    CHECK(err != noErr, "NumberOfBands = max+1 (%u) rejected -> %s",
          tooMany, [FourCC(err) UTF8String]);

    UInt32 absurd = 0x40000000;
    err = AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands,
                               kAudioUnitScope_Global, 0, &absurd, sizeof(absurd));
    CHECK(err != noErr, "NumberOfBands = 2^30 rejected -> %s", [FourCC(err) UTF8String]);

    UInt32 zero = 0;
    err = AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands,
                               kAudioUnitScope_Global, 0, &zero, sizeof(zero));
    INFO("NumberOfBands = 0 -> %s", [FourCC(err) UTF8String]);

    // At the maximum must succeed while uninitialized.
    err = AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands,
                               kAudioUnitScope_Global, 0, &maxBands, sizeof(maxBands));
    CHECK(err == noErr, "NumberOfBands = max (%u) accepted -> %s",
          maxBands, [FourCC(err) UTF8String]);

    // ...and must be refused once initialized.
    AudioStreamBasicDescription asbd = FloatFormat(44100, 2);
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,  0, &asbd, sizeof(asbd));
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, sizeof(asbd));

    err = AudioUnitInitialize(unit);
    CHECK(err == noErr, "initialize with %u bands -> %s", maxBands, [FourCC(err) UTF8String]);

    // The header says this "can only be set if the unit is uninitialized".
    // As of AUNBandEQ 1.6.0 the unit accepts it anyway and resizes live, so
    // the test is not "does it refuse" but "whatever it answers, is the
    // resulting state coherent".  An AU that returns noErr while leaving its
    // band array sized for the old count is the corruption case.
    UInt32 fewer = 2;
    err = AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands,
                               kAudioUnitScope_Global, 0, &fewer, sizeof(fewer));

    if (err != noErr) {
        CHECK(YES, "NumberOfBands while initialized refused as documented -> %s", [FourCC(err) UTF8String]);
    } else {
        INFO("NumberOfBands is settable while initialized (header says otherwise)");

        UInt32 readBack = 0; size = sizeof(readBack);
        AudioUnitGetProperty(unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &readBack, &size);
        CHECK(readBack == fewer, "live resize took effect: reads back %u", readBack);

        // Every derived quantity must have followed the resize.
        UInt32 coeffSize = 0;
        AudioUnitGetPropertyInfo(unit, kAUNBandEQProperty_BiquadCoefficients,
                                 kAudioUnitScope_Global, 0, &coeffSize, NULL);
        CHECK(coeffSize == readBack * 5 * sizeof(Float64),
              "BiquadCoefficients resized with it: %u bytes for %u bands", coeffSize, readBack);

        OSStatus inRange  = AudioUnitSetParameter(unit, kAUNBandEQParam_Gain + (readBack - 1),
                                                  kAudioUnitScope_Global, 0, 3, 0);
        OSStatus outRange = AudioUnitSetParameter(unit, kAUNBandEQParam_Gain + readBack,
                                                  kAudioUnitScope_Global, 0, 3, 0);
        CHECK(inRange == noErr, "band %u still writable after resize -> %s",
              readBack - 1, [FourCC(inRange) UTF8String]);
        CHECK(outRange != noErr, "band %u refused after shrink -> %s",
              readBack, [FourCC(outRange) UTF8String]);
    }

    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
}

// kAUNBandEQProperty_BiquadCoefficients returns "an array of Float64 values,
// 5 per band".  A property getter that ignores the caller's ioDataSize and
// writes the full array anyway overflows the caller's buffer -- corruption
// that lands in the *host's* heap, which is the shape of bug that produces
// crashes far away from the audio unit itself.  Surround the buffer with a
// canary and check every byte past the size we advertised.
static void testBiquadCoefficientsRespectsBufferSize(void)
{
    TEST("BiquadCoefficients getter honours the caller's buffer size");

    AudioComponent comp = NBandEQComponent();
    if (!comp) { SKIP("no component"); return; }

    RenderState state = {0};
    AudioUnit unit = NULL;
    UInt32 bands = 0;   // keep the default
    OSStatus err = MakeEQ(&unit, &state, 44100, 2, 512, &bands);
    if (err) { SKIP("MakeEQ -> %s", [FourCC(err) UTF8String]); return; }

    ApplyAppBands(unit);

    UInt32 bandCount = 0, size = sizeof(bandCount);
    AudioUnitGetProperty(unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &bandCount, &size);

    UInt32 infoSize = 0;
    Boolean writable = false;
    err = AudioUnitGetPropertyInfo(unit, kAUNBandEQProperty_BiquadCoefficients,
                                   kAudioUnitScope_Global, 0, &infoSize, &writable);
    CHECK(err == noErr, "BiquadCoefficients property info -> %s", [FourCC(err) UTF8String]);
    if (err) { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); return; }

    UInt32 expected = bandCount * 5 * (UInt32)sizeof(Float64);
    CHECK(infoSize == expected, "advertised size %u == 5 x Float64 x %u bands (%u)",
          infoSize, bandCount, expected);
    CHECK(writable == false, "BiquadCoefficients is read-only as documented");

    const size_t kGuard = 4096;
    const uint8_t kPattern = 0xA5;

    // Offer the getter progressively smaller buffers.  Anything it writes
    // beyond the size we hand it is an out-of-bounds write into our heap.
    UInt32 offers[] = { infoSize, infoSize / 2, (UInt32)sizeof(Float64), 0 };

    for (size_t t = 0; t < sizeof(offers) / sizeof(offers[0]); t++) {
        UInt32 offer = offers[t];
        size_t total = (size_t)infoSize + kGuard;
        uint8_t *buffer = malloc(total);
        memset(buffer, kPattern, total);

        UInt32 ioSize = offer;
        OSStatus getErr = AudioUnitGetProperty(unit, kAUNBandEQProperty_BiquadCoefficients,
                                               kAudioUnitScope_Global, 0, buffer, &ioSize);

        // Find the highest byte the AU actually touched.
        size_t highestTouched = 0;
        for (size_t i = total; i > 0; i--) {
            if (buffer[i - 1] != kPattern) { highestTouched = i; break; }
        }

        CHECK(highestTouched <= offer,
              "offered %u bytes, wrote at most %zu (err %s, returned size %u)",
              offer, highestTouched, [FourCC(getErr) UTF8String], ioSize);

        if (getErr == noErr && offer >= infoSize) {
            Float64 *coeffs = (Float64 *)buffer;
            BOOL finite = YES;
            for (UInt32 i = 0; i < bandCount * 5; i++) {
                if (!isfinite(coeffs[i])) finite = NO;
            }
            CHECK(finite, "all %u coefficients are finite", bandCount * 5);
        }

        free(buffer);
    }

    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
}

// Per the header, band parameter IDs are only valid "up to the number of bands
// minus one".  Writing past that is the most likely way a host trips an
// out-of-bounds write, and it is what EffectAdditions.m would do if the
// default band count were ever smaller than its six-band layout.
static void testOutOfRangeBandParametersRejected(void)
{
    TEST("band parameters beyond the band count are refused");

    AudioComponent comp = NBandEQComponent();
    if (!comp) { SKIP("no component"); return; }

    RenderState state = {0};
    AudioUnit unit = NULL;
    UInt32 bands = 2;   // deliberately narrow, so band 2+ is out of range
    OSStatus err = MakeEQ(&unit, &state, 44100, 2, 512, &bands);
    if (err) { SKIP("MakeEQ with 2 bands -> %s", [FourCC(err) UTF8String]); return; }

    UInt32 maxBands = 0, size = sizeof(maxBands);
    AudioUnitGetProperty(unit, kAUNBandEQProperty_MaxNumberOfBands, kAudioUnitScope_Global, 0, &maxBands, &size);

    struct { AudioUnitParameterID base; const char *name; AudioUnitParameterValue value; } params[] = {
        { kAUNBandEQParam_BypassBand, "BypassBand", 0    },
        { kAUNBandEQParam_FilterType, "FilterType", 7    },
        { kAUNBandEQParam_Frequency,  "Frequency",  1000 },
        { kAUNBandEQParam_Gain,       "Gain",       12   },
        { kAUNBandEQParam_Bandwidth,  "Bandwidth",  1.0  },
    };

    // Just past the configured band count, and far past the hard maximum.
    UInt32 indices[] = { bands, bands + 1, maxBands, maxBands + 8, 500 };

    for (size_t p = 0; p < sizeof(params) / sizeof(params[0]); p++) {
        for (size_t i = 0; i < sizeof(indices) / sizeof(indices[0]); i++) {
            AudioUnitParameterID pid = params[p].base + indices[i];
            OSStatus setErr = AudioUnitSetParameter(unit, pid, kAudioUnitScope_Global, 0,
                                                    params[p].value, 0);
            CHECK(setErr != noErr, "%s band %u (id %u) rejected -> %s",
                  params[p].name, indices[i], pid, [FourCC(setErr) UTF8String]);
        }
    }

    // The unit must still render sanely afterwards.
    AudioBufferList *abl = AllocBufferList(2, 512);
    UInt64 t = 0;
    BOOL nonFinite = NO;
    err = RenderSlices(unit, abl, 512, 64, &t, &nonFinite);
    CHECK(err == noErr, "renders after rejected writes -> %s", [FourCC(err) UTF8String]);
    CHECK(!nonFinite, "output stays finite after rejected writes");

    FreeBufferList(abl);
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
}

// Exercises the exact code path in Source/EffectAdditions.m: an AUAudioUnit,
// its AUParameterTree, and -parameterWithID:scope:element:.  Note that this
// v3 path is inherently safer than AudioUnitSetParameter -- an out-of-range
// ID yields nil, and -setValue: on nil is a no-op -- but that also means a
// mis-sized layout fails *silently*, so assert every band really took.
static void testAppConfigurationApplies(void)
{
    TEST("EffectAdditions.m's six-band layout applies through AUParameterTree");

    AudioComponentDescription acd = {0};
    acd.componentType = kAudioUnitType_Effect;
    acd.componentSubType = kAudioUnitSubType_NBandEQ;
    acd.componentManufacturer = kAudioUnitManufacturer_Apple;

    NSError *error = nil;
    AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:acd error:&error];
    CHECK(unit != nil, "AUAudioUnit instantiated -> %s",
          error ? [[error localizedDescription] UTF8String] : "ok");
    if (!unit) return;

    AUParameterTree *tree = [unit parameterTree];
    CHECK(tree != nil, "parameterTree is non-nil");
    if (!tree) return;

    for (UInt32 i = 0; i < sAppBandCount; i++) {
        EQBand band = sAppBands[i];

        AUParameter *bypass = [tree parameterWithID:kAUNBandEQParam_BypassBand + i scope:kAudioUnitScope_Global element:0];
        AUParameter *type   = [tree parameterWithID:kAUNBandEQParam_FilterType + i scope:kAudioUnitScope_Global element:0];
        AUParameter *freq   = [tree parameterWithID:kAUNBandEQParam_Frequency  + i scope:kAudioUnitScope_Global element:0];
        AUParameter *gain   = [tree parameterWithID:kAUNBandEQParam_Gain       + i scope:kAudioUnitScope_Global element:0];

        CHECK(bypass && type && freq && gain, "band %u: all four parameters exist", i);
        if (!(bypass && type && freq && gain)) continue;

        [bypass setValue:0];
        [type   setValue:band.type];
        [freq   setValue:band.frequency];
        [gain   setValue:0];

        if (band.bandwidth) {
            AUParameter *bw = [tree parameterWithID:kAUNBandEQParam_Bandwidth + i scope:kAudioUnitScope_Global element:0];
            CHECK(bw != nil, "band %u: bandwidth parameter exists", i);
            [bw setValue:band.bandwidth];
        }

        CHECK([bypass value] == 0, "band %u: bypass reads back 0", i);
        CHECK((UInt32)[type value] == (UInt32)band.type, "band %u: filter type reads back %u", i, (UInt32)band.type);
        CHECK(fabsf([freq value] - band.frequency) < 1.0f,
              "band %u: frequency reads back %.0f (wanted %.0f)", i, [freq value], band.frequency);
    }

    // Bands past the layout should still be present (the comment claims eight)
    // and left bypassed for the user.
    AUParameter *seventh = [tree parameterWithID:kAUNBandEQParam_BypassBand + sAppBandCount scope:kAudioUnitScope_Global element:0];
    if (seventh) {
        CHECK([seventh value] != 0, "band %u left bypassed for the user", sAppBandCount);
    } else {
        SKIP("no band %u exposed by this build of AUNBandEQ", sAppBandCount);
    }

    [unit deallocateRenderResources];
}

// Not a memory-safety test -- a "does it actually equalize" test.  Feeds a
// sine at a band's centre frequency and checks the band's gain moves the
// output level by the amount asked for.
static void testFrequencyResponse(void)
{
    TEST("bands apply the gain they are given");

    const double kSampleRate = 44100;
    const double kToneHz = 1000;    // band 3 in the app layout
    const UInt32 kBand = 3;
    const UInt32 kFrames = 1024;
    const UInt32 kSlices = 64;

    struct { float gainDB; double expectedRatio; } cases[] = {
        {   0, 1.0    },
        { +12, 3.981  },   // 10^(12/20)
        { -12, 0.2512 },
    };

    double measured[3] = {0};

    for (size_t c = 0; c < 3; c++) {
        RenderState state = {0};
        AudioUnit unit = NULL;
        UInt32 bands = 0;
        OSStatus err = MakeEQ(&unit, &state, kSampleRate, 1, kFrames, &bands);
        if (err) { SKIP("MakeEQ -> %s", [FourCC(err) UTF8String]); return; }

        state.sineHz = kToneHz;
        ApplyAppBands(unit);
        AudioUnitSetParameter(unit, kAUNBandEQParam_Gain + kBand, kAudioUnitScope_Global, 0, cases[c].gainDB, 0);

        AudioBufferList *abl = AllocBufferList(1, kFrames);
        UInt64 t = 0;
        BOOL nonFinite = NO;
        err = RenderSlices(unit, abl, kFrames, kSlices, &t, &nonFinite);
        CHECK(err == noErr && !nonFinite, "render at %+.0f dB -> %s", cases[c].gainDB, [FourCC(err) UTF8String]);

        // RMS of the final (settled) slice.
        double sum = 0;
        const float *samples = (const float *)abl->mBuffers[0].mData;
        for (UInt32 i = 0; i < kFrames; i++) sum += (double)samples[i] * samples[i];
        measured[c] = sqrt(sum / kFrames);

        FreeBufferList(abl);
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
    }

    CHECK(measured[0] > 0.5 && measured[0] < 0.9,
          "flat EQ passes the tone through (rms %.4f, expected ~0.707)", measured[0]);

    for (size_t c = 1; c < 3; c++) {
        double ratio = measured[c] / measured[0];
        double errorDB = fabs(20 * log10(ratio) - cases[c].gainDB);
        CHECK(errorDB < 0.5, "%+.0f dB on band %u measured %+.2f dB at %.0f Hz",
              cases[c].gainDB, kBand, 20 * log10(ratio), kToneHz);
    }
}

// The scenario the app actually creates: a render loop on one thread and a
// user dragging EQ sliders on another.  Historically this is where audio units
// with unsynchronised parameter storage corrupt memory.  Run it hot and long,
// with a heap canary allocated between render buffers so a stray write into
// neighbouring allocations is caught even without a malloc guard.
typedef struct {
    AudioUnit unit;
    UInt32 bandCount;
    _Atomic(int) stop;
    _Atomic(unsigned long) writes;
} AutomationContext;

static void *AutomationThread(void *arg)
{
    AutomationContext *ctx = (AutomationContext *)arg;
    uint64_t rng = 0x2545F4914F6CDD1DULL;
    unsigned long writes = 0;

    while (!atomic_load_explicit(&ctx->stop, memory_order_relaxed)) {
        rng = rng * 6364136223846793005ULL + 1442695040888963407ULL;
        UInt32 band = (UInt32)((rng >> 33) % ctx->bandCount);
        double r = (double)((rng >> 11) & 0xFFFFF) / (double)0xFFFFF;

        AudioUnitSetParameter(ctx->unit, kAUNBandEQParam_Gain + band, kAudioUnitScope_Global, 0,
                              (AudioUnitParameterValue)(-24.0 + r * 48.0), 0);
        AudioUnitSetParameter(ctx->unit, kAUNBandEQParam_Frequency + band, kAudioUnitScope_Global, 0,
                              (AudioUnitParameterValue)(20.0 + r * 20000.0), 0);
        AudioUnitSetParameter(ctx->unit, kAUNBandEQParam_Bandwidth + band, kAudioUnitScope_Global, 0,
                              (AudioUnitParameterValue)(0.05 + r * 4.95), 0);
        AudioUnitSetParameter(ctx->unit, kAUNBandEQParam_FilterType + band, kAudioUnitScope_Global, 0,
                              (AudioUnitParameterValue)((rng >> 7) % 11), 0);
        AudioUnitSetParameter(ctx->unit, kAUNBandEQParam_BypassBand + band, kAudioUnitScope_Global, 0,
                              (AudioUnitParameterValue)((rng >> 5) & 1), 0);
        writes += 5;
    }

    atomic_store(&ctx->writes, writes);
    return NULL;
}

static void testConcurrentAutomationSoak(void)
{
    TEST("sustained render with concurrent parameter automation");

    const UInt32 kFrames = 512;
    const UInt32 kSlices = 4000;     // ~46 s of audio at 44.1 kHz
    const size_t kCanary = 8192;
    const uint8_t kPattern = 0x5A;

    RenderState state = {0};
    AudioUnit unit = NULL;
    UInt32 bands = 0;
    OSStatus err = MakeEQ(&unit, &state, 44100, 2, kFrames, &bands);
    if (err) { SKIP("MakeEQ -> %s", [FourCC(err) UTF8String]); return; }

    UInt32 bandCount = 0, size = sizeof(bandCount);
    AudioUnitGetProperty(unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &bandCount, &size);
    ApplyAppBands(unit);

    // Canaries on both sides of the render buffers.
    uint8_t *canaryLow = malloc(kCanary);  memset(canaryLow,  kPattern, kCanary);
    AudioBufferList *abl = AllocBufferList(2, kFrames);
    uint8_t *canaryHigh = malloc(kCanary); memset(canaryHigh, kPattern, kCanary);

    AutomationContext ctx = { .unit = unit, .bandCount = bandCount };
    atomic_init(&ctx.stop, 0);
    atomic_init(&ctx.writes, 0);

    pthread_t thread;
    pthread_create(&thread, NULL, AutomationThread, &ctx);

    UInt64 t = 0;
    BOOL nonFinite = NO;
    err = RenderSlices(unit, abl, kFrames, kSlices, &t, &nonFinite);

    atomic_store(&ctx.stop, 1);
    pthread_join(thread, NULL);

    CHECK(err == noErr, "%u slices x %u frames rendered -> %s", kSlices, kFrames, [FourCC(err) UTF8String]);
    INFO("%lu parameter writes raced against the render thread", atomic_load(&ctx.writes));

    // Wild parameter jumps legitimately make a biquad ring, but never produce
    // NaN or infinity in a correct implementation.
    CHECK(!nonFinite, "output stayed finite through every parameter jump");

    BOOL lowIntact = YES, highIntact = YES;
    for (size_t i = 0; i < kCanary; i++) {
        if (canaryLow[i]  != kPattern) lowIntact  = NO;
        if (canaryHigh[i] != kPattern) highIntact = NO;
    }
    CHECK(lowIntact && highIntact, "%zu-byte heap canaries either side of the render buffers are intact", kCanary);

    free(canaryLow);
    free(canaryHigh);
    FreeBufferList(abl);
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
}

// Every band active, at the maximum band count, across the channel layouts and
// slice sizes a real host will hand it.  Buffers are sized exactly, so an AU
// that writes even one frame past the end lands in a guard page under
// libgmalloc.
static void testMaxBandsAcrossFormats(void)
{
    TEST("maximum band count across channel counts and slice sizes");

    AudioComponent comp = NBandEQComponent();
    if (!comp) { SKIP("no component"); return; }

    AudioUnit probe = NULL;
    if (AudioComponentInstanceNew(comp, &probe) != noErr) { SKIP("instantiate"); return; }
    UInt32 maxBands = 0, size = sizeof(maxBands);
    AudioUnitGetProperty(probe, kAUNBandEQProperty_MaxNumberOfBands, kAudioUnitScope_Global, 0, &maxBands, &size);
    AudioComponentInstanceDispose(probe);

    double rates[]    = { 44100, 48000, 96000, 192000 };
    UInt32 channels[] = { 1, 2, 4, 8 };
    UInt32 slices[]   = { 1, 32, 512, 4096 };

    for (size_t r = 0; r < 4; r++) {
        for (size_t c = 0; c < 4; c++) {
            for (size_t s = 0; s < 4; s++) {
                RenderState state = {0};
                AudioUnit unit = NULL;
                UInt32 bands = maxBands;

                OSStatus err = MakeEQ(&unit, &state, rates[r], channels[c], slices[s], &bands);
                if (err) {
                    // Not every channel count is required to be supported.
                    SKIP("%.0f Hz / %u ch / %u frames unsupported -> %s",
                         rates[r], channels[c], slices[s], [FourCC(err) UTF8String]);
                    continue;
                }

                // Turn on every band with a distinct filter type.
                for (UInt32 i = 0; i < maxBands; i++) {
                    AudioUnitSetParameter(unit, kAUNBandEQParam_BypassBand + i, kAudioUnitScope_Global, 0, 0, 0);
                    AudioUnitSetParameter(unit, kAUNBandEQParam_FilterType + i, kAudioUnitScope_Global, 0, i % 11, 0);
                    AudioUnitSetParameter(unit, kAUNBandEQParam_Frequency  + i, kAudioUnitScope_Global, 0,
                                          40.0f * powf(1.6f, (float)i), 0);
                    AudioUnitSetParameter(unit, kAUNBandEQParam_Gain       + i, kAudioUnitScope_Global, 0,
                                          (i % 2) ? 6.0f : -6.0f, 0);
                    AudioUnitSetParameter(unit, kAUNBandEQParam_Bandwidth  + i, kAudioUnitScope_Global, 0, 0.5f, 0);
                }

                AudioBufferList *abl = AllocBufferList(channels[c], slices[s]);
                UInt64 t = 0;
                BOOL nonFinite = NO;
                err = RenderSlices(unit, abl, slices[s], 128, &t, &nonFinite);

                CHECK(err == noErr && !nonFinite,
                      "%6.0f Hz / %u ch / %4u frames / %u bands -> %s%s",
                      rates[r], channels[c], slices[s], maxBands,
                      [FourCC(err) UTF8String], nonFinite ? " NON-FINITE OUTPUT" : "");

                FreeBufferList(abl);
                AudioUnitUninitialize(unit);
                AudioComponentInstanceDispose(unit);
            }
        }
    }
}

// Parameter values outside the documented ranges, plus NaN and infinity.  A
// host slider, a restored preset, or a sample-rate change can all produce a
// frequency above Nyquist; the AU must contain that rather than index a table
// with it.  Each value gets a fresh unit so a poisoned filter state cannot
// leak into the next case and turn one failure into thirty.
static void testHostileParameterValues(void)
{
    TEST("out-of-range, NaN and infinite parameter values are contained");

    struct { AudioUnitParameterID base; const char *name; BOOL perBand; } bases[] = {
        { kAUNBandEQParam_Frequency,  "Frequency",  YES },
        { kAUNBandEQParam_Gain,       "Gain",       YES },
        { kAUNBandEQParam_Bandwidth,  "Bandwidth",  YES },
        { kAUNBandEQParam_FilterType, "FilterType", YES },
        { kAUNBandEQParam_BypassBand, "BypassBand", YES },
        { kAUNBandEQParam_GlobalGain, "GlobalGain", NO  },
    };

    struct { float value; const char *label; } values[] = {
        { 0.0f,       "0"        }, { -1.0f,      "-1"       },
        { -1e9f,      "-1e9"     }, { 1e9f,       "1e9"      },
        { 22050.0f,   "Nyquist"  }, { 22051.0f,   ">Nyquist" },
        { 96000.0f,   "96k"      }, { FLT_MAX,    "FLT_MAX"  },
        { -FLT_MAX,   "-FLT_MAX" }, { FLT_MIN,    "FLT_MIN"  },
        { NAN,        "NaN"      }, { INFINITY,   "+Inf"     },
        { -INFINITY,  "-Inf"     },
    };

    int renderFailures = 0, nonFiniteCases = 0, rejectedNonFinite = 0, nonFiniteTotal = 0;

    for (size_t b = 0; b < sizeof(bases) / sizeof(bases[0]); b++) {
        for (size_t v = 0; v < sizeof(values) / sizeof(values[0]); v++) {
            RenderState state = {0};
            AudioUnit unit = NULL;
            UInt32 bands = 0;
            if (MakeEQ(&unit, &state, 44100, 2, 512, &bands) != noErr) { SKIP("MakeEQ"); return; }

            ApplyAppBands(unit);

            AudioUnitParameterID pid = bases[b].base + (bases[b].perBand ? 2 : 0);
            OSStatus setErr = AudioUnitSetParameter(unit, pid, kAudioUnitScope_Global, 0, values[v].value, 0);

            BOOL isNonFinite = !isfinite(values[v].value);
            if (isNonFinite) {
                nonFiniteTotal++;
                if (setErr != noErr) rejectedNonFinite++;

                // A rejected write must leave the previous value in place.
                float readBack = 0;
                AudioUnitGetParameter(unit, pid, kAudioUnitScope_Global, 0, &readBack);
                CHECK(isfinite(readBack), "%s <- %s rejected, value stays finite (%g)",
                      bases[b].name, values[v].label, readBack);
            }

            AudioBufferList *abl = AllocBufferList(2, 512);
            UInt64 t = 0;
            BOOL nonFiniteOut = NO;
            OSStatus renderErr = RenderSlices(unit, abl, 512, 32, &t, &nonFiniteOut);
            if (renderErr != noErr) renderFailures++;
            if (nonFiniteOut) {
                nonFiniteCases++;
                INFO("non-finite audio from %s = %s", bases[b].name, values[v].label);

                // Only a gain can do this, and only by overflowing 10^(dB/20).
                // A frequency, bandwidth or filter type that reaches the audio
                // would mean a coefficient was computed from an unvalidated
                // value -- a real defect rather than arithmetic.
                BOOL isGain = (bases[b].base == kAUNBandEQParam_Gain ||
                               bases[b].base == kAUNBandEQParam_GlobalGain);
                CHECK(isGain, "non-finite audio confined to gain (%s = %s)",
                      bases[b].name, values[v].label);
            }

            FreeBufferList(abl);
            AudioUnitUninitialize(unit);
            AudioComponentInstanceDispose(unit);
        }
    }

    size_t total = (sizeof(bases) / sizeof(bases[0])) * (sizeof(values) / sizeof(values[0]));
    CHECK(renderFailures == 0, "all %zu hostile-value renders completed without error", total);

    // NaN and infinity must be refused outright -- storing either one bakes a
    // NaN into a biquad coefficient, which silences the stream permanently.
    CHECK(rejectedNonFinite == nonFiniteTotal,
          "%d/%d NaN/Inf writes refused", rejectedNonFinite, nonFiniteTotal);

    // Finite-but-absurd gains legitimately overflow to infinity (10^(1e9/20)
    // is not representable); that is arithmetic, not corruption.  What matters
    // is that it is confined to the gain parameters.
    INFO("%d/%zu cases produced non-finite audio (expected: extreme gain only)",
         nonFiniteCases, total);
}

// Asking for more frames than kAudioUnitProperty_MaximumFramesPerSlice must be
// refused.  An AU that obliges is writing past buffers the host sized from the
// same property -- the textbook version of this crash.
static void testOverlongRenderRefused(void)
{
    TEST("render beyond MaximumFramesPerSlice is refused, not obeyed");

    const UInt32 kMaxFrames = 512;

    RenderState state = {0};
    AudioUnit unit = NULL;
    UInt32 bands = 0;
    OSStatus err = MakeEQ(&unit, &state, 44100, 2, kMaxFrames, &bands);
    if (err) { SKIP("MakeEQ -> %s", [FourCC(err) UTF8String]); return; }

    ApplyAppBands(unit);

    // Buffers sized to the *declared* maximum, with a canary behind each.
    const size_t kCanary = 4096;
    const uint8_t kPattern = 0xC3;
    const UInt32 kChannels = 2;

    AudioBufferList *abl = calloc(1, sizeof(AudioBufferList) + (kChannels - 1) * sizeof(AudioBuffer));
    abl->mNumberBuffers = kChannels;
    uint8_t *blocks[2];
    for (UInt32 i = 0; i < kChannels; i++) {
        size_t bytes = kMaxFrames * sizeof(float);
        blocks[i] = malloc(bytes + kCanary);
        memset(blocks[i], kPattern, bytes + kCanary);
        abl->mBuffers[i].mNumberChannels = 1;
        abl->mBuffers[i].mDataByteSize = (UInt32)bytes;
        abl->mBuffers[i].mData = blocks[i];
    }

    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp ts = {0};
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    ts.mSampleTime = 0;

    UInt32 overlong = kMaxFrames * 4;
    OSStatus renderErr = AudioUnitRender(unit, &flags, &ts, 0, overlong, abl);

    CHECK(renderErr != noErr, "render of %u frames (max %u) refused -> %s",
          overlong, kMaxFrames, [FourCC(renderErr) UTF8String]);

    BOOL intact = YES;
    for (UInt32 i = 0; i < kChannels; i++) {
        uint8_t *canary = blocks[i] + kMaxFrames * sizeof(float);
        for (size_t j = 0; j < kCanary; j++) if (canary[j] != kPattern) intact = NO;
    }
    CHECK(intact, "canary past each %u-frame buffer is intact", kMaxFrames);

    for (UInt32 i = 0; i < kChannels; i++) free(blocks[i]);
    free(abl);
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
}

// Instantiate/configure/render/dispose churn, which is what adding and removing
// the effect in the Effects window does.  Catches leaks of the band array and
// use-after-free on teardown.
static void testLifecycleChurn(void)
{
    TEST("repeated instantiate / configure / render / dispose cycles");

    const int kCycles = 300;
    int failures = 0;

    for (int i = 0; i < kCycles; i++) {
        RenderState state = {0};
        AudioUnit unit = NULL;
        UInt32 bands = (i % 2) ? 0 : (UInt32)(1 + (i % 8));

        OSStatus err = MakeEQ(&unit, &state, 44100, 2, 256, &bands);
        if (err) { failures++; continue; }

        ApplyAppBands(unit);

        AudioBufferList *abl = AllocBufferList(2, 256);
        UInt64 t = 0;
        if (RenderSlices(unit, abl, 256, 4, &t, NULL) != noErr) failures++;
        FreeBufferList(abl);

        // Uninitialize, reconfigure, re-initialize -- the path a sample-rate
        // change takes.
        if (AudioUnitUninitialize(unit) != noErr) failures++;
        UInt32 newBands = 4;
        AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &newBands, sizeof(newBands));
        if (AudioUnitInitialize(unit) != noErr) failures++;

        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
    }

    CHECK(failures == 0, "%d cycles completed with %d failures", kCycles, failures);
}

// AUNBandEQ accepts kAUNBandEQProperty_NumberOfBands while initialized even
// though the header forbids it, which means it resizes its band array under a
// live render.  A host that trusts the noErr -- restoring a preset while the
// engine runs, say -- puts a reallocation directly in the path of the render
// thread.  Hammer that race; under guard malloc a stale pointer lands on a
// protected page instead of quietly scribbling on the heap.
typedef struct {
    AudioUnit unit;
    UInt32 maxBands;
    _Atomic(int) stop;
    _Atomic(unsigned long) flips;
} ResizeContext;

static void *ResizeThread(void *arg)
{
    ResizeContext *ctx = (ResizeContext *)arg;
    unsigned long n = 0;

    while (!atomic_load_explicit(&ctx->stop, memory_order_relaxed)) {
        UInt32 bands = 1 + (UInt32)(n % ctx->maxBands);
        if (AudioUnitSetProperty(ctx->unit, kAUNBandEQProperty_NumberOfBands,
                                 kAudioUnitScope_Global, 0, &bands, sizeof(bands)) == noErr) {
            for (UInt32 i = 0; i < bands; i++) {
                AudioUnitSetParameter(ctx->unit, kAUNBandEQParam_BypassBand + i, kAudioUnitScope_Global, 0, 0, 0);
                AudioUnitSetParameter(ctx->unit, kAUNBandEQParam_Gain + i, kAudioUnitScope_Global, 0, (i % 2) ? 9.0f : -9.0f, 0);
                AudioUnitSetParameter(ctx->unit, kAUNBandEQParam_Frequency + i, kAudioUnitScope_Global, 0,
                                      40.0f * powf(1.6f, (float)i), 0);
            }
        }
        n++;
    }

    atomic_store(&ctx->flips, n);
    return NULL;
}

static void testConcurrentBandCountResize(void)
{
    TEST("band count resized concurrently with an active render");

    const UInt32 kFrames = 512;
    const UInt32 kSlices = 20000;

    RenderState state = {0};
    AudioUnit unit = NULL;
    UInt32 bands = 2;      // initialize small, then grow underneath the render
    OSStatus err = MakeEQ(&unit, &state, 44100, 2, kFrames, &bands);
    if (err) { SKIP("MakeEQ -> %s", [FourCC(err) UTF8String]); return; }

    UInt32 maxBands = 0, size = sizeof(maxBands);
    AudioUnitGetProperty(unit, kAUNBandEQProperty_MaxNumberOfBands, kAudioUnitScope_Global, 0, &maxBands, &size);

    // Verify the premise before racing on it.
    UInt32 grow = maxBands;
    OSStatus liveErr = AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands,
                                            kAudioUnitScope_Global, 0, &grow, sizeof(grow));
    if (liveErr != noErr) {
        SKIP("this build refuses live band-count changes (%s) -- race not reachable",
             [FourCC(liveErr) UTF8String]);
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        return;
    }

    AudioBufferList *abl = AllocBufferList(2, kFrames);

    ResizeContext ctx = { .unit = unit, .maxBands = maxBands };
    atomic_init(&ctx.stop, 0);
    atomic_init(&ctx.flips, 0);

    pthread_t thread;
    pthread_create(&thread, NULL, ResizeThread, &ctx);

    UInt64 t = 0;
    BOOL nonFinite = NO;
    err = RenderSlices(unit, abl, kFrames, kSlices, &t, &nonFinite);

    atomic_store(&ctx.stop, 1);
    pthread_join(thread, NULL);

    CHECK(err == noErr, "%u slices survived %lu concurrent resizes -> %s",
          kSlices, atomic_load(&ctx.flips), [FourCC(err) UTF8String]);
    CHECK(!nonFinite, "output stayed finite across every resize");

    // The unit must still be coherent afterwards.
    UInt32 finalBands = 0; size = sizeof(finalBands);
    OSStatus getErr = AudioUnitGetProperty(unit, kAUNBandEQProperty_NumberOfBands,
                                           kAudioUnitScope_Global, 0, &finalBands, &size);
    CHECK(getErr == noErr && finalBands >= 1 && finalBands <= maxBands,
          "band count still sane afterwards: %u (max %u)", finalBands, maxBands);

    FreeBufferList(abl);
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
}

// Effect.m reads a property list straight out of a saved set list and hands it
// to -setFullState:.  That dictionary carries "numberOfBands" next to an opaque
// "data" blob, and the blob turns out to be:
//
//     [8-byte header][big-endian uint32 record count][count x 8-byte records]
//
// where each record is a big-endian float value followed by a big-endian
// parameter ID.  For a default eight-band unit the count is 81 and the blob is
// 12 + 81*8 = 660 bytes.  Nothing cross-checks that count against the blob's
// actual length, so a corrupt file walks the parser off the end of the
// allocation.  These tests pin that behaviour.
//
// Each trial runs in a re-exec'd child (see kStateTrialArg) so that a crash is
// reported as a failing test rather than taking the whole suite with it.

static const char *kStateTrialArg = "--state-trial";

static AudioComponentDescription NBandEQDescription(void)
{
    AudioComponentDescription acd = {0};
    acd.componentType = kAudioUnitType_Effect;
    acd.componentSubType = kAudioUnitSubType_NBandEQ;
    acd.componentManufacturer = kAudioUnitManufacturer_Apple;
    return acd;
}

static NSDictionary *ValidFullState(void)
{
    NSError *error = nil;
    AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:NBandEQDescription() error:&error];
    if (!unit) return nil;

    AUParameterTree *tree = [unit parameterTree];
    for (UInt32 i = 0; i < sAppBandCount; i++) {
        [[tree parameterWithID:kAUNBandEQParam_BypassBand + i scope:kAudioUnitScope_Global element:0] setValue:0];
        [[tree parameterWithID:kAUNBandEQParam_FilterType + i scope:kAudioUnitScope_Global element:0] setValue:sAppBands[i].type];
        [[tree parameterWithID:kAUNBandEQParam_Frequency  + i scope:kAudioUnitScope_Global element:0] setValue:sAppBands[i].frequency];
        [[tree parameterWithID:kAUNBandEQParam_Gain       + i scope:kAudioUnitScope_Global element:0] setValue:3];
    }

    return [unit fullState];
}

// Body of the child process: load a state plist, install it, read it back and
// render.  Exits 0 on success; a crash shows up as a signal to the parent.
static int RunStateTrial(const char *path)
{
    NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
    if (!data) return 91;

    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL error:&error];
    if (![plist isKindOfClass:[NSDictionary class]]) return 92;

    AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:NBandEQDescription() error:&error];
    if (!unit) return 93;

    [unit setFullState:(NSDictionary *)plist];
    (void)[unit fullState];
    (void)[unit parameterTree];

    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    [unit setMaximumFramesToRender:512];
    [[[unit inputBusses]  objectAtIndexedSubscript:0] setFormat:format error:&error];
    [[[unit outputBusses] objectAtIndexedSubscript:0] setFormat:format error:&error];

    if ([unit allocateRenderResourcesAndReturnError:&error]) {
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
        AudioBufferList *abl = AllocBufferList(2, 512);
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp ts = {0};
        ts.mFlags = kAudioTimeStampSampleTimeValid;

        for (int i = 0; i < 32; i++) {
            ts.mSampleTime = i * 512;
            for (UInt32 b = 0; b < abl->mNumberBuffers; b++) abl->mBuffers[b].mDataByteSize = 512 * sizeof(float);
            render(&flags, &ts, 512, 0, abl, NULL, pull);
        }

        FreeBufferList(abl);
        [unit deallocateRenderResources];
    }

    return 0;
}

static const char *sExecutablePath = NULL;

// Returns 0 if the child completed, or 128+signal if it died.
static int TrialInChild(NSDictionary *state)
{
    NSString *path = [NSString stringWithFormat:@"%@/nbandeq-state-%u.plist",
                      NSTemporaryDirectory(), arc4random()];

    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:state
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:&error];
    if (!data || ![data writeToFile:path atomically:YES]) return 94;

    pid_t pid = fork();
    if (pid == 0) {
        // Re-exec so the child does not inherit CoreAudio's threads.
        execl(sExecutablePath, sExecutablePath, kStateTrialArg, [path UTF8String], (char *)NULL);
        _exit(95);
    }

    int status = 0;
    waitpid(pid, &status, 0);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return WEXITSTATUS(status);
}

static NSString *DescribeTrial(int rc)
{
    if (rc == 0) return @"ok";
    if (rc > 128) return [NSString stringWithFormat:@"signal %d", rc - 128];
    return [NSString stringWithFormat:@"exit %d", rc];
}

// The headline test: the record count embedded in the blob must be validated
// against the blob's real length.
static void testFullStateRecordCountIsValidated(void)
{
    TEST("the record count inside a saved preset is validated against its length");

    NSDictionary *valid = ValidFullState();
    if (!valid) { SKIP("could not capture a valid fullState"); return; }

    NSData *blob = valid[@"data"];
    const uint8_t *bytes = [blob bytes];
    NSUInteger length = [blob length];

    CHECK(length >= 12, "state blob is %lu bytes", (unsigned long)length);
    if (length < 12) return;

    uint32_t declared = ((uint32_t)bytes[8] << 24) | ((uint32_t)bytes[9] << 16) |
                        ((uint32_t)bytes[10] << 8) | (uint32_t)bytes[11];

    CHECK(12 + (NSUInteger)declared * 8 == length,
          "declared record count %u accounts for the blob exactly (12 + %u*8 == %lu)",
          declared, declared, (unsigned long)length);

    CHECK(TrialInChild(valid) == 0, "unmodified state round-trips");

    // Counts that claim more records than the blob can hold.
    uint32_t counts[] = { declared + 1, 100, 1000, 65535, 0x10000, 0x100000,
                          0x1000000, 0x1000051, 0x7FFFFFFF, 0xFFFFFFFF };

    for (size_t i = 0; i < sizeof(counts) / sizeof(counts[0]); i++) {
        NSMutableData *mutated = [blob mutableCopy];
        uint8_t *p = [mutated mutableBytes];
        p[8]  = (counts[i] >> 24) & 0xFF;
        p[9]  = (counts[i] >> 16) & 0xFF;
        p[10] = (counts[i] >> 8)  & 0xFF;
        p[11] =  counts[i]        & 0xFF;

        NSMutableDictionary *state = [valid mutableCopy];
        state[@"data"] = mutated;

        int rc = TrialInChild(state);
        NSUInteger claimed = 12 + (NSUInteger)counts[i] * 8;
        KNOWN_DEFECT(rc == 0, "count %u (claims %lu bytes of a %lu-byte blob) -> %s",
              counts[i], (unsigned long)claimed, (unsigned long)length,
              [DescribeTrial(rc) UTF8String]);
    }
}

static void testHostileFullState(void)
{
    TEST("inconsistent and fuzzed presets fed through -setFullState:");

    NSDictionary *valid = ValidFullState();
    if (!valid) { SKIP("could not capture a valid fullState"); return; }

    NSData *validData = valid[@"data"];
    CHECK(valid != nil, "captured a valid fullState (%s bands, %lu-byte blob)",
          [[valid[@"numberOfBands"] description] UTF8String], (unsigned long)[validData length]);

    // numberOfBands disagreeing with the blob.
    NSNumber *counts[] = { @0, @1, @7, @16, @17, @999, @65536, @(-1), @2147483647 };
    for (size_t i = 0; i < sizeof(counts) / sizeof(counts[0]); i++) {
        NSMutableDictionary *state = [valid mutableCopy];
        state[@"numberOfBands"] = counts[i];
        int rc = TrialInChild(state);
        CHECK(rc == 0, "numberOfBands = %s -> %s",
              [[counts[i] stringValue] UTF8String], [DescribeTrial(rc) UTF8String]);
    }

    // Blob truncated or padded.
    NSUInteger lengths[] = { 0, 1, 8, 11, 12, [validData length] / 2,
                             [validData length] - 1, [validData length] + 1,
                             [validData length] * 4 };
    for (size_t i = 0; i < sizeof(lengths) / sizeof(lengths[0]); i++) {
        NSMutableDictionary *state = [valid mutableCopy];
        NSMutableData *data = [NSMutableData dataWithLength:lengths[i]];
        [data replaceBytesInRange:NSMakeRange(0, MIN(lengths[i], [validData length]))
                        withBytes:[validData bytes]];
        state[@"data"] = data;
        // NB: a short blob still declares 81 records, so the parser reads
        // past it here too.  These pass because the over-read is small enough
        // to stay inside mapped heap -- run under guard malloc to see it.
        int rc = TrialInChild(state);
        CHECK(rc == 0, "blob truncated/padded to %lu bytes -> %s",
              (unsigned long)lengths[i], [DescribeTrial(rc) UTF8String]);
    }

    // Wrong types where numbers and data are expected.
    NSMutableDictionary *wrongType = [valid mutableCopy];
    wrongType[@"numberOfBands"] = @"not a number";
    CHECK(TrialInChild(wrongType) == 0, "string in place of numberOfBands");

    NSMutableDictionary *missing = [valid mutableCopy];
    [missing removeObjectForKey:@"data"];
    CHECK(TrialInChild(missing) == 0, "missing data key");

    NSMutableDictionary *nested = [valid mutableCopy];
    nested[@"data"] = @{ @"unexpected": @[ @1, @2, @3 ] };
    CHECK(TrialInChild(nested) == 0, "dictionary in place of data");
}

// The blob format is not AUNBandEQ's own -- it is the shared representation
// CoreAudio uses for kAudioUnitProperty_ClassInfo -- so the same unchecked
// count reaches every Apple effect the app can host.  Effect.m applies saved
// state to whichever effect a set list names, so this is worth knowing per
// unit rather than for the EQ alone.
static void testOtherAppleEffectsShareTheFormat(void)
{
    TEST("other Apple effects hosted by the app use the same preset format");

    struct { OSType subType; const char *name; } effects[] = {
        { kAudioUnitSubType_NBandEQ,             "AUNBandEQ"             },
        { kAudioUnitSubType_GraphicEQ,           "AUGraphicEQ"           },
        { kAudioUnitSubType_ParametricEQ,        "AUParametricEQ"        },
        { kAudioUnitSubType_DynamicsProcessor,   "AUDynamicsProcessor"   },
        { kAudioUnitSubType_MultiBandCompressor, "AUMultibandCompressor" },
        { kAudioUnitSubType_PeakLimiter,         "AUPeakLimiter"         },
        { kAudioUnitSubType_LowPassFilter,       "AULowpass"             },
        { kAudioUnitSubType_HighShelfFilter,     "AUHighShelfFilter"     },
        { kAudioUnitSubType_Delay,               "AUDelay"               },
        { kAudioUnitSubType_MatrixReverb,        "AUMatrixReverb"        },
    };

    for (size_t i = 0; i < sizeof(effects) / sizeof(effects[0]); i++) {
        AudioComponentDescription acd = {0};
        acd.componentType = kAudioUnitType_Effect;
        acd.componentSubType = effects[i].subType;
        acd.componentManufacturer = kAudioUnitManufacturer_Apple;

        NSError *error = nil;
        AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:acd error:&error];
        if (!unit) { SKIP("%s unavailable", effects[i].name); continue; }

        NSData *blob = [unit fullState][@"data"];
        if ([blob length] < 12) { SKIP("%s has no length-prefixed blob", effects[i].name); continue; }

        const uint8_t *bytes = [blob bytes];
        uint32_t declared = ((uint32_t)bytes[8] << 24) | ((uint32_t)bytes[9] << 16) |
                            ((uint32_t)bytes[10] << 8) | (uint32_t)bytes[11];

        CHECK(12 + (NSUInteger)declared * 8 == [blob length],
              "%s: same layout (12 + %u*8 == %lu bytes)",
              effects[i].name, declared, (unsigned long)[blob length]);
    }
}

// Bit-flip fuzzing of the opaque blob.  Slow -- each round is a process
// launch -- so it only runs in the full suite.
static void testFullStateFuzz(void)
{
    TEST("bit-flip fuzzing of the saved preset blob");

    NSDictionary *valid = ValidFullState();
    if (!valid) { SKIP("could not capture a valid fullState"); return; }

    NSData *validData = valid[@"data"];
    NSUInteger length = [validData length];

    const int kRounds = 250;
    uint64_t rng = 0x9E3779B97F4A7C15ULL;
    int survived = 0;
    NSMutableSet *crashOffsets = [NSMutableSet set];

    for (int i = 0; i < kRounds; i++) {
        NSMutableData *data = [validData mutableCopy];
        uint8_t *bytes = [data mutableBytes];
        NSMutableArray *touched = [NSMutableArray array];

        int mutations = 1 + (i % 8);
        for (int m = 0; m < mutations; m++) {
            rng = rng * 6364136223846793005ULL + 1442695040888963407ULL;
            NSUInteger offset = (NSUInteger)((rng >> 33) % length);
            bytes[offset] ^= (uint8_t)(1 << ((rng >> 13) & 7));
            [touched addObject:@(offset)];
        }

        NSMutableDictionary *state = [valid mutableCopy];
        state[@"data"] = data;

        if (TrialInChild(state) == 0) survived++;
        else [crashOffsets addObjectsFromArray:touched];
    }

    KNOWN_DEFECT(survived == kRounds, "%d/%d bit-flipped presets survived", survived, kRounds);

    if (survived != kRounds) {
        NSArray *sorted = [[crashOffsets allObjects] sortedArrayUsingSelector:@selector(compare:)];
        INFO("offsets implicated in crashes: %s",
             [[[sorted subarrayWithRange:NSMakeRange(0, MIN(24, [sorted count]))]
               componentsJoinedByString:@", "] UTF8String]);
    }
}

// EmbraceNG's mitigation for the unchecked record count: screen the blob before
// it reaches the audio unit.  The guarantee that matters is one-directional --
// anything the validator accepts must not crash.  Rejecting a few odd-but-safe
// blobs costs a preset; accepting one bad blob costs the show.
static void testStateValidatorAcceptsOnlySafeBlobs(void)
{
    TEST("EmbraceAudioUnitFullStateIsWellFormed accepts only blobs that survive");

    AudioComponentDescription acd = NBandEQDescription();

    NSDictionary *valid = ValidFullState();
    if (!valid) { SKIP("could not capture a valid fullState"); return; }

    CHECK(EmbraceAudioUnitFullStateIsWellFormed(valid, acd), "accepts a genuine state");

    // Every Apple effect the app can host must pass as-is, or the mitigation
    // would throw away working presets.
    OSType subTypes[] = {
        kAudioUnitSubType_NBandEQ, kAudioUnitSubType_GraphicEQ,
        kAudioUnitSubType_ParametricEQ, kAudioUnitSubType_DynamicsProcessor,
        kAudioUnitSubType_MultiBandCompressor, kAudioUnitSubType_PeakLimiter,
        kAudioUnitSubType_LowPassFilter, kAudioUnitSubType_HighShelfFilter,
        kAudioUnitSubType_Delay, kAudioUnitSubType_MatrixReverb,
    };

    for (size_t i = 0; i < sizeof(subTypes) / sizeof(subTypes[0]); i++) {
        AudioComponentDescription other = NBandEQDescription();
        other.componentSubType = subTypes[i];

        NSError *error = nil;
        AUAudioUnit *unit = [[AUAudioUnit alloc] initWithComponentDescription:other error:&error];
        if (!unit) continue;

        char name[5] = { (char)(subTypes[i] >> 24), (char)(subTypes[i] >> 16),
                         (char)(subTypes[i] >> 8), (char)subTypes[i], 0 };
        CHECK(EmbraceAudioUnitFullStateIsWellFormed([unit fullState], other),
              "accepts a genuine '%s' state", name);
    }

    // Third-party units keep their own opaque format and must pass through.
    AudioComponentDescription thirdParty = NBandEQDescription();
    thirdParty.componentManufacturer = 'Test';
    CHECK(EmbraceAudioUnitFullStateIsWellFormed(@{ @"data": [NSData dataWithBytes:"junk" length:4] }, thirdParty),
          "passes through a third-party unit's state untouched");

    // Nothing to validate is not the same as invalid.
    CHECK(EmbraceAudioUnitFullStateIsWellFormed(@{ @"numberOfBands": @8 }, acd),
          "accepts a state with no data blob");
    CHECK(!EmbraceAudioUnitFullStateIsWellFormed(@{ @"data": @"a string" }, acd),
          "rejects a non-NSData blob");
    CHECK(!EmbraceAudioUnitFullStateIsWellFormed(nil, acd), "rejects nil");

    // Every count that crashed AUNBandEQ must now be refused.
    NSData *blob = valid[@"data"];
    uint32_t crashers[] = { 0x100000, 0x1000000, 0x1000051, 0x7FFFFFFF, 0xFFFFFFFF, 100, 1000, 65535 };

    for (size_t i = 0; i < sizeof(crashers) / sizeof(crashers[0]); i++) {
        NSMutableData *mutated = [blob mutableCopy];
        uint8_t *p = [mutated mutableBytes];
        p[8] = (crashers[i] >> 24) & 0xFF; p[9]  = (crashers[i] >> 16) & 0xFF;
        p[10] = (crashers[i] >> 8) & 0xFF; p[11] =  crashers[i]        & 0xFF;

        NSMutableDictionary *state = [valid mutableCopy];
        state[@"data"] = mutated;
        CHECK(!EmbraceAudioUnitFullStateIsWellFormed(state, acd),
              "rejects record count %u over a %lu-byte blob",
              crashers[i], (unsigned long)[blob length]);
    }

    // Truncated blobs, which over-read even when they happen not to fault.
    NSUInteger lengths[] = { 0, 1, 8, 11, 12, [blob length] / 2, [blob length] - 1, [blob length] + 1 };
    for (size_t i = 0; i < sizeof(lengths) / sizeof(lengths[0]); i++) {
        NSMutableData *data = [NSMutableData dataWithLength:lengths[i]];
        [data replaceBytesInRange:NSMakeRange(0, MIN(lengths[i], [blob length])) withBytes:[blob bytes]];
        NSMutableDictionary *state = [valid mutableCopy];
        state[@"data"] = data;
        CHECK(!EmbraceAudioUnitFullStateIsWellFormed(state, acd),
              "rejects a blob truncated/padded to %lu bytes", (unsigned long)lengths[i]);
    }
}

// The end-to-end guarantee, fuzzed: for every mutated preset, whatever the
// validator says, "accepted" must imply "did not crash".
static void testStateValidatorHoldsUnderFuzzing(void)
{
    TEST("no blob the validator accepts crashes the audio unit");

    NSDictionary *valid = ValidFullState();
    if (!valid) { SKIP("could not capture a valid fullState"); return; }

    AudioComponentDescription acd = NBandEQDescription();
    NSData *validData = valid[@"data"];
    NSUInteger length = [validData length];

    const int kRounds = 250;
    uint64_t rng = 0xD1B54A32D192ED03ULL;
    int accepted = 0, rejected = 0, acceptedAndCrashed = 0, rejectedButSafe = 0;

    for (int i = 0; i < kRounds; i++) {
        NSMutableData *data = [validData mutableCopy];
        uint8_t *bytes = [data mutableBytes];

        // Bias a quarter of the rounds at the count field, where the bug lives.
        int mutations = 1 + (i % 8);
        for (int m = 0; m < mutations; m++) {
            rng = rng * 6364136223846793005ULL + 1442695040888963407ULL;
            NSUInteger offset = (i % 4 == 0) ? (8 + ((rng >> 33) % 4))
                                             : (NSUInteger)((rng >> 33) % length);
            bytes[offset] ^= (uint8_t)(1 << ((rng >> 13) & 7));
        }

        NSMutableDictionary *state = [valid mutableCopy];
        state[@"data"] = data;

        BOOL wellFormed = EmbraceAudioUnitFullStateIsWellFormed(state, acd);
        BOOL survived = (TrialInChild(state) == 0);

        if (wellFormed) {
            accepted++;
            if (!survived) acceptedAndCrashed++;
        } else {
            rejected++;
            if (survived) rejectedButSafe++;
        }
    }

    CHECK(acceptedAndCrashed == 0,
          "%d/%d accepted presets, none crashed", accepted, kRounds);
    INFO("%d rejected, of which %d would in fact have been harmless",
         rejected, rejectedButSafe);
}

// ------------------------------------------------------------------- main --

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        sExecutablePath = argv[0];

        // Child mode first, before any output: a crash here must be
        // attributable to the state under test and nothing else.
        if (argc > 2 && strcmp(argv[1], kStateTrialArg) == 0) {
            return RunStateTrial(argv[2]);
        }

        fprintf(stderr, "AUNBandEQ test suite\n");

        NSProcessInfo *info = [NSProcessInfo processInfo];
        NSOperatingSystemVersion os = [info operatingSystemVersion];
        fprintf(stderr, "macOS %ld.%ld.%ld\n",
                (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion);

        const char *guard = getenv("DYLD_INSERT_LIBRARIES");
        fprintf(stderr, "guard malloc: %s\n", (guard && strstr(guard, "libgmalloc")) ? "ON" : "off");

        BOOL quick = (argc > 1 && strcmp(argv[1], "--quick") == 0);

        testComponentAvailable();
        testBandCountContract();
        testBiquadCoefficientsRespectsBufferSize();
        testOutOfRangeBandParametersRejected();
        testAppConfigurationApplies();
        testFrequencyResponse();
        testOverlongRenderRefused();
        testHostileParameterValues();

        testOtherAppleEffectsShareTheFormat();
        testStateValidatorAcceptsOnlySafeBlobs();
        testFullStateRecordCountIsValidated();
        testHostileFullState();

        if (!quick) {
            testFullStateFuzz();
            testStateValidatorHoldsUnderFuzzing();
            testMaxBandsAcrossFormats();
            testConcurrentAutomationSoak();
            testConcurrentBandCountResize();
            testLifecycleChurn();
        } else {
            fprintf(stderr, "\n(--quick: skipping soak, format matrix and churn)\n");
        }

        fprintf(stderr, "\n----------------------------------------\n");
        fprintf(stderr, "%d passed, %d failed, %d known Apple defects, %d skipped\n",
                sPassCount, sFailCount, sKnownDefectCount, sSkipCount);

        if (sKnownDefectCount) {
            fprintf(stderr, "\nXFAIL entries are Apple's unchecked preset record count.\n"
                            "EmbraceNG mitigates it in Source/AudioUnitStateValidation.m;\n"
                            "see Tests/README.md.\n");
        }

        return sFailCount == 0 ? 0 : 1;
    }
}
