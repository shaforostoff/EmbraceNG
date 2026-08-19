// (c) 2018-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "HugAudioEngine.h"

#import "HugCrashPad.h"
#import "HugLimiter.h"
#import "HugLinearRamper.h"
#import "HugStereoField.h"
#import "HugFastUtils.h"
#import "HugLevelMeter.h"
#import "HugMeterData.h"
#import "HugSimpleGraph.h"
#import "HugRingBuffer.h"
#import "HugUtils.h"
#import "HugAudioSettings.h"
#import "HugAudioSource.h"

#import <AVFoundation/AVFoundation.h>

#include <stdatomic.h>

extern volatile mach_port_t _HugCrashPadIgnoredThread;
extern volatile BOOL _HugCrashPadEnabled;


typedef NS_ENUM(NSInteger, PacketType) {
    PacketTypeUnknown = 0,

    // Transmitted via _statusRingBuffer
    PacketTypePlayback = 1,
    PacketTypeMeter    = 2,
    PacketTypeDanger   = 3,
    
    // Transmitted via _errorRingBuffer
    PacketTypeStatusBufferFull = 101, // Uses PacketDataUnknown
    PacketTypeOverload         = 102, // Uses PacketDataUnknown
    PacketTypeRenderError      = 200, // Uses PacketDataError
};

typedef struct {
    uint64_t timestamp;
    UInt16 type;
} PacketDataUnknown;

typedef struct {
    uint64_t timestamp;
    UInt16 type;
    HugPlaybackInfo info;
} PacketDataPlayback;

typedef struct {
    uint64_t timestamp;
    UInt16 type;
    UInt16 frameCount;
    uint64_t renderTime;
} PacketDataDanger;

typedef struct {
    uint64_t timestamp;
    UInt16 type;
    HugMeterDataStruct leftMeterData;
    HugMeterDataStruct rightMeterData;
} PacketDataMeter;

typedef struct {
    uint64_t timestamp;
    UInt16 type;
    UInt16 index;
    OSStatus err;
} PacketDataRenderError;

typedef struct {
    _Atomic HugAudioSourceInputBlock inputBlock;
    _Atomic HugAudioSourceInputBlock nextInputBlock;
    
    _Atomic AURenderPullInputBlock renderBlock;
    _Atomic AURenderPullInputBlock nextRenderBlock;

    volatile float stereoWidth;
    volatile float stereoBalance;
    volatile float volume;
    volatile float preGain;

    volatile UInt64 renderStart;

    // Frames drawn from the front of the chain, and frames handed to the device.
    // An effect with lookahead pulls its input ahead of the audio it emits, which
    // leaves the source reading ahead of what is being heard; the difference is
    // how far, and lookaheadHostTime is that difference as a duration.
    volatile UInt64 sourceFrames;
    volatile UInt64 outputFrames;
    volatile UInt64 lookaheadHostTime;
} RenderUserInfo;


static OSStatus sOutputUnitRenderCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData)
{
    _HugCrashPadIgnoredThread = mach_thread_self();

    RenderUserInfo *userInfo = (RenderUserInfo *)inRefCon;
    
    __unsafe_unretained AURenderPullInputBlock renderBlock     = atomic_load(&userInfo->renderBlock);
    __unsafe_unretained AURenderPullInputBlock nextRenderBlock = atomic_load(&userInfo->nextRenderBlock);

    OSStatus err = renderBlock(ioActionFlags, inTimeStamp, inNumberFrames, 0, ioData);

    if (renderBlock != nextRenderBlock) {
        atomic_store(&userInfo->renderBlock, nextRenderBlock);
    }

    return err;
}


static OSStatus sHandleAudioDeviceOverload(AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress inAddresses[], void *inClientData)
{
    PacketDataUnknown packet = { 0, PacketTypeOverload };
    HugRingBufferWrite((HugRingBuffer *)inClientData, &packet, sizeof(packet));
    
    return noErr;
}


