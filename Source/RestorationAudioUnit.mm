// (c) 2024 Ricci Adams
// MIT License (or) 1-clause BSD License

// Prefix.pch defines `auto` as __auto_type for the Objective-C sources.  This is
// Objective-C++, where libc++ needs `auto` to mean what C++ says it means.
#undef auto

#import "RestorationAudioUnit.h"
#import "EmbraceAudioUnitUtils.h"

#import "declick_core.h"
#import "dehum_core.h"
#import "ParameterFormView.h"
#import "HugAudioFile.h"
#import "HugUtils.h"

#import <AVFoundation/AVFoundation.h>

#include <atomic>
#include <memory>
#include <algorithm>
#include <cmath>
#include <vector>

extern const OSType EmbraceRestorationManufacturer = 'Embr';
extern const OSType EmbraceDeclickSubType          = 'dclk';
extern const OSType EmbraceDehumSubType            = 'dhum';

static const int sMaxChannels   = 2;
static const int sMaxParameters = 10;


// Bypass runs the DSP with a wet mix of zero rather than skipping it, which is
// what makes A/B useful: declick keeps reading ahead by the same amount, so the
// two versions line up sample for sample, and dehum's detector keeps tracking, so
// switching back does not cost the several seconds it takes to re-acquire a line.
// Bypass clears delta too, or a zero wet mix would leave nothing to hear at all.
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

        // Built, not configured.  -allocateRenderResources is the first point
        // at which the real sample rate and channel count are known, and it
        // configures before anything can render; configuring here as well only
        // sized a 44.1 kHz envelope for that call to throw away -- 4.4 MB of it
        // per unit, on every stream that is not 44.1 kHz.  Both cores construct
        // without touching the heap, so an unconfigured DSP costs nothing, and
        // both render blocks refuse to run until one has been.
        [self createDSP];
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


