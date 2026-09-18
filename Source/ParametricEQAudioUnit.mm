// (c) 2026 EmbraceNG contributors
// MIT License (or) 1-clause BSD License

// Prefix.pch defines `auto` as __auto_type for the Objective-C sources.  This is
// Objective-C++, where libc++ needs `auto` to mean what C++ says it means.
#undef auto

#import "ParametricEQAudioUnit.h"

#import "ParametricEQView.h"
#import "ParameterFormView.h"
#import "EmbraceAudioUnitUtils.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreAudioKit/CoreAudioKit.h>

#include <atomic>
#include <algorithm>
#include <cmath>

extern const OSType EmbraceParametricEQManufacturer = 'Embr';
extern const OSType EmbraceParametricEQSubType      = 'peq5';

static const int sMaxChannels = 2;


// Parameter values, published by the main thread and read by the render thread.
// Relaxed ordering throughout: each is independent, and a control move landing
// one render early or late is not something anyone can hear.
//
struct ParametricEQState {
    std::atomic<float> value[EmbraceParametricEQParameterCount];
    std::atomic<bool>  bypassed;

    float defaultValue[EmbraceParametricEQParameterCount];

    ParametricEQState() : bypassed(false)
    {
        for (int i = 0; i < EmbraceParametricEQParameterCount; i++) {
            value[i].store(0, std::memory_order_relaxed);
            defaultValue[i] = 0;
        }
    }

    float get(int index) const { return value[index].load(std::memory_order_relaxed); }
    bool  isBypassed()   const { return bypassed.load(std::memory_order_relaxed); }
};


// The one place the fifteen parameters become core parameters.  Both the render
// thread, reading atomics, and the editor, reading the parameter tree, arrive
// here, so the curve on screen cannot disagree with what the audio is doing.
//
static paraeq::Params sParamsFromValues(const float *values)
{
    paraeq::Params p = paraeq::Params::defaults();

    p.hpFrequency  = values[EmbraceParametricEQParameterFilterFrequency];
    p.hpSlope      = (int)lrintf(values[EmbraceParametricEQParameterFilterSlope]);

    p.lfGain       = values[EmbraceParametricEQParameterLFGain];
    p.lfFrequency  = values[EmbraceParametricEQParameterLFFrequency];
    p.lfBell       = values[EmbraceParametricEQParameterLFBell] >= 0.5f;

    p.lmfGain      = values[EmbraceParametricEQParameterLMFGain];
    p.lmfFrequency = values[EmbraceParametricEQParameterLMFFrequency];
    p.lmfQ         = values[EmbraceParametricEQParameterLMFQ];

    p.hmfGain      = values[EmbraceParametricEQParameterHMFGain];
    p.hmfFrequency = values[EmbraceParametricEQParameterHMFFrequency];
    p.hmfQ         = values[EmbraceParametricEQParameterHMFQ];

    p.hfGain       = values[EmbraceParametricEQParameterHFGain];
    p.hfFrequency  = values[EmbraceParametricEQParameterHFFrequency];
    p.hfBell       = values[EmbraceParametricEQParameterHFBell] >= 0.5f;

    p.outputGain   = values[EmbraceParametricEQParameterOutputGain];

    p.sanitize();

    return p;
}


paraeq::Params EmbraceParametricEQParamsFromTree(AUParameterTree *parameterTree)
{
    float values[EmbraceParametricEQParameterCount] = { 0 };

    for (int i = 0; i < EmbraceParametricEQParameterCount; i++) {
        AUParameter *parameter = [parameterTree parameterWithAddress:(AUParameterAddress)i];
        values[i] = parameter ? [parameter value] : 0;
    }

    return sParamsFromValues(values);
}


#pragma mark - DSP

struct ParametricEQDSP {
    paraeq::Channel channel[sMaxChannels];
    paraeq::Params  active;
    paraeq::Config  cfg;

    double sampleRate = 44100;
    int    channels   = 2;
    bool   haveActive = false;

    paraeq::Params paramsFrom(const ParametricEQState *state) const
    {
        float values[EmbraceParametricEQParameterCount];

        for (int i = 0; i < EmbraceParametricEQParameterCount; i++) {
            values[i] = state->get(i);
        }

        paraeq::Params p = sParamsFromValues(values);

        // Bypass is a target rather than a branch, so the curve flattens over
        // the glide instead of switching.  See the core's header for why an EQ
        // must not do this by blending a dry path in.
        p.bypass = state->isBypassed();

        return p;
    }

