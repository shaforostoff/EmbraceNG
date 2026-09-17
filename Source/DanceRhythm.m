// (c) 2026 Nick Shaforostov
// MIT License (or) 1-clause BSD License

#import "DanceRhythm.h"


DanceRhythm GetDanceRhythmForGenreString(NSString *genre)
{
    if (![genre isKindOfClass:[NSString class]] || ![genre length]) {
        return DanceRhythmUnknown;
    }

    // Folding is what lets one table cover "Tango", "TANGO", "Tangó" and the
    // full-width forms an iTunes library occasionally carries.
    NSString *folded = [genre stringByFoldingWithOptions:
        (NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch)
        locale:nil];

    // Most specific first.  A compound tag names the family and then the
    // rhythm -- "Tango Vals", "Tango Milonga", "Milonga Candombe" -- so the
    // narrower word is the one that says what the floor will dance, and asking
    // for it first is what stops all three reading as Tango.  Nothing acts on
    // the difference today; the logs do.
    //
    struct { const char *needle; DanceRhythm rhythm; } table[] = {
        { "candombe", DanceRhythmCandombe },
        { "milonga",  DanceRhythmMilonga  },
        { "vals",     DanceRhythmVals     },
        { "tango",    DanceRhythmTango    }
    };

    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
        NSString *needle = @(table[i].needle);

        // Containment rather than whole words, because the separator between
        // two of these is not something to rely on: "Tango/Milonga",
        // "Tango-Vals" and "Neotango" are all in real collections, and every
        // inflection that matters -- tangos, valses, milongas, candombes --
        // is this word with something stuck to it.
        if ([folded rangeOfString:needle].location != NSNotFound) {
            return table[i].rhythm;
        }
    }

    return DanceRhythmUnknown;
}


DanceRhythm GetDanceRhythmForDetectedName(NSString *name)
{
    if (![name isKindOfClass:[NSString class]] || ![name length]) {
        return DanceRhythmUnknown;
    }

    // bpmcore's rhythm_name(), which is the only thing that produces these.
    NSDictionary *map = @{
        @"tango":   @( DanceRhythmTango ),
        @"vals":    @( DanceRhythmVals ),
        @"milonga": @( DanceRhythmMilonga ),
        @"reggae":  @( DanceRhythmReggae ),
        @"other":   @( DanceRhythmOther )
    };

    NSNumber *number = [map objectForKey:[name lowercaseString]];

    return number ? [number integerValue] : DanceRhythmUnknown;
}


DanceRhythm GetDanceRhythm(NSString *genre, NSString *detectedName)
{
    if ([genre isKindOfClass:[NSString class]] && [genre length]) {
        DanceRhythm tagged = GetDanceRhythmForGenreString(genre);

        // A tag naming none of the four is not silence -- it is a DJ saying
        // this track is not part of a tanda -- so it answers the question
        // rather than deferring to a measurement that was made without
        // knowing what the track is for.
        return (tagged == DanceRhythmUnknown) ? DanceRhythmOther : tagged;
    }

    return GetDanceRhythmForDetectedName(detectedName);
}


BOOL GetDanceRhythmIsDanced(DanceRhythm rhythm)
{
    return rhythm == DanceRhythmTango    ||
           rhythm == DanceRhythmVals     ||
           rhythm == DanceRhythmMilonga  ||
           rhythm == DanceRhythmCandombe;
}


NSString *GetNameForDanceRhythm(DanceRhythm rhythm)
{
    switch (rhythm) {
        case DanceRhythmTango:    return @"Tango";
        case DanceRhythmVals:     return @"Vals";
        case DanceRhythmMilonga:  return @"Milonga";
        case DanceRhythmCandombe: return @"Candombe";
        case DanceRhythmReggae:   return @"Reggae";
        case DanceRhythmOther:    return @"Other";
        case DanceRhythmUnknown:  break;
    }

    return @"Unknown";
}


BOOL GetWantsTempoMeasurement(
    BOOL       displaysBPM,
    NSString  *detectedRhythm,
    NSInteger  taggedBPM,
    NSString  *taggedGenre
) {
    if ([detectedRhythm isKindOfClass:[NSString class]] && [detectedRhythm length]) {
        return NO;
    }

    BOOL hasGenreTag = [taggedGenre isKindOfClass:[NSString class]] &&
                       [taggedGenre length] > 0;

    BOOL wantsBPM    = displaysBPM && (taggedBPM == 0);
    BOOL wantsRhythm = !hasGenreTag;

    return wantsBPM || wantsRhythm;
}
