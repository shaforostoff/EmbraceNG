// (c) 2026 Nick Shaforostov
// MIT License (or) 1-clause BSD License

#import "CortinaEffects.h"

#import "DanceRhythm.h"
#import "Effect.h"
#import "EffectType.h"
#import "Log.h"
#import "RecentPresets.h"
#import "Track.h"

NSString * const CortinaPresetName = @"cortina";


@implementation CortinaEffects {
    // Effect UUID string -> the settings that effect was holding when its
    // cortina preset was loaded over them.  Membership is also the record of
    // which effects are currently switched, so there is no second flag to keep
    // in step with it.
    NSMutableDictionary<NSString *, NSDictionary *> *_savedPresets;
}


+ (instancetype) sharedInstance
{
    static CortinaEffects *sSharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sSharedInstance = [[CortinaEffects alloc] init];
    });

    return sSharedInstance;
}


- (id) init
{
    if ((self = [super init])) {
        _savedPresets = [NSMutableDictionary dictionary];
    }

    return self;
}


#pragma mark - Private Methods

static NSString *sKeyForEffect(Effect *effect)
{
    return [[effect UUID] UUIDString];
}


// An effect deleted from the chain while a cortina was playing has nothing left
// to restore to, and its entry would otherwise sit here for the rest of the
// session claiming a switch that no longer exists.
//
- (void) _forgetEffectsMissingFrom:(NSArray<Effect *> *)effects
{
    if (![_savedPresets count]) return;

    NSMutableSet *live = [NSMutableSet set];

    for (Effect *effect in effects) {
        NSString *key = sKeyForEffect(effect);
        if (key) [live addObject:key];
    }

    for (NSString *key in [_savedPresets allKeys]) {
        if (![live containsObject:key]) {
            EmbraceLog(@"CortinaEffects", @"Forgetting saved settings for removed effect %@", key);
            [_savedPresets removeObjectForKey:key];
        }
    }
}


- (void) _loadCortinaPresetsForEffects:(NSArray<Effect *> *)effects
{
    for (Effect *effect in effects) {
        NSString *key = sKeyForEffect(effect);
        if (!key) continue;

        // Already switched.  Saving again here would overwrite the user's
        // settings with the cortina preset, which is how two cortinas in a row
        // would lose them for good.
        if ([_savedPresets objectForKey:key]) continue;

        NSString *typeName = [[effect type] fullName];

        NSURL *fileURL = GetRecentPresetFileURLWithName(typeName, CortinaPresetName);
        if (!fileURL) continue;

        NSDictionary *saved = [effect audioPreset];
        if (!saved) continue;

        // Deliberately not AddRecentPresetPath(): the app loading this every
        // few minutes would keep the preset pinned to the top of the menu and
        // push out presets the user actually chose.
        if (![effect loadAudioPresetAtFileURL:fileURL]) {
            EmbraceLog(@"CortinaEffects", @"%@ refused the cortina preset at %@", typeName, [fileURL path]);
            continue;
        }

        [_savedPresets setObject:saved forKey:key];

        EmbraceLog(@"CortinaEffects", @"Loaded the cortina preset onto %@", typeName);
    }
}


#pragma mark - Public Methods

- (void) updateWithTrack:(Track *)track effects:(NSArray<Effect *> *)effects
{
    [self _forgetEffectsMissingFrom:effects];

    DanceRhythm rhythm = [track danceRhythm];

    // Unknown counts as danced, so nothing is switched on a track we cannot
    // identify.  The two ways to be wrong are not equal: leaving the DJ's own
    // settings alone on a cortina costs one track played through the settings
    // that were already there, and putting a cortina preset on an unrecognised
    // tango takes the shellac restoration off a track that needs it, in front
    // of a floor.
    BOOL danced = (rhythm == DanceRhythmUnknown) || GetDanceRhythmIsDanced(rhythm);

    EmbraceLog(@"CortinaEffects", @"%@ is %@; %@", track, GetNameForDanceRhythm(rhythm),
        danced ? @"restoring" : @"loading cortina presets");

    if (danced) {
        [self restoreEffects:effects];
    } else {
        [self _loadCortinaPresetsForEffects:effects];
    }
}


- (void) restoreEffects:(NSArray<Effect *> *)effects
{
    if (![_savedPresets count]) return;

    for (Effect *effect in effects) {
        NSString *key = sKeyForEffect(effect);
        if (!key) continue;

        NSDictionary *saved = [_savedPresets objectForKey:key];
        if (!saved) continue;

        // Dropped before the load rather than after it, so that a preset the
        // effect refuses cannot leave this holding a state it will try to
        // install again on every track for the rest of the session.
        [_savedPresets removeObjectForKey:key];

        if (![effect loadAudioPreset:saved]) {
            EmbraceLog(@"CortinaEffects", @"%@ refused its own saved settings", [[effect type] fullName]);
            continue;
        }

        EmbraceLog(@"CortinaEffects", @"Restored %@", [[effect type] fullName]);
    }

    // Anything still here belongs to an effect that was not in the list.
    [self _forgetEffectsMissingFrom:effects];
}


- (NSDictionary *) persistentAudioPresetForEffect:(Effect *)effect
{
    NSString *key = sKeyForEffect(effect);

    NSDictionary *saved = key ? [_savedPresets objectForKey:key] : nil;

    return saved ? saved : [effect audioPreset];
}


- (BOOL) isEngaged
{
    return [_savedPresets count] > 0;
}

@end
