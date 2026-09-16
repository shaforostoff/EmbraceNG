// (c) 2026 Nick Shaforostov
// MIT License (or) 1-clause BSD License

// Puts the effect chain on a different setting for cortinas.
//
// A cortina is the track played between tandas to clear the floor, and it is
// not a tango: it is whatever the DJ likes, usually a modern recording with
// none of the problems that the declick, dehum and EQ settings for a 1940s
// shellac transfer exist to solve.  Those settings are actively wrong for it.
//
// So: an effect that has a preset named "cortina" among its recent presets gets
// that preset loaded whenever the track playing is not a tango, vals, milonga
// or candombe, and gets exactly what it was holding before put back the moment
// one of those four comes round again.  An effect with no such preset is never
// touched, which is what makes this opt-in per effect -- saving one under that
// name is the whole of the setup, and deleting it is the whole of the undo.
//
// What the track is comes from -[Track danceRhythm]: the genre tag where the
// file has one, and bpmcore's measurement where it does not.
//
// Two things are worth knowing about the restore:
//
//   * It is a restore, not an undo.  Settings changed by hand while a cortina
//     plays are on top of a state that is about to be put back, and go with it.
//     The effects window is for between tandas, which is exactly when a cortina
//     is playing, so this is the one sharp edge here.
//   * What gets written to disk is the state being held for the restore, not
//     the cortina preset over the top of it -- see -persistentAudioPresetForEffect:.
//     A quit, a crash or an edit to the chain in the middle of a cortina all
//     leave the user's own settings in NSUserDefaults.

#import <Foundation/Foundation.h>

@class Effect, Track;

// "cortina".  Matched against a recent preset's file name without its
// extension, case- and diacritic-insensitively.
extern NSString * const CortinaPresetName;


@interface CortinaEffects : NSObject

+ (instancetype) sharedInstance;

// Call with the track about to play.  Loads or restores as that track requires,
// and does nothing at all when the chain is already the right way round, so
// calling it twice for the same track is free.
- (void) updateWithTrack:(Track *)track effects:(NSArray<Effect *> *)effects;

// Puts every effect back to what it was holding before a cortina preset was
// loaded over it, and forgets the saved state.
- (void) restoreEffects:(NSArray<Effect *> *)effects;

// The settings to persist for this effect: what the user chose, even while a
// cortina preset is audible over the top of them.  Its own current settings
// when no cortina preset is loaded, which is almost always.
- (NSDictionary *) persistentAudioPresetForEffect:(Effect *)effect;

// True while a cortina preset is loaded on at least one effect.
@property (nonatomic, readonly, getter=isEngaged) BOOL engaged;

@end
