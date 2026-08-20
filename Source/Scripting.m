// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "Scripting.h"
#import "Track.h"
#import "Effect.h"
#import "EffectType.h"
#import "SetlistController.h"
#import "TracksController.h"
#import "AppDelegate.h"
#import "MusicAppManager.h"
#import "Preferences.h"

@interface Track (Scripting)
@end


@interface NSApplication (Scripting)
@end


@interface Effect (Scripting)
@end


@implementation NSApplication (Scripting)

- (NSNumber *) scriptingPlayerState
{
    return [[Player sharedInstance] isPlaying] ? @1 : @0;
}


- (NSArray *) scriptingEffects
{
    return [[Player sharedInstance] effects];
}


- (NSArray *) scriptingTracks
{
    return [[[GetAppDelegate() setlistController] tracksController] tracks];
}


- (Track *) scriptingCurrentTrack
{
    return [[Player sharedInstance] currentTrack];
}


- (NSNumber *) scriptingCurrentIndex
{
    Track *currentTrack = [[Player sharedInstance] currentTrack];
    if (!currentTrack) return @(0);

    NSArray *tracks = [[[GetAppDelegate() setlistController] tracksController] tracks];
    NSUInteger index = [tracks indexOfObject:currentTrack];
    
    if (index == NSNotFound) {
        return @(0);
    } else {
        return @(index + 1);
    }
}


- (NSNumber *) scriptingElapsedTime
{
    Player *player = [Player sharedInstance];
    return [player isPlaying] ? @([player timeElapsed]) : @0;
}


- (NSNumber *) scriptingRemainingTime
{
    Player *player = [Player sharedInstance];
    return [player isPlaying] ? @([player timeRemaining]) : @0;
}


- (void) setScriptingVolume:(NSNumber *)number
{
    [[Player sharedInstance] setVolume:[number doubleValue]];
}


- (NSNumber *) scriptingVolume
{
    return @([[Player sharedInstance] volume]);
}


- (void) setScriptingMinimumSilence:(NSNumber *)number
{
    return [[GetAppDelegate() setlistController] setMinimumSilenceBetweenTracks:[number integerValue]];
}


- (NSNumber *) scriptingMinimumSilence
{
    return @([[GetAppDelegate() setlistController] minimumSilenceBetweenTracks]);
}


- (void) handlePlayScriptCommand:(NSScriptCommand *)command
{
    Player *player = [Player sharedInstance];
    
    if (![player isPlaying]) {
        [player play];
    }
}


- (void) handleStopScriptCommand:(NSScriptCommand *)command
{
    Player *player = [Player sharedInstance];
    
    if ([player isPlaying]) {
        [player hardStop];
    }
}


@end


@implementation Track (Scripting)

- (NSScriptObjectSpecifier *) objectSpecifier
{
    NSScriptClassDescription *containerDescription = (NSScriptClassDescription *)[NSApp classDescription];
    return [[NSUniqueIDSpecifier alloc] initWithContainerClassDescription:containerDescription containerSpecifier:nil key:@"scriptingTracks" uniqueID:[self scriptingID]];
}


- (NSString *) scriptingID
{
    return [[self UUID] UUIDString];
}


- (NSString *) scriptingAggregate
{
    NSString *(^getSanitizedString)(NSString *) = ^(NSString *inString) {
        if (!inString) return @"";

        if ([inString rangeOfString:@"\t"].location != NSNotFound) {
            return [inString stringByReplacingOccurrencesOfString:@"\t" withString:@"  "];
        } else {
            return inString;
        }
    };

    return [NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@\t%@\t%@\t%@",
        getSanitizedString( [self title]       ),
        getSanitizedString( [self artist]      ),
        getSanitizedString( [self album]       ),
        getSanitizedString( [self genre]       ),
        getSanitizedString( [self comments]    ),
        getSanitizedString( [self albumArtist] ),
        getSanitizedString( [self composer]    ),
        getSanitizedString( [self grouping]    )
    ];
}


- (NSNumber *) scriptingTrackStatus
{
    return @([self trackStatus]);
}


- (NSString *) scriptingTitle
{
    return [self title];
}


- (NSString *) scriptingAlbumArtist
{
    return [self albumArtist];
}


- (NSString *) scriptingAlbum
{
    return [self album];
}


- (NSString *) scriptingArtist
{
    return [self artist];
}


- (NSString *) scriptingComment
{
    return [self comments];
}


- (NSString *) scriptingComposer
{
    return [self composer];
}


- (NSString *) scriptingGrouping
{
    return [self grouping];
}


- (NSString *) scriptingGenre
{
    return [self genre];
}


- (NSNumber *) scriptingDuration
{
    return @([self playDuration]);
}


- (NSURL *) scriptingFile
{
    return [self externalURL];
}


- (NSNumber *) scriptingDatabaseID
{
    return @([self databaseID]);
}


- (NSNumber *) scriptingEnergyLevel
{
    return @([self energyLevel]);
}


- (void) setScriptingExpectedDuration:(NSNumber *)expectedDuration
{
    [self setExpectedDuration:[expectedDuration doubleValue]];
}


- (NSNumber *) scriptingExpectedDuration
{
    return @([self expectedDuration]);
}   


- (void) setScriptingLabel:(NSNumber *)scriptingLabel
{
    TrackLabel label = [scriptingLabel integerValue];
    Preferences *preferences = [Preferences sharedInstance];
    
    if (![preferences showsLabelDots] && ![preferences showsLabelStripes] && (label != TrackLabelNone)) {
        [preferences setShowsLabelStripes:YES];
    }

    [self setTrackLabel:label];
}


- (NSNumber *) scriptingLabel
{
    return @([self trackLabel]);
}


- (void) setScriptingStopsAfterPlaying:(NSNumber *)stopsAfterPlaying
{
    [self setStopsAfterPlaying:[stopsAfterPlaying boolValue]];
}


- (NSNumber *) scriptingStopsAfterPlaying
{
    return @([self stopsAfterPlaying]);
}


- (void) setScriptingIgnoresAutoGap:(NSNumber *)ignoresAutoGap
{
    [self setIgnoresAutoGap:[ignoresAutoGap boolValue]];
}


- (NSNumber *) scriptingIgnoresAutoGap
{
    return @([self ignoresAutoGap]);
}


- (NSString *) scriptingKeySignature
{
    return GetTraditionalStringForTonality([self tonality]);
}


- (NSNumber *) scriptingYear
{
    return @([self year]);
}


- (NSString *) scriptingRecordedDate
{
    return [self recordedDate];
}


@end




@implementation Effect (Scripting)


- (NSScriptObjectSpecifier *) objectSpecifier
{
    NSScriptClassDescription *containerDescription = (NSScriptClassDescription *)[NSApp classDescription];
    return [[NSUniqueIDSpecifier alloc] initWithContainerClassDescription:containerDescription containerSpecifier:nil key:@"scriptingEffects" uniqueID:[self scriptingID]];
}


- (NSString *) scriptingID
{
    return [[self UUID] UUIDString];
}


- (NSString *) scriptingName
{
    return [[self type] name];
}


- (NSString *) scriptingManufacturer
{
    return [[self type] manufacturer];
}


- (void) setScriptingBypass:(BOOL)bypass
{
    [self setBypass:bypass];
}


- (BOOL) scriptingBypass
{
    return [self bypass];
}

@end
