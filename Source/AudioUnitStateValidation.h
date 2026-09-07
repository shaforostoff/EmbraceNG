// (c) 2025 EmbraceNG contributors
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

// Apple's audio units do not validate the opaque parameter blob inside a saved
// -fullState dictionary.  The blob is laid out as
//
//     [8-byte header][big-endian uint32 record count][count x 8-byte records]
//
// and nothing cross-checks that count against the blob's real length, so a
// truncated or corrupted preset walks CoreAudio's parser off the end of the
// allocation and crashes the process inside -setFullState:.  See
// Tests/README.md for the disassembly and the reproducer.
//
// This validates the blob before it reaches the audio unit.  It only applies
// to Apple-manufactured units, whose blob format is CoreAudio's own; a
// third-party unit's state is opaque to us and is always passed through.

extern BOOL EmbraceAudioUnitFullStateIsWellFormed(NSDictionary *fullState,
                                                  AudioComponentDescription componentDescription);


// Apple's AUNBandEQ editor (AUNBandEQView) traps inside AppKit when the band
// count changes underneath it: -[CAAppleEQGraphView updateGraphFrame] recomputes
// geometry from controls the change has already invalidated.  Three or four
// changes are enough, and the editor cannot be rebuilt to recover -- an audio
// unit only ever hands out one view controller.
//
// Applying state with the band count held at whatever the unit already has
// avoids it entirely, and costs nothing in practice: the app never varies the
// count, and AUNBandEQ exposes all its bands regardless, leaving unused ones
// bypassed.  Returns fullState unchanged for anything but Apple's N-band EQ.

extern NSDictionary *EmbraceAudioUnitFullStateByPreservingBandCount(NSDictionary *fullState,
                                                                    AUAudioUnit *audioUnit);

#ifdef __cplusplus
}
#endif