@implementation HugAudioEngine {
    RenderUserInfo _renderUserInfo;

    HugAudioSource *_currentSource;
    HugAudioSourceInputBlock _currentInputBlock;
    AudioUnit _outputAudioUnit;

    HugSimpleGraph *_graph;
    AURenderPullInputBlock _graphRenderBlock;

    AudioDeviceID _outputDeviceID;
    NSDictionary *_outputSettings;

    BOOL _switchingSources;

    NSTimer *_updateTimer;

    HugLimiter      *_emergencyLimiter;
    HugStereoField  *_stereoField;
    HugLevelMeter   *_leftLevelMeter;
    HugLevelMeter   *_rightLevelMeter;
    HugLinearRamper *_preGainRamper;
    HugLinearRamper *_volumeRamper;

    HugRingBuffer   *_errorRingBuffer;
    HugRingBuffer   *_statusRingBuffer;

    HugPlaybackStatus _playbackStatus;
    NSTimeInterval    _timeElapsed;
    NSTimeInterval    _timeRemaining;
    HugMeterData     *_leftMeterData;
    HugMeterData     *_rightMeterData;
    float             _dangerLevel;
    NSTimeInterval    _lastOverloadTime;

    NSArray<AUAudioUnit *> *_effectAudioUnits;
}


- (instancetype) init
{
    if ((self = [super init])) {
        HugLogMethod();

        AudioComponentDescription outputCD = {
            kAudioUnitType_Output,
            kAudioUnitSubType_HALOutput,
            kAudioUnitManufacturer_Apple,
            0,
            0
        };

        AudioComponent outputComponent = AudioComponentFindNext(NULL, &outputCD);

        HugCheckError(
            AudioComponentInstanceNew(outputComponent, &_outputAudioUnit),
            @"HugAudioEngine", @"AudioComponentInstanceNew[ Output ]"
        );

        _stereoField      = HugStereoFieldCreate();
        _preGainRamper    = HugLinearRamperCreate();
        _volumeRamper     = HugLinearRamperCreate();
        _leftLevelMeter   = HugLevelMeterCreate();
        _rightLevelMeter  = HugLevelMeterCreate();
        _emergencyLimiter = HugLimiterCreate();
        
        _statusRingBuffer = HugRingBufferCreate(8196);
        _errorRingBuffer  = HugRingBufferCreate(8196);
    }

    return self;
}


- (void) _sendAudioSourceToRenderThread:(HugAudioSource *)source
{
    if (_currentSource == source) return;

    _switchingSources = YES;

    HugLog(@"HugAudioEngine", @"Sending %@ to render thread", source);

    HugAudioSourceInputBlock blockToCall = [source inputBlock];
    
    // Make a copy of blockToCall. This will change the object pointer
    // and reset the track even if source is the same as _currentSource
    //
    HugAudioSourceInputBlock blockToSend = blockToCall ? [^(
        AUAudioFrameCount frameCount,
        AudioBufferList *inputData,
        HugPlaybackInfo *outInfo
    ) {
        return blockToCall(frameCount, inputData, outInfo);
    } copy] : nil;

    if ([self _isRunning]) {
        atomic_store(&_renderUserInfo.nextInputBlock, blockToSend);

        NSInteger loopGuard = 0;
        while (1) {
            HugRingBufferConfirmReadAll(_statusRingBuffer);

            if (blockToSend == atomic_load(&_renderUserInfo.inputBlock)) {
                break;
            }

            if (![self _isRunning]) return;

            if (loopGuard >= 1000) {
                HugLog(@"HugAudioEngine", @"_sendAudioSourceToRenderThread timed out");
                break;
            }
            
            usleep(1000);
            loopGuard++;
        }

    } else {
        atomic_store(&_renderUserInfo.inputBlock,     nil);
        atomic_store(&_renderUserInfo.nextInputBlock, blockToSend);
    }
    
    _currentSource = source;
    _currentInputBlock = blockToSend;

    HugRingBufferConfirmReadAll(_statusRingBuffer);
    _switchingSources = NO;
}


