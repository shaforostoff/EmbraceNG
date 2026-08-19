// (c) 2024 Ricci Adams
// MIT License (or) 1-clause BSD License

// Prefix.pch defines `auto` as __auto_type for the Objective-C sources.  This is
// Objective-C++, where libc++ needs `auto` to mean what C++ says it means.
#undef auto

#import "RestorationAudioUnit.h"

#import "declick_core.h"
#import "dehum_core.h"

#import <AVFoundation/AVFoundation.h>

#include <atomic>
#include <algorithm>
#include <cmath>

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

@interface RestorationAudioUnit : AUAudioUnit

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

@property (nonatomic, readonly) RestorationState *state;

@end


@implementation RestorationAudioUnit {
    AUAudioUnitBusArray *_inputBusArray;
    AUAudioUnitBusArray *_outputBusArray;
    AUAudioUnitBus      *_inputBus;
    AUAudioUnitBus      *_outputBus;
    AUParameterTree     *_parameterTree;

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
        dehum::Params p = paramsFrom(state);
        if (haveActive && p == active) return;

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


@interface DehumAudioUnit : RestorationAudioUnit
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


- (void) createDSP  { _dsp = new DehumDSP(); }
- (void) destroyDSP { delete _dsp; _dsp = NULL; }


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
