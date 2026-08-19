// (c) 2024 Ricci Adams
// MIT License (or) 1-clause BSD License

// Prefix.pch defines `auto` as __auto_type for the Objective-C sources.  This is
// Objective-C++, where libc++ needs `auto` to mean what C++ says it means.
#undef auto

#import "RestorationAudioUnit.h"

#import "declick_core.h"
#import "dehum_core.h"
#import "ParameterFormView.h"
#import "HugAudioFile.h"
#import "HugUtils.h"

#import <AVFoundation/AVFoundation.h>

#include <atomic>
#include <algorithm>
#include <cmath>
#include <vector>

extern const OSType EmbraceRestorationManufacturer = 'Embr';
extern const OSType EmbraceDeclickSubType          = 'dclk';
extern const OSType EmbraceDehumSubType            = 'dhum';

static const int sMaxChannels   = 2;
static const int sMaxParameters = 8;


// Bypass runs the DSP with a wet mix of zero rather than skipping it, which is
// what makes A/B useful: declick's latency stays put so the two versions line up
// sample for sample, and dehum's detector keeps tracking, so switching back does
// not cost the several seconds it takes to re-acquire a line.
//
struct RestorationState {
    std::atomic<float> value[sMaxParameters];
    std::atomic<bool>  bypassed;

    float defaultValue[sMaxParameters];

    RestorationState() : bypassed(false)
    {
        for (int i = 0; i < sMaxParameters; i++) {
            value[i].store(0, std::memory_order_relaxed);
            defaultValue[i] = 0;
        }
    }

    float get(int index) const { return value[index].load(std::memory_order_relaxed); }
    bool  isBypassed()   const { return bypassed.load(std::memory_order_relaxed); }
};


// Embrace's graph always hands us real buffers.  A host that does not is asking
// the unit to supply its own, which we do not, so say so rather than carrying a
// scratch buffer whose lifetime the render thread would have to reason about.
//
static AUAudioUnitStatus sPrepareBufferList(AudioBufferList *bufferList, AUAudioFrameCount frameCount)
{
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
        if (!bufferList->mBuffers[i].mData) return kAudioUnitErr_InvalidParameter;
        bufferList->mBuffers[i].mDataByteSize = frameCount * sizeof(float);
    }

    return noErr;
}


static AUParameter *sMakeParameter(
    NSString *identifier, NSString *name, AUParameterAddress address,
    AUValue min, AUValue max, AUValue value, AudioUnitParameterUnit unit)
{
    AUParameter *parameter = [AUParameterTree
        createParameterWithIdentifier: identifier
                                 name: name
                              address: address
                                  min: min
                                  max: max
                                 unit: unit
                             unitName: nil
                                flags: kAudioUnitParameterFlag_IsReadable |
                                       kAudioUnitParameterFlag_IsWritable
                         valueStrings: nil
                  dependentParameters: nil];

    [parameter setValue:value];

    return parameter;
}


#pragma mark - Base Unit

@interface RestorationAudioUnit : AUAudioUnit <ParameterDescribing>

// Subclass hooks, all main thread.  The DSP is built once in -init and freed in
// -dealloc so its address never moves: a render block captures that pointer, and
// a graph rebuild can leave an old block running for a moment after a new one
// has been handed out.
//
- (void) createDSP;
- (void) destroyDSP;
- (void) configureDSPWithSampleRate:(double)sampleRate channels:(int)channels;
- (NSArray<AUParameter *> *) createParameters;
- (AUInternalRenderBlock) createRenderBlock;

// One entry per parameter, in the order -createParameters returns them
- (NSArray<NSString *> *) createParameterHelp;

@property (nonatomic, readonly) RestorationState *state;

@end


@implementation RestorationAudioUnit {
    AUAudioUnitBusArray *_inputBusArray;
    AUAudioUnitBusArray *_outputBusArray;
    AUAudioUnitBus      *_inputBus;
    AUAudioUnitBus      *_outputBus;
    AUParameterTree     *_parameterTree;
    NSArray<NSString *> *_parameterHelp;

    RestorationState    *_state;
}

@synthesize parameterTree = _parameterTree;
@synthesize state = _state;