- (BOOL) _isRunning
{
    if (!_outputAudioUnit) return NO;

    Boolean isRunning = false;
    UInt32 size = sizeof(isRunning);

    HugCheckError(
        AudioUnitGetProperty(_outputAudioUnit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &isRunning, &size),
        @"HugAudioEngine", @"AudioUnitGetProperty[ Output, IsRunning ]"
    );
    
    return isRunning ? YES : NO;
}


- (void) _readRingBuffers
{
    uint64_t current = HugGetCurrentHostTime();
    uint64_t tooFar  = current + HugGetHostTimeWithSeconds(1.0);

    NSInteger loopGuard = HugRingBufferGetCapacity(_statusRingBuffer) / sizeof(PacketDataUnknown);

    NSInteger overloadCount   = 0;
    NSInteger statusFullCount = 0;

    // Process status
    for (NSInteger i = 0; i < loopGuard; i++) {
        // If we are switching sources, clear the entire _statusRingBuffer
        if (_switchingSources) {
            HugRingBufferConfirmReadAll(_statusRingBuffer);
            break;
        }

        PacketDataUnknown *unknown = HugRingBufferGetReadPtr(_statusRingBuffer, sizeof(PacketDataUnknown));
        if (!unknown) break;
               
        if ((unknown->timestamp >= current) && (unknown->timestamp < tooFar)) {
            break;
        }
        
        if (unknown->type == PacketTypePlayback) {
            PacketDataPlayback packet;
            if (!HugRingBufferRead(_statusRingBuffer, &packet, sizeof(PacketDataPlayback))) return;

            _playbackStatus = packet.info.status;
            _timeElapsed    = packet.info.timeElapsed;
            _timeRemaining  = packet.info.timeRemaining;

        } else if (unknown->type == PacketTypeMeter) {
            PacketDataMeter packet;
            if (!HugRingBufferRead(_statusRingBuffer, &packet, sizeof(PacketDataMeter))) return;
            
            _leftMeterData  = [[HugMeterData alloc] initWithStruct:packet.leftMeterData];
            _rightMeterData = [[HugMeterData alloc] initWithStruct:packet.rightMeterData];

        } else if (unknown->type == PacketTypeDanger) {
            PacketDataDanger packet;
            if (!HugRingBufferRead(_statusRingBuffer, &packet, sizeof(PacketDataDanger))) return;
            
            uint64_t renderTime = packet.renderTime;

            double outputSampleRate = [[_outputSettings objectForKey:HugAudioSettingSampleRate] doubleValue];
            
            double callbackDuration = packet.frameCount / outputSampleRate;
            double elapsedDuration  = HugGetSecondsWithHostTime(renderTime);
            
            _dangerLevel = elapsedDuration / callbackDuration;

        } else {
            NSAssert(NO, @"Unknown packet type: %ld", (long)unknown->type);
        }
    }
    
    // Process error buffer
    for (NSInteger i = 0; i < loopGuard; i++) {
        PacketDataUnknown *unknown = HugRingBufferGetReadPtr(_errorRingBuffer, sizeof(PacketDataUnknown));
        if (!unknown) return;

        if (unknown->type == PacketTypeOverload) {
            PacketDataUnknown packet;
            if (!HugRingBufferRead(_errorRingBuffer, &packet, sizeof(PacketDataUnknown))) return;

            _lastOverloadTime = [NSDate timeIntervalSinceReferenceDate];

            overloadCount++;
           
        } else if (unknown->type == PacketTypeStatusBufferFull) {
            PacketDataUnknown packet;
            if (!HugRingBufferRead(_errorRingBuffer, &packet, sizeof(PacketDataUnknown))) return;

            statusFullCount++;
        
        } else if (unknown->type == PacketTypeRenderError) {
            PacketDataRenderError packet;
            if (!HugRingBufferRead(_errorRingBuffer, &packet, sizeof(PacketDataRenderError))) return;

            HugLog(@"HugAudioEngine", @"Render error on audio thread: index=%ld, error=%@",
                (long)packet.index,
                HugGetStringForFourCharCode(packet.err)
            );
            
        } else {
            NSAssert(NO, @"Unknown packet type: %ld", (long)unknown->type);
        }
    }
    
    // Aggregate logging for overloads and "buffer full" errors. Else, we can spend
    // too much time in HugLog while _statusRingBuffer continues to fill.
    //
    if (overloadCount > 0) {
        HugLog(@"HugAudioEngine", @"kAudioDeviceProcessorOverload detected (%ld)", overloadCount);
    }
    
    if (statusFullCount > 0) {
        HugLog(@"HugAudioEngine", @"_statusRingBuffer is full (%ld)", statusFullCount);
    }
}


