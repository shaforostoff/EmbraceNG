// (c) 2026 EmbraceNG contributors
// MIT License (or) 1-clause BSD License
//
// In-process Audio Unit wrapping the parametric EQ core from
// paraeq_core.{h,cpp}, which is portable and framework-free so it can be
// carried upstream beside declick and dehum.  Everything Apple-specific lives
// here.
//
// Registered rather than mapped: unlike the graphic EQs and AppleParametricEQ,
// which are Apple units handed a starting configuration, this is our own unit
// with our own parameters and our own editor.  Which is the point -- Apple's
// N-band EQ editor traps in AppKit when the band count moves underneath it (see
// AudioUnitStateValidation.h), and a unit with a fixed layout and a view of its
// own cannot reach that code at all.

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>


// Parameter addresses.  The order is the order of a console strip read left to
// right -- filter, then the four bands, then the output -- and it is also the
// order a generic parameter form lays them out in, so the two agree.
typedef NS_ENUM(AUParameterAddress, EmbraceParametricEQParameter) {
    EmbraceParametricEQParameterFilterFrequency = 0,
    EmbraceParametricEQParameterFilterSlope,

    EmbraceParametricEQParameterLFGain,
    EmbraceParametricEQParameterLFFrequency,
    EmbraceParametricEQParameterLFBell,

    EmbraceParametricEQParameterLMFGain,
    EmbraceParametricEQParameterLMFFrequency,
    EmbraceParametricEQParameterLMFQ,

    EmbraceParametricEQParameterHMFGain,
    EmbraceParametricEQParameterHMFFrequency,
    EmbraceParametricEQParameterHMFQ,

    EmbraceParametricEQParameterHFGain,
    EmbraceParametricEQParameterHFFrequency,
    EmbraceParametricEQParameterHFBell,

    EmbraceParametricEQParameterOutputGain,

    EmbraceParametricEQParameterCount
};


#ifdef __cplusplus
extern "C" {
#endif

// Deliberately the code the restoration units register under: it identifies the
// app, not the effect.  The name passed to -registerSubclass: is what carries
// the identity EffectType stores, so nothing depends on this being distinct.
extern const OSType EmbraceParametricEQManufacturer;
extern const OSType EmbraceParametricEQSubType;

// Registers the unit with AudioComponent so -[AUAudioUnit
// initWithComponentDescription:] can find it.  Call once, before any EffectType
// lookup.
extern void EmbraceRegisterParametricEQAudioUnit(void);

#ifdef __cplusplus
}

#include "paraeq_core.h"

// The parameter tree read back as core parameters, which is what a response
// curve is drawn from.  `bypass` is not a parameter -- it is the unit's own
// -shouldBypassEffect -- so it comes back false and a caller that cares sets
// it.  Main thread: this reads AUParameter values.
extern paraeq::Params EmbraceParametricEQParamsFromTree(AUParameterTree *parameterTree);

#endif