- (instancetype) initWithComponentDescription:(AudioComponentDescription)componentDescription
                                      options:(AudioComponentInstantiationOptions)options
                                        error:(NSError **)outError
{
    if ((self = [super initWithComponentDescription:componentDescription options:options error:outError])) {
        _state = new RestorationState();

        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];

        _inputBus  = [[AUAudioUnitBus alloc] initWithFormat:format error:nil];
        _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:nil];

        [_inputBus  setMaximumChannelCount:sMaxChannels];
        [_outputBus setMaximumChannelCount:sMaxChannels];

        _inputBusArray  = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput  busses:@[ _inputBus  ]];
        _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[ _outputBus ]];

        NSArray<AUParameter *> *parameters = [self createParameters];
        _parameterTree = [AUParameterTree createTreeWithChildren:parameters];
        _parameterHelp = [self createParameterHelp];

        RestorationState *state = _state;

        for (AUParameter *parameter in parameters) {
            AUParameterAddress address = [parameter address];

            state->value[address].store([parameter value], std::memory_order_relaxed);
            state->defaultValue[address] = [parameter value];
        }

        [_parameterTree setImplementorValueObserver:^(AUParameter *parameter, AUValue value) {
            state->value[[parameter address]].store(value, std::memory_order_relaxed);
        }];

        [_parameterTree setImplementorValueProvider:^AUValue(AUParameter *parameter) {
            return state->value[[parameter address]].load(std::memory_order_relaxed);
        }];

        [self createDSP];
        [self configureDSPWithSampleRate:44100 channels:2];
    }

    return self;
}


- (void) dealloc
{
    [self destroyDSP];

    delete _state;
    _state = NULL;
}


- (AUAudioUnitBusArray *) inputBusses  { return _inputBusArray;  }
- (AUAudioUnitBusArray *) outputBusses { return _outputBusArray; }

- (BOOL) canProcessInPlace { return YES; }


- (BOOL) allocateRenderResourcesAndReturnError:(NSError **)outError
{
    if (![super allocateRenderResourcesAndReturnError:outError]) {
        return NO;
    }

    AVAudioFormat *format = [_outputBus format];

    // The cores only touch the heap on their first configure at a given sample
    // rate, so getting that one out of the way here is what keeps every later
    // parameter move allocation-free on the render thread.
    [self configureDSPWithSampleRate: [format sampleRate]
                            channels: std::min((int)[format channelCount], sMaxChannels)];

    return YES;
}


- (void) setShouldBypassEffect:(BOOL)shouldBypassEffect
{
    [super setShouldBypassEffect:shouldBypassEffect];
    _state->bypassed.store(shouldBypassEffect ? true : false, std::memory_order_relaxed);
}


- (AUInternalRenderBlock) internalRenderBlock
{
    return [self createRenderBlock];
}


- (NSString *) embrace_helpTextForParameterAddress:(AUParameterAddress)address
{
    if (address >= [_parameterHelp count]) return nil;
    return [_parameterHelp objectAtIndex:address];
}


// The value each parameter was created with, i.e. Params::defaults().  Read by
// ParameterFormView so double-clicking one control resets just that control.
- (AUValue) embrace_defaultValueForParameterAddress:(AUParameterAddress)address
{
    if (address >= sMaxParameters) return 0;
    return _state->defaultValue[address];
}


#pragma mark - Subclass Hooks

- (void) createDSP { }
- (void) destroyDSP { }
- (void) configureDSPWithSampleRate:(double)sampleRate channels:(int)channels { }
- (NSArray<AUParameter *> *) createParameters { return @[ ]; }
- (NSArray<NSString *> *) createParameterHelp { return @[ ]; }
- (AUInternalRenderBlock) createRenderBlock { return nil; }

@end


#pragma mark - Declick

struct DeclickDSP {
    declick::Channel channel[sMaxChannels];
    declick::Params  active;
    declick::Config  cfg;

    double sampleRate = 44100;
    int    channels   = 2;
    bool   haveActive = false;
    bool   needsPrime = true;

    declick::Params paramsFrom(const RestorationState *state) const
    {
        declick::Params p = declick::Params::defaults();

        p.sensitivity = state->get(0);
        p.extent      = state->get(1);
        p.maxLengthMs = state->get(2);
        p.depth       = state->get(3);
        p.passes      = (int)lrintf(state->get(4));
        p.order       = (int)lrintf(state->get(5));
        p.dryWet      = state->isBypassed() ? 0.0f : state->get(6);
        p.sanitize();

        return p;
    }

