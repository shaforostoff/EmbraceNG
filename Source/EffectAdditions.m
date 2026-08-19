// (c) 2015-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "EffectAdditions.h"

NSString * const EmbraceMappedEffect10BandEQ     = @"EmbraceGraphicEQ10";
NSString * const EmbraceMappedEffect31BandEQ     = @"EmbraceGraphicEQ31";
NSString * const EmbraceMappedEffectParametricEQ = @"EmbraceParametricEQ";

NSString * const EmbraceEffectDeclick = @"EmbraceDeclick";
NSString * const EmbraceEffectDehum   = @"EmbraceDehum";


typedef struct {
    AUValue type;
    AUValue frequency;
    AUValue bandwidth;  // In octaves, ignored by the shelves
} ParametricEQBand;


// Band placement for 78rpm shellac transfers, where the useful range is roughly
// 100Hz - 8kHz.  The violin band is centred on sqrt(1500 * 6000) = 3000Hz and is
// log2(6000 / 1500) = 2 octaves wide, so it spans 1500 - 6000Hz.  Every band
// starts at 0dB -- these are starting positions, not a curve.
//
static ParametricEQBand sParametricEQBands[] = {
    { kAUNBandEQFilterType_LowShelf,    100, 0   },  // Rumble and transfer noise under the cello
    { kAUNBandEQFilterType_Parametric,  250, 1.0 },  // Cello and double bass
    { kAUNBandEQFilterType_Parametric,  500, 1.0 },  // Lower mids, bandoneon body
    { kAUNBandEQFilterType_Parametric, 1000, 1.0 },  // Mids, bandoneon reeds and piano
    { kAUNBandEQFilterType_Parametric, 3000, 2.0 },  // Violins
    { kAUNBandEQFilterType_HighShelf,  6000, 0   }   // Above what most shellacs carry
};


@implementation EffectType (EmbraceAdditions)

+ (void) embrace_registerMappedEffects
{
    AudioComponentDescription acd = {0};
    
    acd.componentType = kAudioUnitType_Effect;
    acd.componentSubType = kAudioUnitSubType_GraphicEQ;
    acd.componentManufacturer = kAudioUnitManufacturer_Apple;
    acd.componentFlags = 0;
    acd.componentFlagsMask = 0;

    [self registerMappedTypeWithName:EmbraceMappedEffect10BandEQ audioComponentDescription:&acd configurator:^(AUAudioUnit *unit) {
        AUParameter *parameter = [[unit parameterTree] parameterWithID:kGraphicEQParam_NumberOfBands scope:kAudioUnitScope_Global element:0];
        [parameter setValue:0];
    }];

    [self registerMappedTypeWithName:EmbraceMappedEffect31BandEQ audioComponentDescription:&acd configurator:^(AUAudioUnit *unit) {
        AUParameter *parameter = [[unit parameterTree] parameterWithID:kGraphicEQParam_NumberOfBands scope:kAudioUnitScope_Global element:0];
        [parameter setValue:1.0];
    }];

    acd.componentSubType = kAudioUnitSubType_NBandEQ;

    [self registerMappedTypeWithName:EmbraceMappedEffectParametricEQ audioComponentDescription:&acd configurator:^(AUAudioUnit *unit) {
        AUParameterTree *parameterTree = [unit parameterTree];

        void (^setBandParameter)(AudioUnitParameterID, NSInteger, AUValue) =
            ^(AudioUnitParameterID base, NSInteger band, AUValue value)
        {
            AUParameter *parameter = [parameterTree parameterWithID:(base + (AudioUnitParameterID)band) scope:kAudioUnitScope_Global element:0];
            [parameter setValue:value];
        };

        NSInteger bandCount = sizeof(sParametricEQBands) / sizeof(sParametricEQBands[0]);

        // AUNBandEQ hands us eight bands, all bypassed.  Anything past our layout
        // stays that way, ready for the user to switch on.
        //
        for (NSInteger i = 0; i < bandCount; i++) {
            ParametricEQBand band = sParametricEQBands[i];

            setBandParameter(kAUNBandEQParam_BypassBand, i, 0);
            setBandParameter(kAUNBandEQParam_FilterType, i, band.type);
            setBandParameter(kAUNBandEQParam_Frequency,  i, band.frequency);
            setBandParameter(kAUNBandEQParam_Gain,       i, 0);

            if (band.bandwidth) {
                setBandParameter(kAUNBandEQParam_Bandwidth, i, band.bandwidth);
            }
        }
    }];
}


- (NSString *) friendlyName
{
    NSString *name = [self name];

    NSDictionary *map = @{
        EmbraceMappedEffect10BandEQ:     NSLocalizedString(@"10-band Graphic Equalizer", nil),
        EmbraceMappedEffect31BandEQ:     NSLocalizedString(@"31-band Graphic Equalizer", nil),
        EmbraceMappedEffectParametricEQ: NSLocalizedString(@"Parametric Equalizer", nil),

        EmbraceEffectDeclick: NSLocalizedString(@"Declick", nil),
        EmbraceEffectDehum:   NSLocalizedString(@"Dehum", nil),

        @"AUDynamicsProcessor":   NSLocalizedString(@"Dynamics Processor", nil),
        @"AUHipass":              NSLocalizedString(@"Highpass Filter", nil),
        @"AUBandpass":            NSLocalizedString(@"Bandpass Filter", nil),
        @"AUHighShelfFilter":     NSLocalizedString(@"Highshelf Filter", nil),
        @"AUPeakLimiter":         NSLocalizedString(@"Peak Limiter", nil),
        @"AULowpass":             NSLocalizedString(@"Lowpass Filter", nil),
        @"AULowShelfFilter":      NSLocalizedString(@"Lowshelf Filter", nil),
        @"AUMultibandCompressor": NSLocalizedString(@"Multiband Compressor", nil),
        @"AUParametricEQ":        NSLocalizedString(@"1-Band Parametric Filter", nil),
        @"AUFilter":              NSLocalizedString(@"5-Band Parametric Filter", nil),
    };
    
    NSString *friendlyName = [map objectForKey:name];
    
    if (!friendlyName) {
        friendlyName = name;
    }
    
    return friendlyName;
}


@end