    void update(const ParametricEQState *state)
    {
        paraeq::Params p = paramsFrom(state);
        if (haveActive && p == active) return;

        cfg.compute(p, sampleRate);

        // retune(), not configure(): the coefficients glide from wherever they
        // are, which is what makes a knob move silent.  It allocates nothing
        // and cannot fail, so the render thread may do this every block.
        for (int i = 0; i < channels; i++) {
            channel[i].retune(cfg);
        }

        active = p;
        haveActive = true;
    }

    // Snaps rather than glides, because a stream that is starting has nothing
    // to glide from: gliding here would fade the equaliser in over the first
    // third of a second of every track.
    void restart(double rate, int chans, const ParametricEQState *state)
    {
        sampleRate = rate;
        channels   = std::min(chans, sMaxChannels);

        paraeq::Params p = paramsFrom(state);
        cfg.compute(p, sampleRate);

        for (int i = 0; i < channels; i++) {
            channel[i].configure(cfg);
        }

        active     = p;
        haveActive = true;
    }

    void process(AudioBufferList *bufferList, AUAudioFrameCount frames)
    {
        int count = std::min((int)bufferList->mNumberBuffers, channels);

        for (int i = 0; i < count; i++) {
            channel[i].process((float *)bufferList->mBuffers[i].mData, frames, 1);
        }
    }
};


#pragma mark - Audio Unit

@interface ParametricEQAudioUnit : AUAudioUnit <ParameterDescribing>
@end


@implementation ParametricEQAudioUnit {
    AUAudioUnitBusArray *_inputBusArray;
    AUAudioUnitBusArray *_outputBusArray;
    AUAudioUnitBus      *_inputBus;
    AUAudioUnitBus      *_outputBus;
    AUParameterTree     *_parameterTree;
    NSArray<NSString *> *_parameterHelp;

    ParametricEQState   *_state;
    ParametricEQDSP     *_dsp;
}

@synthesize parameterTree = _parameterTree;


- (instancetype) initWithComponentDescription:(AudioComponentDescription)componentDescription
                                      options:(AudioComponentInstantiationOptions)options
                                        error:(NSError **)outError
{
    if ((self = [super initWithComponentDescription:componentDescription options:options error:outError])) {
        _state = new ParametricEQState();

        // Built once here and freed in -dealloc so its address never moves: a
        // render block captures that pointer, and a graph rebuild can leave an
        // old block running for a moment after a new one has been handed out.
        _dsp = new ParametricEQDSP();

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

        ParametricEQState *state = _state;

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

        _dsp->restart(44100, 2, _state);
    }

    return self;
}


- (void) dealloc
{
    delete _dsp;
    _dsp = NULL;

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

    _dsp->restart([format sampleRate], (int)[format channelCount], _state);

    return YES;
}


- (void) setShouldBypassEffect:(BOOL)shouldBypassEffect
{
    [super setShouldBypassEffect:shouldBypassEffect];
    _state->bypassed.store(shouldBypassEffect ? true : false, std::memory_order_relaxed);
}


- (AUInternalRenderBlock) internalRenderBlock
{
    ParametricEQDSP   *dsp   = _dsp;
    ParametricEQState *state = _state;

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

        AUAudioUnitStatus err = EmbraceAUPrepareBufferList(outputData, frameCount);
        if (err) return err;

        AudioUnitRenderActionFlags pullFlags = 0;
        err = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData);
        if (err) return err;

        paraeq::scoped_flush_denormals ftz;

        dsp->update(state);
        dsp->process(outputData, frameCount);

        return noErr;
    };
}


#pragma mark - Editor

// An editor of our own is the whole reason this unit exists, so it is not
// optional: -[EditSystemEffectController windowDidLoad] asks for one only when
// this says yes, and falls back to a form built from the parameter tree
// otherwise.  The form is a perfectly good editor -- ParameterDescribing below
// keeps it that way -- but a console strip is what the controls are shaped like.
//
- (BOOL) providesUserInterface
{
    return YES;
}


- (void) requestViewControllerWithCompletionHandler:(void (^)(AUViewControllerBase *))completionHandler
{
    if (!completionHandler) return;

    ParametricEQView *view = [[ParametricEQView alloc] initWithAudioUnit:self];

    NSViewController *viewController = [[NSViewController alloc] init];
    [viewController setView:view];

    completionHandler(viewController);
}


#pragma mark - ParameterDescribing

- (NSString *) embrace_helpTextForParameterAddress:(AUParameterAddress)address
{
    if (address >= [_parameterHelp count]) return nil;
    return [_parameterHelp objectAtIndex:address];
}


- (AUValue) embrace_defaultValueForParameterAddress:(AUParameterAddress)address
{
    if (address >= EmbraceParametricEQParameterCount) return 0;
    return _state->defaultValue[address];
}


#pragma mark - Parameters