    void update(const RestorationState *state)
    {
        declick::Params p = paramsFrom(state);
        if (haveActive && p == active) return;

        declick::Config next;
        next.compute(p, sampleRate);

        if (!needsPrime && next.structurallyEquals(cfg)) {
            bool retuned = true;

            for (int i = 0; i < channels; i++) {
                if (!channel[i].retune(next)) retuned = false;
            }

            if (retuned) {
                cfg = next;
                active = p;
                haveActive = true;
                return;
            }
        }

        // Only Max Repair and Model Order reach here.  Past the first call it
        // allocates nothing -- see the buffer envelope in declick::Config -- but
        // prime() does push `latency` samples through the model, so moving those
        // two under a live stream is not free.
        for (int i = 0; i < channels; i++) {
            channel[i].configure(next);
            channel[i].prime();
        }

        cfg = next;
        active = p;
        haveActive = true;
        needsPrime = false;
    }

    void restart(double rate, int chans)
    {
        sampleRate = rate;
        channels   = chans;
        haveActive = false;
        needsPrime = true;
    }

    void process(AudioBufferList *bufferList, AUAudioFrameCount frames)
    {
        int count = std::min((int)bufferList->mNumberBuffers, channels);

        for (int i = 0; i < count; i++) {
            float *samples = (float *)bufferList->mBuffers[i].mData;

            // prime() left `latency` samples in the pipe, so a pull the same
            // size as the push can never come up short.
            channel[i].push(samples, frames, 1);
            channel[i].pull(samples, frames, 1);
        }
    }
};


@interface DeclickAudioUnit : RestorationAudioUnit
@end


@implementation DeclickAudioUnit {
    DeclickDSP *_dsp;
}

- (NSArray<AUParameter *> *) createParameters
{
    declick::Params defaults = declick::Params::defaults();

    return @[
        sMakeParameter(@"sensitivity", NSLocalizedString(@"Sensitivity",  nil), 0, 0,   1,  defaults.sensitivity, kAudioUnitParameterUnit_Generic),
        sMakeParameter(@"extent",      NSLocalizedString(@"Extent",       nil), 1, 0,   1,  defaults.extent,      kAudioUnitParameterUnit_Generic),
        sMakeParameter(@"maxLength",   NSLocalizedString(@"Max Repair",   nil), 2, 0.2, 20, defaults.maxLengthMs, kAudioUnitParameterUnit_Milliseconds),
        sMakeParameter(@"depth",       NSLocalizedString(@"Repair Depth", nil), 3, 0,   1,  defaults.depth,       kAudioUnitParameterUnit_Generic),
        sMakeParameter(@"passes",      NSLocalizedString(@"Passes",       nil), 4, 1,   3,  defaults.passes,      kAudioUnitParameterUnit_Indexed),
        sMakeParameter(@"order",       NSLocalizedString(@"Model Order",  nil), 5, declick::kMinOrder, declick::kMaxOrder, defaults.order, kAudioUnitParameterUnit_Indexed),
        sMakeParameter(@"dryWet",      NSLocalizedString(@"Dry/Wet",      nil), 6, 0,   1,  defaults.dryWet,      kAudioUnitParameterUnit_Generic)
    ];
}


// Condensed from the rationale in declick_core.h, which has the measurements.
- (NSArray<NSString *> *) createParameterHelp
{
    return @[
        NSLocalizedString(@"How readily a sample is called a click. The default puts the trigger at "
            "3.9 sigma above the local noise estimate; on 78rpm tango transfers that takes impulsive "
            "events from roughly 71 per second down to 14. Raise it towards 0.8 to catch more, at the "
            "cost of flagging music as damage.", nil),

        NSLocalizedString(@"How far each detection spreads outwards into the tail of the click. "
            "Higher repairs more of the decay; too high starts replacing good audio either side of it.", nil),

        NSLocalizedString(@"The longest single stretch that may be reconstructed. Damage longer than "
            "this is left alone rather than guessed at.", nil),

        NSLocalizedString(@"How much of the estimated click is subtracted. 0 is the setting measured "
            "to add the least error of its own, against real clicks injected into a clean master at "
            "known positions. Raising it removes more of each click but substitutes more guesswork.", nil),

        NSLocalizedString(@"How many times the detector sweeps each block. A second pass catches "
            "clicks that the first pass's repairs uncover.", nil),

        NSLocalizedString(@"Taps in the autoregressive model that predicts what the waveform should "
            "have been. The lever that pays most: against injected-click ground truth, 128 takes "
            "whole-file error from +0.60 to +1.31 dB and 256 to +2.55 dB. It also costs real CPU and "
            "adds latency, which is why the default stops at 64.", nil),

        NSLocalizedString(@"Blend of the repaired signal against the original. 0 passes the input "
            "through untouched.", nil)
    ];
}


