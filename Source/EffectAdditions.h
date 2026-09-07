// (c) 2015-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "EffectType.h"

extern NSString * const EmbraceMappedEffect10BandEQ;
extern NSString * const EmbraceMappedEffect31BandEQ;
extern NSString * const EmbraceMappedEffectAppleParametricEQ;

// Registered audio units of our own rather than mapped Apple ones -- these are
// the names AudioComponentCopyName reports, and what a saved set list stores.
extern NSString * const EmbraceEffectDeclick;
extern NSString * const EmbraceEffectDehum;
extern NSString * const EmbraceEffectParametricEQ;


@interface EffectType (EmbraceAdditions)

+ (void) embrace_registerMappedEffects;

- (NSString *) friendlyName;

@end