- (void) _reconnectGraph
{
    HugLogMethod();

    HugLimiter      *limiter          = _emergencyLimiter;
    HugStereoField  *stereoField      = _stereoField;
    HugLevelMeter   *leftLevelMeter   = _leftLevelMeter;
    HugLevelMeter   *rightLevelMeter  = _rightLevelMeter;
    HugLinearRamper *preGainRamper    = _preGainRamper;
    HugLinearRamper *volumeRamper     = _volumeRamper;
    HugRingBuffer   *statusRingBuffer = _statusRingBuffer;
    HugRingBuffer   *errorRingBuffer  = _errorRingBuffer;

    RenderUserInfo *userInfo = &_renderUserInfo;

    HugSimpleGraph *graph = [[HugSimpleGraph alloc] initWithErrorBlock:^(OSStatus err, NSInteger index) {
        PacketDataRenderError packet = { 0, PacketTypeRenderError, index, err };
        HugRingBufferWrite(errorRingBuffer, &packet, sizeof(packet));
    }];
     
    void (^__sendStatusPacket)(void *, CFIndex) = ^(void *buffer, CFIndex length) {
        if (!HugRingBufferWrite(statusRingBuffer, buffer, length)) {
            PacketDataUnknown packet = { 0, PacketTypeStatusBufferFull };
            HugRingBufferWrite(errorRingBuffer, &packet, sizeof(packet));
        }
    };
    #define sendStatusPacket(packet) __sendStatusPacket(&(packet), sizeof((packet)));
     
    [graph addBlock:^(
        AudioUnitRenderActionFlags *ioActionFlags,
        const AudioTimeStamp *timestamp,
        AUAudioFrameCount inNumberFrames,
        NSInteger inputBusNumber,
        AudioBufferList *ioData
    ) {
        userInfo->renderStart = HugGetCurrentHostTime();

        __unsafe_unretained HugAudioSourceInputBlock inputBlock     = atomic_load(&userInfo->inputBlock);
        __unsafe_unretained HugAudioSourceInputBlock nextInputBlock = atomic_load(&userInfo->nextInputBlock);
        
        HugPlaybackInfo info = {0};
        OSStatus err = noErr;
        
        BOOL willChangeUnits = (nextInputBlock != inputBlock);

        float *leftData  = ioData->mNumberBuffers > 0 ? ioData->mBuffers[0].mData : NULL;
        float *rightData = ioData->mNumberBuffers > 1 ? ioData->mBuffers[1].mData : NULL;

        // Counts pulls rather than renders: an effect with lookahead calls this
        // block more than once for a single render.
        userInfo->sourceFrames += inNumberFrames;

        if (!inputBlock) {
            *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
            HugApplySilence(leftData, inNumberFrames);
            HugApplySilence(rightData, inNumberFrames);

        } else {
            err = inputBlock(inNumberFrames, ioData, &info);
            
            HugStereoFieldProcess(stereoField, leftData, rightData, inNumberFrames, userInfo->stereoBalance, userInfo->stereoWidth);
            HugLinearRamperProcess(preGainRamper, leftData, rightData, inNumberFrames, userInfo->preGain);

            if (willChangeUnits) {
                HugApplyFade(leftData,  inNumberFrames, 1.0, 0.0);
                HugApplyFade(rightData, inNumberFrames, 1.0, 0.0);
            }
        }

        if (willChangeUnits) {
            HugLinearRamperReset(preGainRamper, userInfo->preGain);
            HugLinearRamperReset(volumeRamper,  userInfo->volume);
            HugStereoFieldReset(stereoField, userInfo->stereoBalance, userInfo->stereoWidth);

            atomic_store(&userInfo->inputBlock, nextInputBlock);

        } else {
            if (inputBlock && (timestamp->mFlags & kAudioTimeStampHostTimeValid)) {
                // Stamped with when this read position will be heard rather than
                // with when it was read.  _readRingBuffers holds a packet back
                // until its stamp has passed, so without the offset a source that
                // is being read ahead would report the end of the file while its
                // last samples were still in the pipeline, and the track would be
                // cut short by exactly that much.
                PacketDataPlayback packet = {
                    timestamp->mHostTime + userInfo->lookaheadHostTime,
                    PacketTypePlayback,
                    info
                };

                sendStatusPacket(packet);
            }
        }

        return err;
    }];

    double sampleRate = [[_outputSettings objectForKey:HugAudioSettingSampleRate] doubleValue];
    UInt32 frameSize  = [[_outputSettings objectForKey:HugAudioSettingFrameSize] unsignedIntValue];
    
    if (sampleRate && frameSize) {
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:2];
        
        [_outputSettings objectForKey:HugAudioSettingFrameSize];
        
        for (AUAudioUnit *unit in _effectAudioUnits) {
            NSError *error = nil;

            if (![unit renderResourcesAllocated] || ([unit maximumFramesToRender] != frameSize)) {
                [unit deallocateRenderResources];
                
                [unit setMaximumFramesToRender:frameSize];

                AUAudioUnitBus *inputBus  = [[unit inputBusses]  objectAtIndexedSubscript:0];
                AUAudioUnitBus *outputBus = [[unit outputBusses] objectAtIndexedSubscript:0];
                
                if (!error) [inputBus  setFormat:format error:&error];
                if (!error) [outputBus setFormat:format error:&error];
                if (!error) [unit allocateRenderResourcesAndReturnError:&error];
                
                [inputBus setEnabled:YES];
                [outputBus setEnabled:YES];
            }
           
            if (error) {
                HugLog(@"HugAudioEngine", @"Error when configuring %@: %@", unit, error);
            } else  {
                [graph addAudioUnit:unit];
            }
        }
    }

    [graph addBlock:^(
        AudioUnitRenderActionFlags *ioActionFlags,
        const AudioTimeStamp *timestamp,
        AUAudioFrameCount inNumberFrames,
        NSInteger inputBusNumber,
        AudioBufferList *ioData
    ) {
        uint64_t currentTime = (timestamp->mFlags & kAudioTimeStampHostTimeValid) ?
            timestamp->mHostTime :
            HugGetCurrentHostTime();
        
        size_t meterFrameCount = HugLevelMeterGetMaxFrameCount(_leftLevelMeter);
        
        NSInteger offset = 0;
        NSInteger framesRemaining = inNumberFrames;

        float *leftData  = ioData->mNumberBuffers > 0 ? ioData->mBuffers[0].mData : NULL;
        float *rightData = ioData->mNumberBuffers > 1 ? ioData->mBuffers[1].mData : NULL;

        float volume = userInfo->volume;
        HugLinearRamperProcess(volumeRamper, leftData, rightData, inNumberFrames, volume);
        
        while (framesRemaining > 0) {
            NSInteger framesToProcess = MIN(framesRemaining, meterFrameCount);

            PacketDataMeter packet = {0};
            packet.timestamp = currentTime + HugGetHostTimeWithSeconds(offset / sampleRate);
            packet.type = PacketTypeMeter;

            if (leftData) {
                HugLevelMeterProcess(leftLevelMeter, leftData + offset, framesToProcess);

                packet.leftMeterData.peakLevel = HugLevelMeterGetPeakLevel(leftLevelMeter);
                packet.leftMeterData.heldLevel = HugLevelMeterGetHeldLevel(leftLevelMeter);
            }

            if (rightData) {
                HugLevelMeterProcess(rightLevelMeter, rightData + offset, framesToProcess);

                packet.rightMeterData.peakLevel = HugLevelMeterGetPeakLevel(rightLevelMeter);
                packet.rightMeterData.heldLevel = HugLevelMeterGetHeldLevel(rightLevelMeter);
            }

            HugLimiterProcess(limiter, leftData + offset, rightData + offset, framesToProcess);
            packet.leftMeterData.limiterActive = HugLimiterIsActive(limiter);
            packet.rightMeterData.limiterActive = packet.leftMeterData.limiterActive;

            sendStatusPacket(packet);

            framesRemaining -= meterFrameCount;
            offset += meterFrameCount;
        }
        
        // Calculate danger level and send packet
        {
            uint64_t renderTime = HugGetCurrentHostTime() - userInfo->renderStart;
            PacketDataDanger packet = { currentTime, PacketTypeDanger, inNumberFrames, renderTime };
            sendStatusPacket(packet);
        }

        // How far the front of the chain has read past what the device has been
        // given.  Zero unless an effect reads ahead.
        {
            userInfo->outputFrames += inNumberFrames;

            UInt64 sourceFrames = userInfo->sourceFrames;
            UInt64 outputFrames = userInfo->outputFrames;
            UInt64 ahead = (sourceFrames > outputFrames) ? (sourceFrames - outputFrames) : 0;

            userInfo->lookaheadHostTime = HugGetHostTimeWithSeconds(ahead / sampleRate);
        }

        return noErr;
    }];

    // Every unit in a rebuilt graph starts with an empty pipeline, so nothing is
    // reading ahead of anything yet.
    _renderUserInfo.sourceFrames      = 0;
    _renderUserInfo.outputFrames      = 0;
    _renderUserInfo.lookaheadHostTime = 0;

    AURenderPullInputBlock blockToSend = [graph renderBlock];
    
    if ([self _isRunning]) {
        atomic_store(&_renderUserInfo.nextRenderBlock, blockToSend);

        NSInteger loopGuard = 0;
        while (1) {
            HugRingBufferConfirmReadAll(_statusRingBuffer);

            if (blockToSend == atomic_load(&_renderUserInfo.renderBlock)) {
                break;
            }

            if (![self _isRunning]) return;

            if (loopGuard >= 1000) {
                HugLog(@"HugAudioEngine", @"_reconnectGraph timed out");
                break;
            }
            
            usleep(1000);
            loopGuard++;
        }

    } else {
        atomic_store(&_renderUserInfo.renderBlock,     blockToSend);
        atomic_store(&_renderUserInfo.nextRenderBlock, blockToSend);
    }

    _graph = graph;
    _graphRenderBlock = blockToSend;
}