- (void) createDSP  { _dsp = new DeclickDSP(); }
- (void) destroyDSP { delete _dsp; _dsp = NULL; }


- (void) configureDSPWithSampleRate:(double)sampleRate channels:(int)channels
{
    _dsp->restart(sampleRate, channels);
    _dsp->update([self state]);
}


- (NSTimeInterval) latency
{
    return _dsp->cfg.latency / _dsp->sampleRate;
}


- (AUInternalRenderBlock) createRenderBlock
{
    DeclickDSP       *dsp   = _dsp;
    RestorationState *state = [self state];

    return ^AUAudioUnitStatus(
        AudioUnitRenderActionFlags *actionFlags,
        const AudioTimeStamp       *timestamp,
        AUAudioFrameCount           frameCount,
        NSInteger                   outputBusNumber,
        AudioBufferList            *outputData,
        const AURenderEvent        *realtimeEventListHead,
        AURenderPullInputBlock      pullInputBlock)
    {
        if (!pullInputBlock) return kAudioUnitErr_NoConnection;

        AUAudioUnitStatus err = sPrepareBufferList(outputData, frameCount);
        if (err) return err;

        AudioUnitRenderActionFlags pullFlags = 0;
        err = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData);
        if (err) return err;

        declick::scoped_flush_denormals ftz;

        dsp->update(state);
        dsp->process(outputData, frameCount);

        return noErr;
    };
}

@end


#pragma mark - Dehum

struct DehumDSP {
    dehum::Channel channel[sMaxChannels];
    dehum::Params  active;
    dehum::Config  cfg;

    double sampleRate = 44100;
    int    channels   = 2;
    bool   haveActive = false;
    bool   configured = false;

    // Published by the main thread once a scout finishes, consumed on the render
    // thread.  Handed to Channel::adopt(), which starts them confirmed and leaves
    // the detector running -- so it keeps tracking them, drops them again if the
    // evidence is not there, and can still find lines the scout missed.
    dehum::LineReport pendingLines[dehum::kMaxLines];
    int               pendingCount;
    std::atomic<bool> pendingReady;

    std::atomic<bool> forgetPending;

    // Bumped per track.  A scout reads a minute of audio, which is long enough
    // that someone working through a set list can leave several in flight.
    std::atomic<long>  scoutGeneration;

    DehumDSP() : pendingCount(0), pendingReady(false), forgetPending(false), scoutGeneration(0) { }

    dehum::Params paramsFrom(const RestorationState *state) const
    {
        dehum::Params p = dehum::Params::defaults();

        p.sensitivity = state->get(0);
        p.bandwidth   = state->get(1);
        p.searchTo    = state->get(2);
        p.harmonics   = (int)lrintf(state->get(3));
        p.frequency   = state->get(4);
        p.rumbleHz    = state->get(5);
        p.dryWet      = state->isBypassed() ? 0.0f : state->get(6);
        p.sanitize();

        return p;
    }