- (NSArray<AUParameter *> *) createParameters
{
    paraeq::Params d = paraeq::Params::defaults();

    NSArray<NSString *> *slopeStrings = @[
        NSLocalizedString(@"Off", nil),
        NSLocalizedString(@"12 dB/oct", nil),
        NSLocalizedString(@"24 dB/oct", nil)
    ];

    NSArray<NSString *> *shapeStrings = @[
        NSLocalizedString(@"Shelf", nil),
        NSLocalizedString(@"Bell", nil)
    ];

    return @[
        EmbraceAUMakeParameter(@"filterFrequency", NSLocalizedString(@"Filter Frequency", nil),
            EmbraceParametricEQParameterFilterFrequency,
            paraeq::kHpFreqMin, paraeq::kHpFreqMax, d.hpFrequency,
            kAudioUnitParameterUnit_Hertz, nil),

        EmbraceAUMakeParameter(@"filterSlope", NSLocalizedString(@"Filter Slope", nil),
            EmbraceParametricEQParameterFilterSlope,
            0, 2, d.hpSlope, kAudioUnitParameterUnit_Indexed, slopeStrings),

        EmbraceAUMakeParameter(@"lfGain", NSLocalizedString(@"LF Gain", nil),
            EmbraceParametricEQParameterLFGain,
            -paraeq::kGainMaxDb, paraeq::kGainMaxDb, d.lfGain,
            kAudioUnitParameterUnit_Decibels, nil),

        EmbraceAUMakeParameter(@"lfFrequency", NSLocalizedString(@"LF Frequency", nil),
            EmbraceParametricEQParameterLFFrequency,
            paraeq::kLfFreqMin, paraeq::kLfFreqMax, d.lfFrequency,
            kAudioUnitParameterUnit_Hertz, nil),

        EmbraceAUMakeParameter(@"lfBell", NSLocalizedString(@"LF Shape", nil),
            EmbraceParametricEQParameterLFBell,
            0, 1, d.lfBell ? 1 : 0, kAudioUnitParameterUnit_Indexed, shapeStrings),

        EmbraceAUMakeParameter(@"lmfGain", NSLocalizedString(@"LMF Gain", nil),
            EmbraceParametricEQParameterLMFGain,
            -paraeq::kGainMaxDb, paraeq::kGainMaxDb, d.lmfGain,
            kAudioUnitParameterUnit_Decibels, nil),

        EmbraceAUMakeParameter(@"lmfFrequency", NSLocalizedString(@"LMF Frequency", nil),
            EmbraceParametricEQParameterLMFFrequency,
            paraeq::kLmfFreqMin, paraeq::kLmfFreqMax, d.lmfFrequency,
            kAudioUnitParameterUnit_Hertz, nil),

        EmbraceAUMakeParameter(@"lmfQ", NSLocalizedString(@"LMF Q", nil),
            EmbraceParametricEQParameterLMFQ,
            paraeq::kQMin, paraeq::kQMax, d.lmfQ,
            kAudioUnitParameterUnit_Generic, nil),

        EmbraceAUMakeParameter(@"hmfGain", NSLocalizedString(@"HMF Gain", nil),
            EmbraceParametricEQParameterHMFGain,
            -paraeq::kGainMaxDb, paraeq::kGainMaxDb, d.hmfGain,
            kAudioUnitParameterUnit_Decibels, nil),

        EmbraceAUMakeParameter(@"hmfFrequency", NSLocalizedString(@"HMF Frequency", nil),
            EmbraceParametricEQParameterHMFFrequency,
            paraeq::kHmfFreqMin, paraeq::kHmfFreqMax, d.hmfFrequency,
            kAudioUnitParameterUnit_Hertz, nil),

        EmbraceAUMakeParameter(@"hmfQ", NSLocalizedString(@"HMF Q", nil),
            EmbraceParametricEQParameterHMFQ,
            paraeq::kQMin, paraeq::kQMax, d.hmfQ,
            kAudioUnitParameterUnit_Generic, nil),

        EmbraceAUMakeParameter(@"hfGain", NSLocalizedString(@"HF Gain", nil),
            EmbraceParametricEQParameterHFGain,
            -paraeq::kGainMaxDb, paraeq::kGainMaxDb, d.hfGain,
            kAudioUnitParameterUnit_Decibels, nil),

        EmbraceAUMakeParameter(@"hfFrequency", NSLocalizedString(@"HF Frequency", nil),
            EmbraceParametricEQParameterHFFrequency,
            paraeq::kHfFreqMin, paraeq::kHfFreqMax, d.hfFrequency,
            kAudioUnitParameterUnit_Hertz, nil),

        EmbraceAUMakeParameter(@"hfBell", NSLocalizedString(@"HF Shape", nil),
            EmbraceParametricEQParameterHFBell,
            0, 1, d.hfBell ? 1 : 0, kAudioUnitParameterUnit_Indexed, shapeStrings),

        EmbraceAUMakeParameter(@"outputGain", NSLocalizedString(@"Output", nil),
            EmbraceParametricEQParameterOutputGain,
            -paraeq::kOutputMaxDb, paraeq::kOutputMaxDb, d.outputGain,
            kAudioUnitParameterUnit_Decibels, nil)
    ];
}


