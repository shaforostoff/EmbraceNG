// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

extern NSString * const EffectDidDeallocNotification;

// Posted by the Effect whose settings were just replaced wholesale -- a preset
// loaded, defaults restored, a cortina switched in or back out.  An editor
// showing that effect has to be told, because nothing about -setFullState:
// reaches the controls that were drawn from the old values.
extern NSString * const EffectDidChangeStateNotification;

@class EffectType;
@class EffectSettingsController;

@interface Effect : NSObject

+ (instancetype) effectWithStateDictionary:(NSDictionary *)dictionary;
- (id) initWithStateDictionary:(NSDictionary *)dictionary;

+ (instancetype) effectWithEffectType:(EffectType *)effectType;
- (id) initWithEffectType:(EffectType *)effectType;

- (BOOL) loadAudioPresetAtFileURL:(NSURL *)fileURL;
- (BOOL) saveAudioPresetAtFileURL:(NSURL *)fileURL;
- (void) restoreDefaultValues;

// The same settings an .aupreset holds, without a file in the way.  This is how
// CortinaEffects puts a chain back the way the user left it: what -audioPreset
// hands out now, -loadAudioPreset: installs later.
//
// -loadAudioPreset: screens the blob exactly as a file would be screened, since
// a set list that has been round-tripped through disk is no more trustworthy
// than a preset a user picked, and returns whether it was actually installed.
- (NSDictionary *) audioPreset;
- (BOOL) loadAudioPreset:(NSDictionary *)preset;

- (NSDictionary *) stateDictionary;

// -stateDictionary for settings other than the ones the unit is holding right
// now.  Used when what should be written to disk is not what is audible: a
// cortina preset is on the effect for as long as the cortina plays, and is not
// what the user would want back on relaunch.
- (NSDictionary *) stateDictionaryUsingAudioPreset:(NSDictionary *)preset;

@property (nonatomic) AUAudioUnit *audioUnit;
@property (nonatomic) NSError *audioUnitError;

@property (nonatomic, readonly) NSUUID *UUID;
@property (nonatomic, readonly) EffectType *type;
@property (nonatomic, readonly) BOOL hasCustomView;
@property (nonatomic) BOOL bypass;

@end