    void update(const RestorationState *state)
    {
        // A new record means a new hum, so nothing carries over.  reset() only
        // memsets buffers it already holds, so this is safe here.
        if (forgetPending.exchange(false, std::memory_order_relaxed)) {
            for (int i = 0; i < channels; i++) {
                channel[i].reset();
            }
        }

        dehum::Params p = paramsFrom(state);

        if (!haveActive || p != active) {
            dehum::Config next;
            next.compute(p, sampleRate);

            // Only the sample rate sizes anything here, so every parameter move
            // retunes in place and the lines already acquired survive it.
            bool retuned = configured && next.structurallyEquals(cfg);

            if (retuned) {
                for (int i = 0; i < channels; i++) {
                    if (!channel[i].retune(next)) retuned = false;
                }
            }

            if (!retuned) {
                for (int i = 0; i < channels; i++) {
                    channel[i].configure(next);
                }

                configured = true;
            }

            cfg = next;
            active = p;
            haveActive = true;
        }

        // Last of all, because configure() ends in reset() and would discard them
        if (pendingReady.load(std::memory_order_acquire)) {
            // Copied out first: a track change can republish while we are here,
            // and adopt() should see one coherent set rather than half of two.
            dehum::LineReport lines[dehum::kMaxLines];
            int count = pendingCount;

            if (count > (int)dehum::kMaxLines) count = (int)dehum::kMaxLines;
            for (int i = 0; i < count; i++) lines[i] = pendingLines[i];

            pendingReady.store(false, std::memory_order_relaxed);

            for (int i = 0; i < channels; i++) {
                channel[i].adopt(lines, count);
            }
        }
    }

    void restart(double rate, int chans)
    {
        sampleRate = rate;
        channels   = chans;
        haveActive = false;
        configured = false;
    }

    void process(AudioBufferList *bufferList, AUAudioFrameCount frames)
    {
        int count = std::min((int)bufferList->mNumberBuffers, channels);

        for (int i = 0; i < count; i++) {
            channel[i].process((float *)bufferList->mBuffers[i].mData, frames, 1);
        }
    }
};



// Reads the opening of a file and returns the line dehum settles on, in Hz, or 0
// if it found nothing worth cancelling.  Off the main thread.
//
// Analysed at the file's own sample rate, which saves resampling it: a hum sits
// at the same frequency in Hz whatever rate you look at it from, so the figure
// transfers straight to the live unit running at the device rate.
//
// Sixty seconds, which is not generous.  Measured on 78rpm tango transfers: a
// line the prominence route can see turns up inside 15 s, but one sitting down in
// the rumble - 7.8 dB prominent, well under the 16 dB threshold - only reaches the
// coherence route at 43 s, because that ratio accumulates over kCohWindowSec.
// Those are exactly the transfers this is worth doing for, so the window has to
// cover them.  Costs about 1.7 s of one core for 60 s of mono audio.
//
static int sScoutHumLines(NSURL *fileURL, float sensitivity, float searchTo,
                          const std::atomic<long> *generationNow, long generation,
                          dehum::LineReport *out, int max)
{
    static const double sSecondsToRead = 60.0;
    static const UInt32 sBlockFrames   = 4096;

    HugAudioFile *file = [[HugAudioFile alloc] initWithFileURL:fileURL];
    if (![file open]) return 0;

    double    rate         = [file sampleRate];
    NSInteger fileChannels = [file channelCount];

    if (rate <= 0 || fileChannels < 1) {
        [file close];
        return 0;
    }

    dehum::Params p = dehum::Params::defaults();
    p.sensitivity = sensitivity;
    p.searchTo    = searchTo;
    p.frequency   = 0;
    p.sanitize();

    dehum::Config cfg;
    cfg.compute(p, rate);

    dehum::Channel channel;
    channel.configure(cfg);

    AudioBufferList *bufferList = HugAudioBufferListCreate((UInt32)fileChannels, sBlockFrames, YES);
    if (!bufferList) {
        [file close];
        return 0;
    }

    // Hum is common mode, so one summed channel finds it for half the work
    std::vector<float> mono(sBlockFrames);

    SInt64 wanted = (SInt64)(sSecondsToRead * rate);
    SInt64 read   = 0;

    {
        dehum::scoped_flush_denormals ftz;

        while (read < wanted) {
            UInt32 frames = sBlockFrames;
            if ((SInt64)frames > (wanted - read)) frames = (UInt32)(wanted - read);

            // ExtAudioFileRead updates these, so they go back each time
            for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
                bufferList->mBuffers[i].mDataByteSize = frames * sizeof(float);
            }

            if (![file readFrames:&frames intoBufferList:bufferList]) break;
            if (frames == 0) break;

            // Another track started; whatever this finds is already stale
            if (generationNow->load(std::memory_order_relaxed) != generation) {
                HugAudioBufferListFree(bufferList, YES);
                [file close];
                return 0;
            }

            for (UInt32 f = 0; f < frames; f++) mono[f] = 0;

            for (UInt32 c = 0; c < bufferList->mNumberBuffers; c++) {
                const float *source = (const float *)bufferList->mBuffers[c].mData;
                if (!source) continue;

                for (UInt32 f = 0; f < frames; f++) mono[f] += source[f];
            }

            float scale = 1.0f / (float)bufferList->mNumberBuffers;
            for (UInt32 f = 0; f < frames; f++) mono[f] *= scale;

            channel.process(mono.data(), frames, 1);
            read += frames;
        }
    }

    HugAudioBufferListFree(bufferList, YES);
    [file close];

    int count = 0;
    channel.report(out, max, &count);

    return count;
}


