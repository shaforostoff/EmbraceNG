// (c) 2025 EmbraceNG contributors
// MIT License (or) 1-clause BSD License

#import "AudioUnitStateValidation.h"

// Offset of the big-endian record count, and the size of each record that
// follows it.  Verified against AUNBandEQ, AUGraphicEQ, AUParametricEQ,
// AUDynamicsProcessor, AUMultibandCompressor, AUPeakLimiter, AULowpass,
// AUHighShelfFilter, AUDelay and AUMatrixReverb.
//
static const NSUInteger sCountOffset = 8;
static const NSUInteger sHeaderLength = 12;
static const NSUInteger sRecordLength = 8;


BOOL EmbraceAudioUnitFullStateIsWellFormed(NSDictionary *fullState,
                                           AudioComponentDescription componentDescription)
{
    if (![fullState isKindOfClass:[NSDictionary class]]) return NO;

    // Only Apple's units use this blob layout.  A third-party unit's state is
    // its own business, and guessing at its format would reject valid presets.
    if (componentDescription.componentManufacturer != kAudioUnitManufacturer_Apple) {
        return YES;
    }

    id data = [fullState objectForKey:@"data"];

    // A state with no blob at all is fine -- the unit falls back to defaults.
    if (!data) return YES;

    if (![data isKindOfClass:[NSData class]]) return NO;

    NSData *blob = (NSData *)data;
    NSUInteger length = [blob length];

    if (length < sHeaderLength) return NO;

    const uint8_t *bytes = [blob bytes];
    uint32_t count = ((uint32_t)bytes[sCountOffset + 0] << 24) |
                     ((uint32_t)bytes[sCountOffset + 1] << 16) |
                     ((uint32_t)bytes[sCountOffset + 2] <<  8) |
                     ((uint32_t)bytes[sCountOffset + 3]);

    // Reject before the multiplication can overflow.
    if (count > (NSUIntegerMax - sHeaderLength) / sRecordLength) return NO;

    return (sHeaderLength + ((NSUInteger)count * sRecordLength)) == length;
}


static NSString * const sNumberOfBandsKey = @"numberOfBands";


NSDictionary *EmbraceAudioUnitFullStateByPreservingBandCount(NSDictionary *fullState,
                                                             AUAudioUnit *audioUnit)
{
    if (![fullState isKindOfClass:[NSDictionary class]] || !audioUnit) return fullState;

    AudioComponentDescription acd = [audioUnit componentDescription];

    if (acd.componentManufacturer != kAudioUnitManufacturer_Apple ||
        acd.componentSubType      != kAudioUnitSubType_NBandEQ)
    {
        return fullState;
    }

    id incoming = [fullState objectForKey:sNumberOfBandsKey];
    if (![incoming isKindOfClass:[NSNumber class]]) return fullState;

    id current = [[audioUnit fullState] objectForKey:sNumberOfBandsKey];
    if (![current isKindOfClass:[NSNumber class]]) return fullState;

    if ([incoming unsignedIntValue] == [current unsignedIntValue]) return fullState;

    NSMutableDictionary *preserved = [fullState mutableCopy];
    [preserved setObject:current forKey:sNumberOfBandsKey];

    return preserved;
}
