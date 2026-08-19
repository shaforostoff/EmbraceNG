// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

extern NSString * const TracksControllerDidModifyTracksNotificationName;

extern NSString *EmbraceLockedTrackPasteboardType;
extern NSString *EmbraceQueuedTrackPasteboardType;

@class Track, TrackTableView;

@interface TracksController : NSObject <NSTableViewDelegate, NSTableViewDataSource>

- (void) saveState;

- (void) copy:(id)sender;
- (void) paste:(id)sender;

- (Track *) firstQueuedTrack;
- (NSArray *) selectedTracks;

- (BOOL) addTracksWithURLs:(NSArray<NSURL *> *)urls;

- (void) removeAllTracks;
- (void) deselectAllTracks;
- (void) resetPlayedTracks;

- (void) revealTime:(id)sender;

- (void) toggleStopsAfterPlaying:(id)sender;
- (void) toggleIgnoreAutoGap:(id)sender;
- (void) toggleMarkAsPlayed:(id)sender;

- (void) detectDuplicates;

- (NSArray<NSString *> *) readableDraggedTypes;
- (NSDragOperation) validateDrop:(id <NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation;
- (BOOL) acceptDrop:(id <NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation;

- (void) didFinishTrack:(Track *)finishedTrack;

- (Track *) trackAtIndex:(NSUInteger)index;
@property (nonatomic, readonly) NSArray *tracks;

@property (nonatomic, readonly) NSTimeInterval modificationTime;

- (void) markTracksAsPlayedBeforeTrack:(Track *)trackToPlay;

- (BOOL) canDeleteSelectedTracks;
- (IBAction) delete:(id)sender;


@end