@interface DehumAudioUnit : RestorationAudioUnit <EmbraceTrackScouting>
@end


@implementation DehumAudioUnit {
    DehumDSP *_dsp;
}

- (NSArray<AUParameter *> *) createParameters
{
    dehum::Params defaults = dehum::Params::defaults();

    // Frequency and Rumble both take zero as an off position rather than as a
    // frequency: 0 Hz means detect automatically, and no high-pass at all.
    return @[
        sMakeParameter(@"sensitivity", NSLocalizedString(@"Sensitivity", nil), 0, 0,   1,   defaults.sensitivity, kAudioUnitParameterUnit_Generic),
        sMakeParameter(@"bandwidth",   NSLocalizedString(@"Bandwidth",   nil), 1, 0.1, 5,   defaults.bandwidth,   kAudioUnitParameterUnit_Hertz),
        sMakeParameter(@"searchTo",    NSLocalizedString(@"Search To",   nil), 2, 40,  dehum::kSearchCeil,   defaults.searchTo,  kAudioUnitParameterUnit_Hertz),
        sMakeParameter(@"harmonics",   NSLocalizedString(@"Harmonics",   nil), 3, 1,   dehum::kMaxHarmonics, defaults.harmonics, kAudioUnitParameterUnit_Indexed),
        sMakeParameter(@"frequency",   NSLocalizedString(@"Frequency",   nil), 4, 0,   500, defaults.frequency,   kAudioUnitParameterUnit_Hertz),
        sMakeParameter(@"rumble",      NSLocalizedString(@"Rumble",      nil), 5, 0,   200, defaults.rumbleHz,    kAudioUnitParameterUnit_Hertz),
        sMakeParameter(@"dryWet",      NSLocalizedString(@"Dry/Wet",     nil), 6, 0,   1,   defaults.dryWet,      kAudioUnitParameterUnit_Generic)
    ];
}


// Condensed from the rationale in dehum_core.h, which has the measurements.
- (NSArray<NSString *> *) createParameterHelp
{
    return @[
        NSLocalizedString(@"How far a spectral peak must stand above its surroundings before it "
            "counts as a tone. The default maps to a 16 dB prominence threshold, which the reference "
            "hum clears on 87% of analysis hops while hum-free material manages at most 10%. Past "
            "about 0.7, clean material starts qualifying.", nil),

        NSLocalizedString(@"Half width of each notch. 1 Hz costs nothing musically - a partial 5 Hz "
            "away loses 0.15 dB - and is wide enough to absorb the detector's own error before the "
            "frequency tracker converges on the line.", nil),

        NSLocalizedString(@"Top of the range searched for hum automatically. Hum lives low; searching "
            "higher finds sustained musical notes instead - during calibration a bandoneon E4 at "
            "329 Hz was detected as hum and duly cancelled.", nil),

        NSLocalizedString(@"Multiples of each detected line to cancel as well. Mains buzz has them; "
            "the off-frequency drones on speed-corrected disc transfers usually do not, and the extra "
            "notches land squarely in the musical register.", nil),

        NSLocalizedString(@"0 detects the line automatically, which needs a few seconds of steady "
            "evidence before it engages. Set a frequency to pin the notch there instead, when you "
            "already know what you are removing.", nil),

        NSLocalizedString(@"High-pass corner for broadband turntable rumble - a separate defect that "
            "happens to share the band with hum. 0 turns it off. Higher removes more rumble, and more "
            "of the bass along with it.", nil),

        NSLocalizedString(@"Blend of the processed signal against the original. 0 passes the input "
            "through untouched.", nil)
    ];
}


