// (c) 2016-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, WorkerTrackCommand) {
    WorkerTrackCommandReadMetadata,         // Reads the file metadating using AVAsset
    WorkerTrackCommandReadLoudness,         // Reads loudness via LoudnessAnalyzer
    WorkerTrackCommandReadLoudnessImmediate // Reads loudness via LoudnessAnalyzer immediately
};


@protocol WorkerProtocol

- (void) cancelUUID:(NSUUID *)uuid;

// `measuresTempo` rides on the two loudness commands and is ignored by the
// metadata one.  The tempo, rhythm and key come out of the decode the loudness
// scan already performs, so measuring is nearly free once that decode is
// happening -- but only nearly, and the app turns it off when nothing would
// read the answer.  It is named for the tempo, which was first, and measures
// all three: the key is not a separate switch because it would only save the
// cheap half of a scan whose cost is the decode.  A scan asked not to measure
// leaves all three out of its reply rather than reporting Unknown, because an
// Unknown that was never looked for is indistinguishable from one that was,
// and the track would never be measured again.
- (void) performTrackCommand: (WorkerTrackCommand) command
                        UUID: (NSUUID *) uuid
                bookmarkData: (NSData *) bookmarkData
            originalFilename: (NSString *) originalFilename
               measuresTempo: (BOOL) measuresTempo
                       reply: (void (^)(NSDictionary *))reply;

- (void) performLibraryParseWithReply: (void (^)(NSDictionary *))reply;

@end
