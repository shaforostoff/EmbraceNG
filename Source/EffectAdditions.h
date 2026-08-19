// (c) 2015-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "EffectType.h"

extern NSString * const EmbraceMappedEffect10BandEQ;
extern NSString * const EmbraceMappedEffect31BandEQ;
extern NSString * const EmbraceMappedEffectParametricEQ;

// Registered by RestorationAudioUnit, not mapped -- these are the names
// AudioComponentCopyName reports, and what a saved set list stores.
extern NSString * const EmbraceEffectDeclick;
extern NSString * const EmbraceEffectDehum;


@interface EffectType (EmbraceAdditions)

+ (void) embrace_registerMappedEffects;

- (NSString *) friendlyName;

@end
