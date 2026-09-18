// (c) 2026 EmbraceNG contributors
// MIT License (or) 1-clause BSD License
//
// The two bits of plumbing that Embrace's in-process Audio Units both need.
// They were a byte-identical copy in RestorationAudioUnit.mm and
// ParametricEQAudioUnit.mm, which is two places to fix anything found in
// either.
//
// Objective-C++ only, and inline rather than a .mm of their own: both are a
// handful of lines, one of them is on the render thread, and neither wants a
// cross-translation-unit call there.

#ifndef EMBRACE_AUDIO_UNIT_UTILS_H
#define EMBRACE_AUDIO_UNIT_UTILS_H

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>


// Embrace's graph always hands us real buffers.  A host that does not is asking
// the unit to supply its own, which we do not, so say so rather than carrying a
// scratch buffer whose lifetime the render thread would have to reason about.
//
static inline AUAudioUnitStatus EmbraceAUPrepareBufferList(
    AudioBufferList *bufferList,
    AUAudioFrameCount frameCount
) {
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
        if (!bufferList->mBuffers[i].mData) return kAudioUnitErr_InvalidParameter;
        bufferList->mBuffers[i].mDataByteSize = frameCount * sizeof(float);
    }

    return noErr;
}


static inline AUParameter *EmbraceAUMakeParameter(
    NSString *identifier, NSString *name, AUParameterAddress address,
    AUValue min, AUValue max, AUValue value, AudioUnitParameterUnit unit,
    NSArray<NSString *> *valueStrings)
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
                         valueStrings: valueStrings
                  dependentParameters: nil];

    [parameter setValue:value];

    return parameter;
}


// Declick and dehum name none of their parameters' values, so the overload
// exists to keep fourteen call sites from each carrying a trailing `nil` that
// says nothing.
//
static inline AUParameter *EmbraceAUMakeParameter(
    NSString *identifier, NSString *name, AUParameterAddress address,
    AUValue min, AUValue max, AUValue value, AudioUnitParameterUnit unit)
{
    return EmbraceAUMakeParameter(identifier, name, address, min, max, value, unit, nil);
}


#endif