// One entry per parameter, in the order -createParameters returns them.  These
// say what each control is *for* on a disc transfer, because the layout is only
// worth having if the operator knows which knob is the hiss.
//
- (NSArray<NSString *> *) createParameterHelp
{
    return @[
        NSLocalizedString(@"Corner of the high-pass filter, which is what takes out turntable "
            "rumble and the roar under a disc transfer. Wind it up until the bottom stops "
            "wallowing; past about 120 Hz it is removing the double bass along with the rumble.", nil),

        NSLocalizedString(@"Steepness of the high-pass. Off leaves the filter out entirely. "
            "24 dB/oct clears rumble while staying closer to the corner, which is usually what a "
            "worn transfer wants; 12 dB/oct is the gentler slope where the low end is worth "
            "keeping.", nil),

        NSLocalizedString(@"The bass knob. Cut and boost at the LF frequency, and on transfers "
            "from 1926-1949 this is the one that puts back the weight the recording chain never "
            "captured.", nil),

        NSLocalizedString(@"Where the bass shelf turns over. 60-125 Hz is the band those "
            "transfers are short of; keeping it there leaves the cello and the double bass "
            "alone.", nil),

        NSLocalizedString(@"Shelf lifts or drops everything below the frequency. Bell "
            "concentrates the same move around it, for when only one part of the low end needs "
            "the help.", nil),

        NSLocalizedString(@"The knob that takes the room out. Cut here and the boxiness a "
            "recording horn or a hall adds goes with it - around 1 kHz on most of this material. "
            "Narrow the Q first if what you are removing is a single ring rather than a general "
            "thickness.", nil),

        NSLocalizedString(@"Centre of the low-mid band. Sweep it with a few dB of boost to find "
            "what is honking, then cut there.", nil),

        NSLocalizedString(@"How wide the low-mid band is. Low values are broad and musical; high "
            "values are narrow enough to take out a resonance without taking the music either "
            "side of it.", nil),

        NSLocalizedString(@"The brilliance knob. 4-6 kHz is where the detail on a shellac sits, "
            "under the surface noise rather than above it, so a boost here brings up the "
            "instrument and the noise together - which is what the HF band is then for.", nil),

        NSLocalizedString(@"Centre of the high-mid band. 5 kHz is the middle of the brilliance "
            "range and far enough below the hiss shelf that the two knobs do not fight.", nil),

        NSLocalizedString(@"How wide the high-mid band is. Broad for brilliance, narrow for a "
            "single piercing partial.", nil),

        NSLocalizedString(@"The hiss knob. Most shellacs carry little programme above 8 kHz and a "
            "great deal of surface noise, so this generally goes down. Pull it only as far as the "
            "cymbals and the bandoneon reeds allow.", nil),

        NSLocalizedString(@"Where the high shelf turns over. Lower reaches further down into the "
            "noise and further into the music with it.", nil),

        NSLocalizedString(@"Shelf drops or lifts everything above the frequency. Bell concentrates "
            "the move around it, which is the better shape when the noise sits in a band rather "
            "than across the whole top.", nil),

        NSLocalizedString(@"Makeup for whatever the bands did, so the equaliser can be compared "
            "against bypass at the same loudness. Boosting four bands and leaving this at 0 dB is "
            "how an EQ ends up sounding better than it is.", nil)
    ];
}

@end


#pragma mark - Registration

void EmbraceRegisterParametricEQAudioUnit(void)
{
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        AudioComponentDescription acd = {0};

        acd.componentType         = kAudioUnitType_Effect;
        acd.componentSubType      = EmbraceParametricEQSubType;
        acd.componentManufacturer = EmbraceParametricEQManufacturer;
        acd.componentFlags        = 0;
        acd.componentFlagsMask    = 0;

        // EffectType splits this at the colon and stores the part after it, so
        // that is what has to stay put.  EffectAdditions maps it to a friendlier
        // name for the menus.
        [AUAudioUnit registerSubclass: [ParametricEQAudioUnit class]
               asComponentDescription: acd
                                 name: @"Embrace: EmbraceParametricEQ"
                              version: 1];
    });
}
