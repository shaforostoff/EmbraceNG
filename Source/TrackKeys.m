// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

NSString * const TrackKeyType             = @"trackType";
NSString * const TrackKeyStatus           = @"trackStatus";
NSString * const TrackKeyLabel            = @"trackLabel";
NSString * const TrackKeyError            = @"error";

NSString * const TrackKeyURL              = @"url";
NSString * const TrackKeyBookmark         = @"bookmark";
NSString * const TrackKeyIgnoresAutoGap   = @"ignoresAutoGap";
NSString * const TrackKeyTitle            = @"title";
NSString * const TrackKeyArtist           = @"artist";
NSString * const TrackKeyAlbum            = @"album";
NSString * const TrackKeyAlbumArtist      = @"albumArtist";
NSString * const TrackKeyComposer         = @"composer";
NSString * const TrackKeyStartTime        = @"startTime";
NSString * const TrackKeyStopTime         = @"stopTime";
NSString * const TrackKeyInitialKey       = @"initialKey";
NSString * const TrackKeyTonality         = @"tonality";
NSString * const TrackKeyTrackLoudness    = @"trackLoudness";
NSString * const TrackKeyTrackPeak        = @"trackPeak";
NSString * const TrackKeyOverviewData     = @"overviewData";
NSString * const TrackKeyOverviewRate     = @"overviewRate";
NSString * const TrackKeyBPM              = @"beatsPerMinute";
NSString * const TrackKeyDatabaseID       = @"databaseID";
NSString * const TrackKeyGrouping         = @"grouping";
NSString * const TrackKeyComments         = @"comments";
NSString * const TrackKeyEnergyLevel      = @"energyLevel";
NSString * const TrackKeyGenre            = @"genre";
NSString * const TrackKeyYear             = @"year";
NSString * const TrackKeyRecordedDate     = @"recordedDate";

// What the audio measured, as opposed to what the file claims.  Kept apart from
// TrackKeyBPM and TrackKeyGenre rather than filled in over them, so that a tag
// added or corrected later wins without anything having to be re-analysed, and
// so a state file says plainly which number came from where.
//
// TrackKeyDetectedRhythm is one of bpmcore's class names -- see DanceRhythm.h --
// and is written even when nothing could be measured, as
// BPMAnalyzerRhythmUnknown.  That is what stops a track too short or too quiet
// to analyse from being re-analysed on every launch forever.
NSString * const TrackKeyDetectedBPM      = @"detectedBeatsPerMinute";
NSString * const TrackKeyDetectedRhythm   = @"detectedRhythm";

// This is the duration as reported by -[AVURLAsset duration]
NSString * const TrackKeyDuration = @"duration";

// This is the duration of the decoded PCM buffer
NSString * const TrackKeyDecodedDuration = @"decodedDuration";

// This is the duration set by the user via an AppleScript
NSString * const TrackKeyExpectedDuration = @"expectedDuration";