- (void) _reallyStopHardware
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_reallyStopHardware) object:nil];

    HugCheckError(
        AudioOutputUnitStop(_outputAudioUnit),
        @"HugAudioEngine", @"AudioOutputUnitStop"
    );

    for (AUAudioUnit *unit in _effectAudioUnits) {
        [unit reset];
    }
    
    if (_updateTimer) {
        [_updateTimer invalidate];
        _updateTimer = nil;
    }
}


- (void) _handleDidPrepareSource:(HugAudioSource *)source
{
    if (source == _currentSource) {
        if ([source error]) {
            [self stopPlayback];
        } else {
            _HugCrashPadEnabled = YES;
        }
    }
}


- (void) _handleUpdateTimer:(NSTimer *)timer
{
    [self _readRingBuffers];
    if (_updateBlock) _updateBlock();
}


#pragma mark - Public Methods

- (BOOL) configureWithDeviceID:(AudioDeviceID)deviceID settings:(NSDictionary *)settings
{
    // Listen for kAudioDeviceProcessorOverload
    {
        AudioObjectPropertyAddress overloadAddress = {
            kAudioDeviceProcessorOverload,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMaster
        };

        if (_outputDeviceID) {
            AudioObjectRemovePropertyListener(_outputDeviceID, &overloadAddress, sHandleAudioDeviceOverload, (void *)_errorRingBuffer);
        }
        
        if (deviceID) {
            AudioObjectAddPropertyListener(deviceID, &overloadAddress, sHandleAudioDeviceOverload, (void *)_errorRingBuffer);
        }
    }

    UInt32 frames = [[settings objectForKey:HugAudioSettingFrameSize] unsignedIntValue];
    UInt32 framesSize = sizeof(frames);

    double sampleRate = [[settings objectForKey:HugAudioSettingSampleRate] doubleValue];

    AURenderCallbackStruct renderCallback = { &sOutputUnitRenderCallback, &_renderUserInfo };

    BOOL ok = YES;

    ok = ok && HugCheckError(AudioUnitSetProperty(_outputAudioUnit,
        kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
        &frames,
        sizeof(frames)
    ), @"HugAudioEngine", @"AudioUnitSetProperty[ Output, kAudioDevicePropertyBufferFrameSize]");
    
    ok = ok && HugCheckError(AudioUnitSetProperty(_outputAudioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &deviceID, sizeof(deviceID)
    ), @"HugAudioEngine", @"AudioUnitSetProperty[ Output, CurrentDevice]");

    ok = ok && HugCheckError(AudioUnitGetProperty(_outputAudioUnit,
        kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
        &frames, &framesSize
    ), @"HugAudioEngine", @"AudioUnitGetProperty[ Output, MaximumFramesPerSlice ]");

    ok = ok && HugCheckError(AudioUnitSetProperty(_outputAudioUnit,
        kAudioUnitProperty_SampleRate, kAudioUnitScope_Input, 0,
        &sampleRate, sizeof(sampleRate)
    ), @"HugAudioEngine", @"AudioUnitSetProperty[ Output, SampleRate, Input ]");

    ok = ok && HugCheckError(AudioUnitSetProperty(_outputAudioUnit,
        kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0,
        &renderCallback,
        sizeof(renderCallback)
    ), @"HugAudioEngine", @"AudioUnitSetProperty[ Output, SetRenderCallback ]");

    _outputDeviceID = deviceID;
    _outputSettings = settings;

    HugLog(@"HugAudioEngine", @"Configuring audio units with %lf sample rate, %ld frame size", sampleRate, (long)frames);

    ok = ok && HugCheckError(
        AudioUnitInitialize(_outputAudioUnit),
        @"HugAudioEngine", @"AudioUnitInitialize[ Output ]"
    );

    HugLevelMeterSetSampleRate(_leftLevelMeter, sampleRate);
    HugLevelMeterSetSampleRate(_rightLevelMeter, sampleRate);
    HugLimiterSetSampleRate(_emergencyLimiter, sampleRate);

    HugLinearRamperSetMaxFrameCount(_preGainRamper, frames);
    HugLinearRamperSetMaxFrameCount(_volumeRamper, frames);
    HugStereoFieldSetMaxFrameCount(_stereoField, frames);

    size_t meterFrame = MIN(frames, 1024);
    HugLevelMeterSetMaxFrameCount(_leftLevelMeter, meterFrame);
    HugLevelMeterSetMaxFrameCount(_rightLevelMeter, meterFrame);

    [self _reconnectGraph];

    return ok;
}