// Subclasses hide parameters that are kept only so that old saved state loads
- (BOOL) embrace_isParameterHiddenAtAddress:(AUParameterAddress)address
{
    return NO;
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

// Upstream (1.1.3) exposes only Sensitivity, Model Order as one of 64, 128 or
// 256, Extra Cautious and delta.  Extent, Max Repair, Repair Depth, Passes and
// Dry/Wet are retired, but they stay in the parameter tree, hidden: AUAudioUnit's
// state archive names each parameter by identifier, and -setFullState: throws on
// one the tree does not have, so dropping them would make every set list and
// .aupreset saved before now fail to load.  Their values are ignored.
//
// The old Model Order ("order", 8 to 256 taps) is one of them.  Its replacement
// ("modelOrder") is an index into the three, and only that is read.  A state
// saved before it existed carries "order" alone, and -setFullState: turns that
// into the nearest of the three.
//
// New parameters take new addresses, so nothing saved means something else now.
//
enum {
    kDeclickSensitivity = 0,
    kDeclickExtent      = 1,   // retired
    kDeclickMaxLength   = 2,   // retired
    kDeclickDepth       = 3,   // retired
    kDeclickPasses      = 4,   // retired
    kDeclickOrder       = 5,   // retired; old states migrate to kDeclickModelOrder
    kDeclickDryWet      = 6,   // retired
    kDeclickDelta       = 7,
    kDeclickModelOrder  = 8,
    kDeclickCautious    = 9
};

static const int sDeclickOrders[] = { 64, 128, 256 };

static int sDeclickOrderForIndex(float index)
{
    long i = lrintf(index);
    if (i < 0) i = 0;
    if (i > 2) i = 2;
    return sDeclickOrders[i];
}

static float sDeclickIndexForOrder(float order)
{
    int snapped = declick::Params::snapOrder((int)lrintf(order));
    return (snapped == 64) ? 0 : (snapped == 128) ? 1 : 2;
}

// Outside every parameter's range: what -setFullState: parks the two order
// parameters on to see which of them the state sets
static const AUValue sDeclickUnset = -1;


struct DeclickDSP {
    declick::Channel channel[sMaxChannels];
    declick::Params  active;
    declick::Config  cfg;

    double sampleRate = 44100;
    int    channels   = 2;
    bool   haveActive = false;
    bool   configured = false;

    // Where the read-ahead pulls land.  One render is the most a single pull asks
    // for, so this is sized to maximumFramesToRender.
    AudioBufferList *lookahead         = NULL;
    UInt32           lookaheadCapacity = 0;

    // Warm start.  A scout (see -embrace_scoutFileURL:) warms a channel of its own
    // over the opening of the track on a worker thread and leaves what that
    // learned here, one slot per scout so that a late one cannot overwrite the
    // slot the render thread is about to read.  `forgetPending` is the scout's
    // word that a track begins: the render thread then starts every channel
    // afresh, from the slot if there is one and cold if there is not.
    declick::WarmState warm[2][sMaxChannels];
    std::atomic<int>   warmSlot { -1 };
    std::atomic<bool>  forgetPending { false };
    std::atomic<long>  scoutGeneration { 0 };

    ~DeclickDSP() { freeLookahead(); }

    // Render thread, after update() and ahead of readAhead(), because starting
    // afresh empties the pipeline and refilling it is the read-ahead's job.
    void applyTrackStart()
    {
        if (!forgetPending.exchange(false, std::memory_order_relaxed) || !configured) return;

        int slot = warmSlot.exchange(-1, std::memory_order_acquire);

        for (int i = 0; i < channels; i++) {
            // adoptWarm() resets on a state it cannot use, as well as on failing
            if (slot < 0) channel[i].reset();
            else          channel[i].adoptWarm(warm[slot][i]);
        }
    }

    void freeLookahead()
    {
        if (lookahead) HugAudioBufferListFree(lookahead, YES);
        lookahead = NULL;
        lookaheadCapacity = 0;
    }

    // Only what upstream lets a user reach: Sensitivity, Model Order, Extra
    // Cautious and delta.  Every stage after the AR repair was tuned with the
    // rest at their defaults, so restrictToControls() puts them back there --
    // whatever a preset saved before they were retired says, and Dry/Wet
    // included.  Bypass is still a wet mix of zero, applied after it.
    declick::Params paramsFrom(const RestorationState *state) const
    {
        declick::Params p = declick::Params::defaults();

        // Unset only for the length of a -setFullState:, which must not cost a
        // reconfigure on its own account
        float orderIndex = state->get(kDeclickModelOrder);

        p.sensitivity = state->get(kDeclickSensitivity);
        p.order       = (orderIndex >= 0) ? sDeclickOrderForIndex(orderIndex) : (haveActive ? active.order : p.order);
        p.cautious    = state->get(kDeclickCautious) >= 0.5f;
        p.delta       = !state->isBypassed() && state->get(kDeclickDelta) >= 0.5f;
        p.restrictToControls();
        p.dryWet      = state->isBypassed() ? 0.0f : 1.0f;

        return p;
    }

    void update(const RestorationState *state)
    {
        declick::Params p = paramsFrom(state);
        if (haveActive && p == active) return;

        declick::Config next;
        next.compute(p, sampleRate);

        if (configured && next.structurallyEquals(cfg)) {
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

        // Only Model Order and Extra Cautious reach here (the latter switches
        // stages on and off, which changes the latency).  Past the first call it
        // allocates nothing -- see the buffer envelope in declick::Config -- but
        // configure() empties the pipeline, and the next render then has to read
        // the model's lookahead back in before it can emit, so moving those two
        // under a live stream is not free.
        for (int i = 0; i < channels; i++) {
            channel[i].configure(next);
        }

        cfg = next;
        active = p;
        haveActive = true;
        configured = true;
    }

    void restart(double rate, int chans, UInt32 maxFrames)
    {
        sampleRate = rate;
        channels   = chans;
        haveActive = false;
        configured = false;

        // Main thread, from -allocateRenderResources, which is the only place
        // either the channel count or the render size can change.
        freeLookahead();
        lookahead = HugAudioBufferListCreate((UInt32)chans, maxFrames, YES);
        lookaheadCapacity = lookahead ? maxFrames : 0;
    }

    // Repairing a sample needs the samples that come after it, so the model has
    // to be fed ahead of the audio being heard.  The usual way is prime(): push
    // `latency` zeros and let everything come out that much later.  A file player
    // does not have to pay that, because the future is sitting in the file -- so
    // instead of priming, keep pulling upstream until the pipeline can satisfy
    // this render.  What that spends is read position rather than time: the
    // source ends up running about a render ahead of the speakers, and the output
    // is bit-identical to the same core run over the whole file in one go.
    //
    // An underrun cannot happen, because the pull below only runs once
    // available() is already large enough.  The guard is here because this is the
    // render thread: at `frameCount` a time it takes latency/frameCount
    // iterations, and measured it never wants more than one beyond that.
    //
    // The timestamp goes out unchanged.  Upstream reads it only to stamp its own
    // status, and HugAudioEngine is what accounts for the offset these pulls
    // open up between the read position and the audio being heard.
    AUAudioUnitStatus readAhead(AUAudioFrameCount frameCount,
                                const AudioTimeStamp *timestamp,
                                AURenderPullInputBlock pullInputBlock)
    {
        if (!lookahead || frameCount > lookaheadCapacity) {
            return kAudioUnitErr_TooManyFramesToProcess;
        }

        int guard = (cfg.latency / (int)frameCount) + 4;

        while (channel[0].available() < frameCount) {
            if (guard-- <= 0) return kAudioUnitErr_TooManyFramesToProcess;

            for (UInt32 i = 0; i < lookahead->mNumberBuffers; i++) {
                lookahead->mBuffers[i].mDataByteSize = frameCount * sizeof(float);
            }

            AudioUnitRenderActionFlags pullFlags = 0;

            AUAudioUnitStatus err = pullInputBlock(&pullFlags, timestamp, frameCount, 0, lookahead);
            if (err) return err;

            int count = std::min((int)lookahead->mNumberBuffers, channels);

            for (int i = 0; i < count; i++) {
                channel[i].push((const float *)lookahead->mBuffers[i].mData, frameCount, 1);
            }
        }

        return noErr;
    }

    void emit(AudioBufferList *bufferList, AUAudioFrameCount frames)
    {
        int count = std::min((int)bufferList->mNumberBuffers, channels);

        for (int i = 0; i < count; i++) {
            channel[i].pull((float *)bufferList->mBuffers[i].mData, frames, 1);
        }
    }
};


// Warms a channel per output channel over the opening of a file, as the core
// does for a host that can read ahead, and saves what it learned into
// dsp->warm[slot].  Off the main thread.  The core wants Config::warmSeconds() of
// the audio that is coming, and the file has it.
//
// At the file's own rate: the saved state is only good for a channel configured
// the same way, and the live unit runs at the rate of the audio it is given, so
// a file that does not match it is left to start cold.  A mono file warms every
// live channel from its one pass.
//
static bool sScoutWarm(NSURL *fileURL, DeclickDSP *dsp, const declick::Params &params,
                       double liveRate, int liveChannels, int slot,
                       const std::atomic<long> *generationNow, long generation)
{
    static const UInt32 sBlockFrames = 4096;

    HugAudioFile *file = [[HugAudioFile alloc] initWithFileURL:fileURL];
    if (![file open]) return false;

    double    rate         = [file sampleRate];
    NSInteger fileChannels = [file channelCount];

    if (fabs(rate - liveRate) > 0.5 || fileChannels < 1 || liveChannels < 1) {
        [file close];
        return false;
    }

    declick::Config cfg;
    cfg.compute(params, rate);

    SInt64 wanted = (SInt64)(cfg.warmSeconds() * rate);

    std::vector<std::vector<float>> audio((size_t)fileChannels);
    for (auto &a : audio) a.reserve((size_t)wanted);

    AudioBufferList *bufferList = HugAudioBufferListCreate((UInt32)fileChannels, sBlockFrames, YES);
    if (!bufferList) {
        [file close];
        return false;
    }

    SInt64 read = 0;

    while (read < wanted) {
        UInt32 frames = sBlockFrames;
        if ((SInt64)frames > (wanted - read)) frames = (UInt32)(wanted - read);

        for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
            bufferList->mBuffers[i].mDataByteSize = frames * sizeof(float);
        }

        if (![file readFrames:&frames intoBufferList:bufferList]) break;
        if (frames == 0) break;

        // Another track started; whatever this finds is already stale
        if (generationNow->load(std::memory_order_relaxed) != generation) {
            HugAudioBufferListFree(bufferList, YES);
            [file close];
            return false;
        }

        for (UInt32 c = 0; c < bufferList->mNumberBuffers && c < audio.size(); c++) {
            const float *source = (const float *)bufferList->mBuffers[c].mData;
            audio[c].insert(audio[c].end(), source, source + frames);
        }

        read += frames;
    }

    HugAudioBufferListFree(bufferList, YES);
    [file close];

    if (read == 0) return false;

    std::vector<char> savedStorage((size_t)liveChannels, 0);
    char *saved = savedStorage.data();

    // A thread a channel of the file, as far as the cores go.  The engine runs the
    // unit in stereo, so a mono file feeds every live channel the same audio: warm
    // it once and save that into each.
    size_t distinct = std::min((size_t)liveChannels, audio.size());

    dispatch_apply(distinct, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t c) {
        declick::scoped_flush_denormals ftz;

        const std::vector<float> &in = audio[c];

        std::unique_ptr<declick::Channel> channel(new declick::Channel());
        channel->configure(cfg);
        channel->beginWarm();
        channel->push(in.data(), in.size(), 1);
        channel->endWarm();

        for (size_t live = c; live < (size_t)liveChannels; live++) {
            if (std::min(live, audio.size() - 1) != c) continue;
            saved[live] = channel->saveWarm(dsp->warm[slot][live]) ? 1 : 0;
        }
    });

    for (char ok : savedStorage) if (!ok) return false;

    return true;
}