- (void) createDSP  { _dsp = new DehumDSP(); }
- (void) destroyDSP { delete _dsp; _dsp = NULL; }


- (void) embrace_scoutFileURL:(NSURL *)fileURL
{
    RestorationState *state = [self state];

    // Whatever the last record's hum was, it is not this one's
    _dsp->pendingReady.store(false, std::memory_order_relaxed);
    _dsp->forgetPending.store(true, std::memory_order_relaxed);

    // A frequency the user pinned by hand is theirs, not ours to overwrite
    if (!fileURL || state->get(4) > 0) return;

    float sensitivity = state->get(0);
    float searchTo    = state->get(2);

    long generation = _dsp->scoutGeneration.fetch_add(1, std::memory_order_relaxed) + 1;

    // self is captured strongly on purpose: it keeps the DSP alive for the scout
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // A vector rather than an array so the inner block can capture it
        std::vector<dehum::LineReport> lines((size_t)dehum::kMaxLines);

        int count = sScoutHumLines(fileURL, sensitivity, searchTo,
                                   &_dsp->scoutGeneration, generation,
                                   lines.data(), (int)dehum::kMaxLines);
        lines.resize((size_t)count);

        dispatch_async(dispatch_get_main_queue(), ^{
            // A later track already started; its scout owns the lines now
            if (_dsp->scoutGeneration.load(std::memory_order_relaxed) != generation) return;

            NSMutableArray *described = [NSMutableArray array];
            for (size_t i = 0; i < lines.size(); i++) {
                [described addObject:[NSString stringWithFormat:@"%.3f Hz (%s)",
                    lines[i].frequency, lines[i].viaCoherence ? "coherence" : "prominence"]];

                _dsp->pendingLines[i] = lines[i];
            }

            EmbraceLog(@"Dehum", @"scouted %@: %@", [fileURL lastPathComponent],
                [described count] ? [described componentsJoinedByString:@", "]
                                  : @"no line, leaving it to the detector");

            _dsp->pendingCount = (int)lines.size();
            _dsp->pendingReady.store(!lines.empty(), std::memory_order_release);
        });
    });
}


- (void) configureDSPWithSampleRate:(double)sampleRate channels:(int)channels
{
    _dsp->restart(sampleRate, channels);
    _dsp->update([self state]);
}


- (AUInternalRenderBlock) createRenderBlock
{
    DehumDSP         *dsp   = _dsp;
    RestorationState *state = [self state];

    return ^AUAudioUnitStatus(
        AudioUnitRenderActionFlags *actionFlags,
        const AudioTimeStamp       *timestamp,
        AUAudioFrameCount           frameCount,
        NSInteger                   outputBusNumber,
        AudioBufferList            *outputData,
        const AURenderEvent        *realtimeEventListHead,
        AURenderPullInputBlock      pullInputBlock)
    {
        if (!pullInputBlock) return kAudioUnitErr_NoConnection;

        AUAudioUnitStatus err = sPrepareBufferList(outputData, frameCount);
        if (err) return err;

        AudioUnitRenderActionFlags pullFlags = 0;
        err = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData);
        if (err) return err;

        dehum::scoped_flush_denormals ftz;

        dsp->update(state);
        dsp->process(outputData, frameCount);

        return noErr;
    };
}

@end


#pragma mark - Registration

void EmbraceRegisterRestorationAudioUnits(void)
{
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        AudioComponentDescription acd = {0};

        acd.componentType         = kAudioUnitType_Effect;
        acd.componentManufacturer = EmbraceRestorationManufacturer;
        acd.componentFlags        = 0;
        acd.componentFlagsMask    = 0;

        // EffectType splits these at the colon and stores the part after it, so
        // that is what has to stay put.  EffectAdditions maps it to a friendlier
        // name for the menus.
        acd.componentSubType = EmbraceDeclickSubType;
        [AUAudioUnit registerSubclass: [DeclickAudioUnit class]
               asComponentDescription: acd
                                 name: @"Embrace: EmbraceDeclick"
                              version: 1];

        acd.componentSubType = EmbraceDehumSubType;
        [AUAudioUnit registerSubclass: [DehumAudioUnit class]
               asComponentDescription: acd
                                 name: @"Embrace: EmbraceDehum"
                              version: 1];
    });
}
