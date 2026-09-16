// (c) 2026 Nick Shaforostov
// MIT License (or) 1-clause BSD License

// Presets the user has loaded or saved, most recent first.
//
// Kept per effect type -- an .aupreset only means anything to the unit that
// wrote it -- and keyed on EffectType.fullName, which also keeps the 10- and
// 31-band graphic EQs apart, since they share an AudioComponent but not a
// mapped name.  It lives in NSUserDefaults, so it survives a relaunch.
//
// This was private to EditEffectController, which is where the list is
// produced.  CortinaEffects consumes it without going anywhere near a menu, so
// it is here instead of being reached for through a window controller.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Seven, which is what the "..." menu lists.
extern NSUInteger GetMaximumRecentPresetCount(void);

// Paths, newest first.  Includes presets whose files have since gone: an
// unmounted volume should hide its presets, not make the app forget them.
extern NSArray<NSString *> *GetRecentPresetPaths(NSString *typeName);

// Records a preset as used.  Re-using one moves it to the front rather than
// listing it twice, and the oldest falls off the end.
extern void AddRecentPresetPath(NSString *typeName, NSURL *fileURL);

// The newest recent preset for this type whose file name, without its
// extension, is `name` -- compared case- and diacritic-insensitively, since the
// name is something a person typed into a save panel.
//
// nil when there is none, and also when the newest match is on a volume that is
// not mounted: a preset that cannot be read cannot be loaded, and reporting one
// that is only nearly there would have callers act as though it had been.
extern NSURL *GetRecentPresetFileURLWithName(NSString *typeName, NSString *name);

#ifdef __cplusplus
}
#endif
