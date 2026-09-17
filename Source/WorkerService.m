// (c) 2016-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "WorkerService.h"

#import "BPMAnalyzer.h"
#import "HugAudioFile.h"
#import "HugUtils.h"
#import "TrackKeys.h"
#import "LoudnessMeasurer.h"
#import "MetadataParser.h"

#import <iTunesLibrary/iTunesLibrary.h>

static dispatch_queue_t sMetadataQueue           = nil;
static dispatch_queue_t sLibraryQueue            = nil;
static dispatch_queue_t sLoudnessImmediateQueue  = nil;
static dispatch_queue_t sLoudnessBackgroundQueue = nil;

static NSMutableSet *sCancelledUUIDs = nil;
static NSMutableSet *sLoudnessUUIDs  = nil;


@interface Worker : NSObject <WorkerProtocol>

@end


@implementation Worker {
    ITLibrary *_library;
}

+ (void) initialize
{
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sMetadataQueue           = dispatch_queue_create("metadata",            DISPATCH_QUEUE_SERIAL);
        sLibraryQueue            = dispatch_queue_create("library",             DISPATCH_QUEUE_SERIAL);
        sLoudnessImmediateQueue  = dispatch_queue_create("loudness-immediate",  DISPATCH_QUEUE_SERIAL);
        sLoudnessBackgroundQueue = dispatch_queue_create("loudness-background", DISPATCH_QUEUE_SERIAL);

        sCancelledUUIDs = [NSMutableSet set];
        sLoudnessUUIDs  = [NSMutableSet set];
    });
}


static NSDictionary *sReadMetadata(NSURL *internalURL, NSString *originalFilename)
{
    NSString *fallbackTitle = [originalFilename stringByDeletingPathExtension];

    MetadataParser *parser = [[MetadataParser alloc] initWithURL:internalURL fallbackTitle:fallbackTitle];
    
    return [parser metadata];
}


static NSDictionary *sReadLoudness(NSURL *internalURL)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    HugAudioFile *audioFile = [[HugAudioFile alloc] initWithFileURL:internalURL];
  
    if ([audioFile open]) {
        NSInteger fileLengthFrames = [audioFile fileLengthFrames];
        AudioStreamBasicDescription format = [audioFile format];

        NSInteger framesRemaining = fileLengthFrames;
        NSInteger bytesRemaining  = framesRemaining * format.mBytesPerFrame;
        NSInteger bytesRead = 0;

        LoudnessMeasurer *measurer = LoudnessMeasurerCreate(format.mChannelsPerFrame, format.mSampleRate, framesRemaining);

        // The tempo and the rhythm come out of the same pass.  Reading a track
        // is by far the expensive part of this -- the analysis itself runs at
        // hundreds of times realtime -- so the one thing worth insisting on is
        // that the file is not decoded twice to answer two questions about it.
        BPMAnalyzer *analyzer = BPMAnalyzerCreate(format.mChannelsPerFrame, format.mSampleRate, framesRemaining);

        AudioBufferList *fillBufferList = HugAudioBufferListCreate(format.mChannelsPerFrame, 4096 * 16, YES);

        BOOL ok = YES;
        while (ok) {
            UInt32 frameCount = (UInt32)framesRemaining;
            ok = [audioFile readFrames:&frameCount intoBufferList:fillBufferList];

            if (frameCount) {
                LoudnessMeasurerScanAudioBuffer(measurer, fillBufferList, frameCount);
                BPMAnalyzerScanAudioBuffer(analyzer, fillBufferList, frameCount);
            } else {
                break;
            }
            
            framesRemaining -= frameCount;
        
            bytesRead      += frameCount * format.mBytesPerFrame;
            bytesRemaining -= frameCount * format.mBytesPerFrame;

            if (framesRemaining == 0) {
                break;
            }
        }
       
        BPMAnalyzerFinish(analyzer);

        NSTimeInterval decodedDuration = fileLengthFrames / format.mSampleRate;
        
        [result setObject:@(decodedDuration)                       forKey:TrackKeyDecodedDuration];
        [result setObject:LoudnessMeasurerGetOverview(measurer)    forKey:TrackKeyOverviewData];
        [result setObject:@(100)                                   forKey:TrackKeyOverviewRate];
        [result setObject:@(LoudnessMeasurerGetLoudness(measurer)) forKey:TrackKeyTrackLoudness];
        [result setObject:@(LoudnessMeasurerGetPeak(measurer))     forKey:TrackKeyTrackPeak];

        // Both go back whatever the answer was.  The rhythm is written even
        // when nothing could be measured, because an absent rhythm is what the
        // app reads as "never analysed" and re-requests; a track that cannot be
        // measured would otherwise be decoded again on every launch.
        [result setObject:@(BPMAnalyzerGetBeatsPerMinute(analyzer)) forKey:TrackKeyDetectedBPM];
        [result setObject:BPMAnalyzerGetRhythm(analyzer)            forKey:TrackKeyDetectedRhythm];

        HugAudioBufferListFree(fillBufferList, YES);
        LoudnessMeasurerFree(measurer);
        BPMAnalyzerFree(analyzer);

    } else {
        if ([audioFile error]) {
            NSData *errorData = [NSKeyedArchiver archivedDataWithRootObject:[audioFile error] requiringSecureCoding:NO error:nil];
            [result setObject:errorData forKey:TrackKeyError];
        }
    }

    return result;
}


