// (c) 2024 Ricci Adams
// MIT License (or) 1-clause BSD License
//
// In-process Audio Units wrapping the declick and dehum DSP cores from
// https://github.com/.../airwindows-foobar2000 (plugins/foobar2000_dsp).
// declick_core.{h,cpp} and dehum_core.{h,cpp} are verbatim copies of the
// portable cores from that tree -- update them by copying, not by editing.

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

extern const OSType EmbraceRestorationManufacturer;
extern const OSType EmbraceDeclickSubType;
extern const OSType EmbraceDehumSubType;

// Registers both units with AudioComponent so -[AUAudioUnit initWithComponentDescription:]
// can find them.  Call once, before any EffectType lookup.
extern void EmbraceRegisterRestorationAudioUnits(void);

#ifdef __cplusplus
}
#endif