@interface DeclickAudioUnit : RestorationAudioUnit <EmbraceTrackScouting>
@end


@implementation DeclickAudioUnit {
    DeclickDSP *_dsp;
}

- (NSArray<AUParameter *> *) createParameters
{
    declick::Params defaults = declick::Params::defaults();

    NSArray<NSString *> *orderNames = @[ @"64", @"128", @"256" ];

    // Tree order is form order for the visible ones.  The retired ones keep
    // their identifiers, addresses, ranges and relative order.
    return @[
        EmbraceAUMakeParameter(@"sensitivity", NSLocalizedString(@"Sensitivity",    nil), kDeclickSensitivity, 0, 1, defaults.sensitivity, kAudioUnitParameterUnit_Generic),
        EmbraceAUMakeParameter(@"modelOrder",  NSLocalizedString(@"Model Order",    nil), kDeclickModelOrder,  0, 2, sDeclickIndexForOrder(defaults.order), kAudioUnitParameterUnit_Indexed, orderNames),
        EmbraceAUMakeParameter(@"cautious",    NSLocalizedString(@"Extra Cautious", nil), kDeclickCautious,    0, 1, defaults.cautious,    kAudioUnitParameterUnit_Boolean),

        EmbraceAUMakeParameter(@"extent",      @"Extent",       kDeclickExtent,    0,   1,  defaults.extent,      kAudioUnitParameterUnit_Generic),
        EmbraceAUMakeParameter(@"maxLength",   @"Max Repair",   kDeclickMaxLength, 0.2, 20, defaults.maxLengthMs, kAudioUnitParameterUnit_Milliseconds),
        EmbraceAUMakeParameter(@"depth",       @"Repair Depth", kDeclickDepth,     0,   1,  defaults.depth,       kAudioUnitParameterUnit_Generic),
        EmbraceAUMakeParameter(@"passes",      @"Passes",       kDeclickPasses,    1,   3,  defaults.passes,      kAudioUnitParameterUnit_Indexed),
        EmbraceAUMakeParameter(@"order",       @"Model Order (taps)", kDeclickOrder, declick::kMinOrder, declick::kMaxOrder, defaults.order, kAudioUnitParameterUnit_Indexed),
        EmbraceAUMakeParameter(@"dryWet",      @"Dry/Wet",      kDeclickDryWet,    0,   1,  defaults.dryWet,      kAudioUnitParameterUnit_Generic),

        EmbraceAUMakeParameter(@"delta",       NSLocalizedString(@"Delta",          nil), kDeclickDelta,       0, 1, defaults.delta,       kAudioUnitParameterUnit_Boolean)
    ];
}


