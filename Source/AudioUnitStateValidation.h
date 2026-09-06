// (c) 2025 EmbraceNG contributors
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

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
