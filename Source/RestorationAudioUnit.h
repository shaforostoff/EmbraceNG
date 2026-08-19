// (c) 2024 Ricci Adams
// MIT License (or) 1-clause BSD License
//
// In-process Audio Units wrapping the declick and dehum DSP cores from
// https://github.com/.../airwindows-foobar2000 (plugins/foobar2000_dsp).
// declick_core.{h,cpp} and dehum_core.{h,cpp} are verbatim copies of the
// portable cores from that tree -- update them by copying, not by editing.

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>


// Effects that can shorten their own learning time by looking at a track before
// it plays.  Dehum's detector needs a few seconds of steady evidence to settle on
// a line, which on a file player is time it does not have to spend: reading the
// opening of the file off-thread finds the line before playback reaches it.
//
// Each record carries its own hum, so this is also the point at which whatever
// was learned from the previous track is thrown away.
//
@protocol EmbraceTrackScouting <NSObject>
- (void) embrace_scoutFileURL:(NSURL *)fileURL;
@end


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