- (BOOL) embrace_isParameterHiddenAtAddress:(AUParameterAddress)address
{
    switch (address) {
    case kDeclickExtent:
    case kDeclickMaxLength:
    case kDeclickDepth:
    case kDeclickPasses:
    case kDeclickOrder:
    case kDeclickDryWet:
        return YES;
    default:
        return NO;
    }
}


// A state saved before Model Order became one of three sets "order" and not
// "modelOrder".  Park both on a value no state holds, load, and see which came
// in.  Through AUParameter rather than the raw state, because -fullState saves
// each AUParameter's cached value: a value stored behind its back would be
// heard but not saved.
//
- (void) setFullState:(NSDictionary<NSString *, id> *)fullState
{
    AUParameterTree *tree       = [self parameterTree];
    AUParameter     *modelOrder = [tree parameterWithAddress:kDeclickModelOrder];
    AUParameter     *order      = [tree parameterWithAddress:kDeclickOrder];

    AUValue modelOrderBefore = [modelOrder value];
    AUValue orderBefore      = [order value];

    [modelOrder setValue:sDeclickUnset originator:NULL];
    [order      setValue:sDeclickUnset originator:NULL];

    [super setFullState:fullState];

    if ([modelOrder value] == sDeclickUnset) {
        AUValue migrated = ([order value] != sDeclickUnset) ? sDeclickIndexForOrder([order value]) : modelOrderBefore;
        [modelOrder setValue:migrated originator:NULL];
    }

    if ([order value] == sDeclickUnset) {
        [order setValue:orderBefore originator:NULL];
    }
}


