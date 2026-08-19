// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Cocoa/Cocoa.h>
#import "Player.h"

@class TracksController;


typedef NS_ENUM(NSInteger, PlaybackAction) {
    PlaybackActionPlay = 0,
    PlaybackActionStop,
    PlaybackActionShowIssue
};


@interface SetlistController : NSWindowController

- (IBAction) performPreferredPlaybackAction:(id)sender;
- (PlaybackAction) preferredPlaybackAction;
- (BOOL) isPreferredPlaybackActionEnabled;

- (void) handleNonSpaceKeyDown;

- (IBAction) playSelectedTrack:(id)sender;

- (IBAction) increaseVolume:(id)sender;
- (IBAction) decreaseVolume:(id)sender;
- (IBAction) increaseAutoGap:(id)sender;
- (IBAction) decreaseAutoGap:(id)sender;

- (IBAction) showEffects:(id)sender;
- (IBAction) showCurrentTrack:(id)sender;

- (IBAction) changeVolume:(id)sender;
- (IBAction) delete:(id)sender;
- (IBAction) toggleStopsAfterPlaying:(id)sender;
- (IBAction) toggleMarkAsPlayed:(id)sender;
- (IBAction) showGearMenu:(id)sender;

- (void) clear;
- (void) resetPlayedTracks;
- (BOOL) shouldPromptForClear;

- (BOOL) addTracksWithURLs:(NSArray<NSURL *> *)urls;

- (void) copyToPasteboard:(NSPasteboard *)pasteboard;
- (void) exportToFile;
- (void) exportToPlaylist;

- (void) detectDuplicates;

- (IBAction) changeLabel:(id)sender;

- (IBAction) revealTime:(id)sender;

- (void) showAlertForIssue:(PlayerIssue)issue;

@property (nonatomic) NSInteger minimumSilenceBetweenTracks;
@property (readonly) NSString *autoGapTimeString;

@property (nonatomic, weak) Player *player;
@property (nonatomic, strong, readonly) TracksController *tracksController;

@end
