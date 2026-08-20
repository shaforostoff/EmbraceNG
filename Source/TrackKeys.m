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

// This is the duration as reported by -[AVURLAsset duration]
NSString * const TrackKeyDuration = @"duration";

// This is the duration of the decoded PCM buffer
NSString * const TrackKeyDecodedDuration = @"decodedDuration";

// This is the duration set by the user via an AppleScript
NSString * const TrackKeyExpectedDuration = @"expectedDuration";