// Condensed from the rationale in declick_core.h and upstream's own tooltips.
// Indexed by address.
- (NSArray<NSString *> *) createParameterHelp
{
    NSMutableArray<NSString *> *help = [NSMutableArray array];
    for (int i = 0; i < sMaxParameters; i++) [help addObject:@""];

    help[kDeclickSensitivity] = NSLocalizedString(@"How readily a sample is called a click. The "
        "default, 0.9, puts the trigger at 2.85 sigma above the local noise estimate. Detections "
        "near the trigger are only partly repaired - they are as likely noise or music as clicks - "
        "and full repair is kept for clear ones. Past the default, music starts being flagged as "
        "damage faster than crackle is found. On clean records 0.7-0.8 takes less still.", nil);

    help[kDeclickModelOrder] = NSLocalizedString(@"Taps in the autoregressive model that predicts "
        "what the waveform should have been. 128 is the balance. 256 models the music better and "
        "changes clean records least, but misses more of the short clicks on heavily crackled "
        "transfers. 64 costs about 0.6x the CPU of 128 and gives up surprisingly little - the one "
        "to pick on a slow machine; 256 costs about 2.4x.", nil);

    help[kDeclickCautious] = NSLocalizedString(@"Repairs only the clicks the detector flags, and "
        "turns off every stage that works on the audio around them: the click-shape fit, the "
        "crackle body, top-band and mid stages, the flank repair and the crackle floor. Those take "
        "the carpet of crackle under the clicks, and on some records a little of the music with "
        "it. With this on the music is left as it is, and more crackle stays. Uses less CPU.", nil);

    help[kDeclickDelta] = NSLocalizedString(@"Outputs what the repair takes out - the input minus "
        "the output - instead of the repaired audio. For testing: it should be crackle and clicks "
        "and nothing else, and any music heard in it is being damaged. Saved with the preset; "
        "untick it when done.", nil);

    return help;
}