- (BOOL) playAudioFile: (HugAudioFile *) file
             startTime: (NSTimeInterval) startTime
              stopTime: (NSTimeInterval) stopTime
               padding: (NSTimeInterval) padding
{
    HugLogMethod();

    // Stop first, this should clear the playing HugAudioSource and
    // release the large HugProtectedBuffer objects for the current track.
    //
    [self stopPlayback];

    _playbackStatus = HugPlaybackStatusPreparing;

    HugAudioSource *source = [[HugAudioSource alloc] initWithAudioFile:file settings:_outputSettings];
    
    HugAuto weakSelf = self;
    BOOL didPrepare = [source prepareWithStartTime:startTime stopTime:stopTime padding:padding completionHandler:^(HugAudioSource *inSource) {
        [weakSelf _handleDidPrepareSource:inSource];
    }];

    if (!didPrepare) {
        HugLog(@"HugAudioEngine", @"Couldn't prepare %@", source);
        return NO;
    }
    
    [self _sendAudioSourceToRenderThread:source];

    HugLog(@"HugAudioEngine", @"setup complete, starting output");

    if (![self _isRunning]) {
        HugCheckError(
            AudioOutputUnitStart(_outputAudioUnit),
            @"HugAudioEngine", @"AudioOutputUnitStart"
        );
    }

    if (!_updateTimer) {
        _updateTimer = [NSTimer timerWithTimeInterval:(1.0/30.0) target:self selector:@selector(_handleUpdateTimer:) userInfo:nil repeats:YES];
        [_updateTimer setTolerance:(1.0/60.0)];

        [[NSRunLoop mainRunLoop] addTimer:_updateTimer forMode:NSRunLoopCommonModes];
        [[NSRunLoop mainRunLoop] addTimer:_updateTimer forMode:NSEventTrackingRunLoopMode];
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_reallyStopHardware) object:nil];

    return YES;
}