- (void) cancelUUID:(NSUUID *)UUID
{
    [sCancelledUUIDs addObject:UUID];
}


- (void) performTrackCommand: (WorkerTrackCommand) command
                        UUID: (NSUUID *) UUID
                bookmarkData: (NSData *) bookmarkData
            originalFilename: (NSString *) originalFilename
                       reply: (void (^)(NSDictionary *))reply
{
    NSError *error = nil;
    NSURL *internalURL = [NSURL URLByResolvingBookmarkData: bookmarkData
                                                   options: NSURLBookmarkResolutionWithoutUI
                                             relativeToURL: nil
                                       bookmarkDataIsStale: NULL
                                                     error: &error];

    if (error) NSLog(@"%@", error);

    if (command == WorkerTrackCommandReadMetadata) {
        dispatch_async(sMetadataQueue, ^{ @autoreleasepool {
            if (![sCancelledUUIDs containsObject:UUID]) {
                reply(sReadMetadata(internalURL, originalFilename));
            }
        } });

    } else if (command == WorkerTrackCommandReadLoudness || command == WorkerTrackCommandReadLoudnessImmediate) {
        BOOL             isImmediate = (command == WorkerTrackCommandReadLoudnessImmediate);
        dispatch_queue_t queue       = isImmediate ? sLoudnessImmediateQueue : sLoudnessBackgroundQueue;

        dispatch_async(queue, ^{ @autoreleasepool {
            if (![sCancelledUUIDs containsObject:UUID] && ![sLoudnessUUIDs containsObject:UUID]) {
                [sLoudnessUUIDs addObject:UUID];

                NSDictionary *dictionary = sReadLoudness(internalURL);

                dispatch_async(dispatch_get_main_queue(), ^{
                    reply(dictionary);
                });
            }
        } });
    }
}


- (void) performLibraryParseWithReply:(void (^)(NSDictionary *))reply
{
    dispatch_async(sLibraryQueue, ^{
        if (!_library) {
            NSError *error = nil;
            _library = [ITLibrary libraryWithAPIVersion:@"1.0" error:&error];
            NSLog(@"%@", error);
        } else {
            [_library reloadData];
        }
        
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        
        for (ITLibMediaItem *mediaItem in [_library allMediaItems]) {
            NSUInteger startTime = [mediaItem startTime];
            NSUInteger stopTime  = [mediaItem stopTime];

            if (startTime || stopTime) {
                NSMutableDictionary *trackData = [NSMutableDictionary dictionaryWithCapacity:2];
                
                if (startTime) [trackData setObject:@(startTime / 1000.0) forKey:TrackKeyStartTime];
                if (stopTime)  [trackData setObject:@(stopTime  / 1000.0) forKey:TrackKeyStopTime];
                
                NSString *location = [[mediaItem location] path];
                if (location) [result setObject:trackData forKey:location];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            reply(result);
        });
    });
}

@end


#pragma mark - WorkerDelegate

@interface WorkerDelegate : NSObject <NSXPCListenerDelegate>
@end


@implementation WorkerDelegate

- (BOOL) listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection
{
    NSXPCInterface *exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(WorkerProtocol)];
    [connection setExportedInterface:exportedInterface];
    
    Worker *exportedObject = [[Worker alloc] init];
    [connection setExportedObject:exportedObject];
    
    [connection resume];
    
    return YES;
}

@end


static WorkerDelegate *sWorkerDelegate = nil;

int main(int argc, const char *argv[])
{
    sWorkerDelegate = [[WorkerDelegate alloc] init];
    
    NSXPCListener *listener = [NSXPCListener serviceListener];
    [listener setDelegate:sWorkerDelegate];
    
    [listener resume];

    return 0;
}