- (void) createDSP  { _dsp = new DeclickDSP(); }
- (void) destroyDSP { delete _dsp; _dsp = NULL; }


// A track is about to start.  Its opening seconds are warmed first, off the
// render thread, so that the key and the crackle floor are the ones the track
// has once those seconds are in rather than the empty ones a cold start has.
// The Player is waiting on this, a fraction of a second for stereo, in the way
// foobar2000's warm start stalls a track's start.  Whatever goes wrong, the
// track starts cold: the same as it would without any of this.
//
- (void) embrace_scoutFileURL:(NSURL *)fileURL
{
    DeclickDSP *dsp = _dsp;

    long generation = dsp->scoutGeneration.fetch_add(1, std::memory_order_relaxed) + 1;
    dsp->warmSlot.store(-1, std::memory_order_relaxed);

    if (!fileURL || !dsp->configured) {
        dsp->forgetPending.store(true, std::memory_order_relaxed);
        return;
    }

    declick::Params p        = dsp->paramsFrom([self state]);
    double          rate     = dsp->sampleRate;
    int             channels = dsp->channels;
    int             slot     = (int)(generation & 1);

    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    // self is captured strongly on purpose: it keeps the DSP alive for the scout
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        bool ok = sScoutWarm(fileURL, dsp, p, rate, channels, slot, &dsp->scoutGeneration, generation);

        // Whoever moves the generation on first decides: this, or a caller that
        // gave up waiting, whose track has started cold by now
        long expected = generation;

        if (ok && dsp->scoutGeneration.compare_exchange_strong(expected, generation + 1)) {
            dsp->warmSlot.store(slot, std::memory_order_release);
            dsp->forgetPending.store(true, std::memory_order_relaxed);
            EmbraceLog(@"Declick", @"warmed on %@", [fileURL lastPathComponent]);
        }

        (void)self;
        dispatch_semaphore_signal(done);
    });

    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) {
        long expected = generation;

        if (dsp->scoutGeneration.compare_exchange_strong(expected, generation + 1)) {
            EmbraceLog(@"Declick", @"warm start of %@ took too long, starting cold", [fileURL lastPathComponent]);
            dsp->forgetPending.store(true, std::memory_order_relaxed);
        } else {
            // The scout won the race and is publishing
            dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        }
        return;
    }

    // Finished without publishing: failed, or went stale.  Cold.
    if (dsp->warmSlot.load(std::memory_order_relaxed) < 0 && dsp->scoutGeneration.load(std::memory_order_relaxed) == generation) {
        long expected = generation;
        dsp->scoutGeneration.compare_exchange_strong(expected, generation + 1);
        dsp->forgetPending.store(true, std::memory_order_relaxed);
    }
}


- (void) configureDSPWithSampleRate:(double)sampleRate channels:(int)channels
{
    _dsp->restart(sampleRate, channels, (UInt32)[self maximumFramesToRender]);
    _dsp->update([self state]);
}