- (void) stopPlayback
{
    _HugCrashPadEnabled = NO;

    if ([self _isRunning]) {
        [self _sendAudioSourceToRenderThread:nil];
        [self performSelector:@selector(_reallyStopHardware) withObject:nil afterDelay:30];
    }

    HugRingBufferConfirmReadAll(_statusRingBuffer);

    HugLevelMeterReset(_leftLevelMeter);
    HugLevelMeterReset(_rightLevelMeter);
    
    _playbackStatus = HugPlaybackStatusStopped;
    _timeElapsed    = 0;
    _timeRemaining  = 0;
    _leftMeterData  = nil;
    _rightMeterData = nil;
    _dangerLevel    = 0;
}


- (void) stopHardware
{
    [self stopPlayback];
    [self _reallyStopHardware];
}


- (void) updateStereoWidth:(float)stereoWidth
{
    _renderUserInfo.stereoWidth = stereoWidth;
}


- (void) updateStereoBalance:(float)stereoBalance
{
    _renderUserInfo.stereoBalance = stereoBalance;
}


- (void) updatePreGain:(float)preGain
{
    _renderUserInfo.preGain = preGain;
}


- (void) updateVolume:(float)volume
{
    _renderUserInfo.volume = volume;
}


- (void) updateEffectAudioUnits:(NSArray<AUAudioUnit *> *)effectAudioUnits
{
    if (_effectAudioUnits != effectAudioUnits || ![_effectAudioUnits isEqual:effectAudioUnits]) {
        NSMutableArray *effectsToAdd    = [NSMutableArray array];
        NSMutableArray *effectsToRemove = [NSMutableArray array];

        for (AUAudioUnit *effect in _effectAudioUnits) {
            if (![effectAudioUnits containsObject:effect]) {
                [effectsToAdd addObject:effect];
            }
        }

        for (AUAudioUnit *effect in effectAudioUnits) {
            if (![_effectAudioUnits containsObject:effect]) {
                [effectsToRemove addObject:effect];
            }
        }
    
        _effectAudioUnits = effectAudioUnits;
        [self _reconnectGraph];
        
        for (AUAudioUnit *unit in effectsToRemove) {
            [unit reset];
        }
    }
}


@end
