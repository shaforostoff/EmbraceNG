// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

extern NSString * const TrackDidModifyTitleNotificationName;
extern NSString * const TrackDidModifyExternalURLNotificationName;
extern NSString * const TrackDidModifyDurationNotificationName;

@class TrackAnalyzer;

typedef NS_ENUM(NSInteger, TrackStatus) {
    TrackStatusQueued    = 0,  // Track is queued
    TrackStatusPreparing = 3,  // Track is preparing or in auto gap
    TrackStatusPlaying   = 1,  // Track is active
    TrackStatusPlayed    = 2   // Track was played
};


typedef NS_ENUM(NSInteger, TrackLabel) {
    TrackLabelNone,
    TrackLabelRed,
    TrackLabelOrange,
    TrackLabelYellow,
    TrackLabelGreen,
    TrackLabelBlue,
    TrackLabelPurple,
        
    TrackLabelMultiple = NSNotFound
};


@interface Track : NSObject

+ (void) clearPersistedState;

+ (instancetype) trackWithUUID:(NSUUID *)uuid;

+ (instancetype) trackWithFileURL:(NSURL *)url;

- (void) cancelLoad;

- (void) clearAndCleanup;
- (void) startPriorityAnalysis;

// playedTime represents the absolute timestamp when a track moved from queued to not-queued
- (NSDate *) playedTimeDate;
@property (nonatomic, readonly) NSTimeInterval playedTime;


// estimatedEndTime may either be a relative date (when not playing a track)
// or an absolute date (when playing a track).  estimatedEndTimeDate returns
// the correct value
//
- (NSDate *) estimatedEndTimeDate;

- (Track *) duplicatedTrack;

@property (nonatomic, readonly) BOOL isResolvingURLs;
@property (nonatomic, readonly) NSURL *externalURL;
@property (nonatomic, readonly) NSURL *internalURL;
@property (nonatomic, readonly) NSUUID *UUID;


// Read/Write
@property (nonatomic) TrackStatus trackStatus;
@property (nonatomic) BOOL stopsAfterPlaying;
@property (nonatomic) BOOL ignoresAutoGap;

@property (nonatomic) NSTimeInterval expectedDuration;

@property (nonatomic) NSTimeInterval estimatedEndTime;
@property (nonatomic) NSError *error;

@property (nonatomic) TrackLabel trackLabel;
@property (nonatomic, getter=isDuplicate) BOOL duplicate;

@property (nonatomic, readonly) NSString *titleForSimilarTitleDetection;

// Metadata
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *album;
@property (nonatomic, readonly) NSString *albumArtist;
@property (nonatomic, readonly) NSString *artist;
@property (nonatomic, readonly) NSString *comments;
@property (nonatomic, readonly) NSString *composer;
@property (nonatomic, readonly) NSString *grouping;
@property (nonatomic, readonly) NSString *genre;
@property (nonatomic, readonly) NSString *initialKey;
@property (nonatomic, readonly) NSString *recordedDate;

@property (nonatomic, readonly) NSInteger beatsPerMinute;
@property (nonatomic, readonly) NSTimeInterval startTime;
@property (nonatomic, readonly) NSTimeInterval stopTime;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) NSInteger databaseID;
@property (nonatomic, readonly) Tonality tonality;
@property (nonatomic, readonly) NSInteger energyLevel;
@property (nonatomic, readonly) NSInteger year;

@property (nonatomic, readonly) NSTimeInterval decodedDuration;
@property (nonatomic, readonly) double  trackLoudness;
@property (nonatomic, readonly) double  trackPeak;
@property (nonatomic, readonly) NSData *overviewData;
@property (nonatomic, readonly) double  overviewRate;

// Dynamic
@property (nonatomic, readonly) NSTimeInterval playDuration;
@property (nonatomic, readonly) NSTimeInterval silenceAtStart;
@property (nonatomic, readonly) NSTimeInterval silenceAtEnd;
@property (nonatomic, readonly) BOOL didAnalyzeLoudness;

@end