// Zero rather than cfg.latency: the model's lookahead is met by reading ahead of
// the playhead, not by holding the output back.  See DeclickDSP::readAhead.
- (NSTimeInterval) latency
{
    return 0;
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

        // A Channel may not be touched before configure(), and readAhead() goes
        // straight at channel[0].  -allocateRenderResources is what configures,
        // and the host is required to call it first; this is here so that a host
        // that does not is an error return rather than a configure -- which is to
        // say an allocation -- on the render thread.
        if (!dsp->configured) return kAudioUnitErr_Uninitialized;

        AUAudioUnitStatus err = EmbraceAUPrepareBufferList(outputData, frameCount);
        if (err) return err;

        declick::scoped_flush_denormals ftz;

        // Ahead of the read-ahead, because a Model Order change empties the
        // pipeline and refilling it is the read-ahead's job.
        dsp->update(state);
        dsp->applyTrackStart();

        err = dsp->readAhead(frameCount, timestamp, pullInputBlock);
        if (err) return err;

        dsp->emit(outputData, frameCount);

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
        p.dryWet      = state->isBypassed() ? 0.0f : 1.0f;   // address 6 is retired
        p.delta       = !state->isBypassed() && state->get(7) >= 0.5f;
        p.sanitize();

        return p;
    }

    void update(const RestorationState *state)
    {
        // A new record means a new hum, so nothing carries over.  reset() only
        // memsets buffers it already holds, so this is safe here.
        //
        // The flag is consumed either way: before the first configure there are
        // no channels to forget with, and the configure below ends in the same
        // reset.  A scout can publish against a unit whose render resources have
        // not been allocated yet, so that ordering is reachable.
        if (forgetPending.exchange(false, std::memory_order_relaxed) && configured) {
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
        int i = 0;

        // Two at a time: bit for bit the same as one after the other, but faster
        for (; i + 1 < count; i += 2) {
            dehum::Channel::processPair(channel[i],     (float *)bufferList->mBuffers[i].mData,
                                        channel[i + 1], (float *)bufferList->mBuffers[i + 1].mData,
                                        frames, 1);
        }

        if (i < count) channel[i].process((float *)bufferList->mBuffers[i].mData, frames, 1);
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
    //
    // Dry/Wet is retired, as upstream (1.1.2) has dropped it: a blend only gives
    // the hum back at the blend's level, so the one useful setting was 0, which
    // Bypass already is.  It stays in the tree, hidden, for the reason declick's
    // retired parameters do: -setFullState: throws on an identifier the tree
    // lacks, so old set lists and presets would no longer load.  Its value is
    // ignored.
    return @[
        EmbraceAUMakeParameter(@"sensitivity", NSLocalizedString(@"Sensitivity", nil), 0, 0,   1,   defaults.sensitivity, kAudioUnitParameterUnit_Generic),
        EmbraceAUMakeParameter(@"bandwidth",   NSLocalizedString(@"Bandwidth",   nil), 1, 0.1, 5,   defaults.bandwidth,   kAudioUnitParameterUnit_Hertz),
        EmbraceAUMakeParameter(@"searchTo",    NSLocalizedString(@"Search To",   nil), 2, 40,  dehum::kSearchCeil,   defaults.searchTo,  kAudioUnitParameterUnit_Hertz),
        EmbraceAUMakeParameter(@"harmonics",   NSLocalizedString(@"Harmonics",   nil), 3, 1,   dehum::kMaxHarmonics, defaults.harmonics, kAudioUnitParameterUnit_Indexed),
        EmbraceAUMakeParameter(@"frequency",   NSLocalizedString(@"Frequency",   nil), 4, 0,   500, defaults.frequency,   kAudioUnitParameterUnit_Hertz),
        EmbraceAUMakeParameter(@"rumble",      NSLocalizedString(@"Rumble",      nil), 5, 0,   200, defaults.rumbleHz,    kAudioUnitParameterUnit_Hertz),
        EmbraceAUMakeParameter(@"dryWet",      @"Dry/Wet", 6, 0,   1,   defaults.dryWet,      kAudioUnitParameterUnit_Generic),
        EmbraceAUMakeParameter(@"delta",       NSLocalizedString(@"Delta",       nil), 7, 0,   1,   defaults.delta,       kAudioUnitParameterUnit_Boolean)
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

        @"",   // Dry/Wet, retired and hidden

        NSLocalizedString(@"Outputs what the notches take out - the input minus the output - instead "
            "of the cleaned audio. For testing: it should be hum and nothing else. Rumble is left out "
            "of it, because what a high-pass removes carries the whole spectrum as phase shift and "
            "sounds like the music. Saved with the preset; untick it when done.", nil)
    ];
}


- (BOOL) embrace_isParameterHiddenAtAddress:(AUParameterAddress)address
{
    return address == 6;   // Dry/Wet, retired
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

        // See the note in the declick render block: unconfigured is the host's
        // mistake, and an error return is a cheaper way to say so than an
        // allocation at a sample rate that was only ever a guess.
        if (!dsp->configured) return kAudioUnitErr_Uninitialized;

        AUAudioUnitStatus err = EmbraceAUPrepareBufferList(outputData, frameCount);
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
