// (c) 2014-2026 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "SetlistController.h"

#import "HugAudioDevice.h"

#import "Track.h"
#import "EffectType.h"
#import "Effect.h"
#import "Player.h"
#import "AppDelegate.h"
#import "ExportManager.h"
#import "MusicAppManager.h"
#import "TrackTableCellView.h"
#import "WaveformView.h"
#import "HairlineView.h"
#import "InnerShadowView.h"
#import "EmbraceWindow.h"
#import "MenuLabelView.h"
#import "NoDropImageView.h"
#import "Preferences.h"
#import "SetlistButton.h"
#import "SetlistDangerView.h"
#import "SetlistMeterView.h"
#import "SetlistPlayBar.h"
#import "SetlistSlider.h"
#import "TipArrowFloater.h"
#import "TrackTableView.h"
#import "TracksController.h"

#import <AVFoundation/AVFoundation.h>

static NSString * const sMinimumSilenceKey = @"minimum-silence";
static NSString * const sSavedAtKey = @"saved-at";
static NSString * const sFadeStopPreviousVolumeDelay = @"fade-stop-previous-volume-delay";

static NSInteger sAutoGapMinimum = 0;
static NSInteger sAutoGapMaximum = 16;


@interface SetlistController () <NSTableViewDelegate, NSTableViewDataSource, NSMenuItemValidation, PlayerListener, PlayerTrackProvider, ApplicationEventListener, SetlistSliderDragDelegate>

@property (nonatomic, strong, readwrite) IBOutlet TracksController *tracksController;

@property (nonatomic, strong) IBOutlet NSView *dragSongsView;

@property (nonatomic, strong) IBOutlet NSMenu        *gearMenu;
@property (nonatomic, strong) IBOutlet MenuLabelView *gearMenuLabelView;
@property (nonatomic, weak)   IBOutlet NSMenuItem    *gearMenuLabelSeparator;
@property (nonatomic, weak)   IBOutlet NSMenuItem    *gearMenuLabelItem;

@property (nonatomic, strong) IBOutlet NSMenu        *tableMenu;
@property (nonatomic, strong) IBOutlet MenuLabelView *tableMenuLabelView;
@property (nonatomic, weak)   IBOutlet NSMenuItem    *tableMenuLabelSeparator;
@property (nonatomic, weak)   IBOutlet NSMenuItem    *tableMenuLabelItem;

@property (nonatomic, weak)   IBOutlet NSTextField       *playOffsetField;
@property (nonatomic, weak)   IBOutlet NSTextField       *playRemainingField;
@property (nonatomic, weak)   IBOutlet SetlistButton     *playButton;
@property (nonatomic, weak)   IBOutlet SetlistButton     *gearButton;
@property (nonatomic, weak)   IBOutlet SetlistDangerView *dangerView;
@property (nonatomic, weak)   IBOutlet SetlistMeterView  *meterView;
@property (nonatomic, weak)   IBOutlet SetlistPlayBar    *playBar;
@property (nonatomic, weak)   IBOutlet SetlistSlider     *volumeSlider;

@property (nonatomic, weak)   IBOutlet InnerShadowView *topInnerShadowView;
@property (nonatomic, weak)   IBOutlet InnerShadowView *bottomInnerShadowView;
@property (nonatomic, weak)   IBOutlet NSScrollView    *scrollView;
@property (nonatomic, weak)   IBOutlet NSView          *footerView;
@property (nonatomic, weak)   IBOutlet HairlineView    *bottomSeparator;
@property (nonatomic, weak)   IBOutlet NoDropImageView *autoGapIcon;
@property (nonatomic, weak)   IBOutlet SetlistSlider   *autoGapSlider;
@property (nonatomic, weak)   IBOutlet NSTextField     *autoGapField;

@end

@implementation SetlistController {
    TipArrowFloater *_volumeTooLowFloater;

    BOOL       _commandDown;
    double     _volumeBeforeDrag;
    double     _volumeBeforeKeyboard;
    BOOL       _confirmStop;
    BOOL       _willCalculateStartAndEndTimes;
}


- (id) initWithWindow:(NSWindow *)window
{
    if ((self = [super initWithWindow:window])) {
        [self _loadState];
    }

    return self;
}


- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (NSString *) windowNibName
{
    return @"SetlistWindow";
}


- (void) windowDidLoad
{
    [super windowDidLoad];

    EmbraceWindow *window = (EmbraceWindow *)[self window];
   
    [window setTitlebarAppearsTransparent:YES];
    [window setTitleVisibility:NSWindowTitleHidden];
    [window setMovableByWindowBackground:YES];
    [window setTitle:@""];
    [[window standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
    [[window standardWindowButton:NSWindowZoomButton]        setHidden:YES];

    [window addListener:[self dangerView]];
    [window addListener:[self meterView]];
    [window addListener:[self gearButton]];
    [window addListener:[self playButton]];
    [window addListener:[self volumeSlider]];
    [window addListener:[self playBar]];

    [[self playButton] setIcon:SetlistButtonIconPlay];
    [[self gearButton] setIcon:SetlistButtonIconGear];

    [[self autoGapIcon] setTintColor:[NSColor labelColor]];


    // Add titlebar visual effect view
    {
        NSView *contentView = [[self window] contentView];
        NSScrollView *scrollView = [self scrollView];
        
        NSRect scrollFrame = [scrollView convertRect:[scrollView bounds] toView:contentView];
        
        NSRect headerFrame = [contentView bounds];
        headerFrame.origin.y = NSMaxY(scrollFrame);
        headerFrame.size.height = headerFrame.size.height - headerFrame.origin.y;
        
        NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:headerFrame];
        
        [effectView setMaterial:NSVisualEffectMaterialTitlebar];
        [effectView setBlendingMode:NSVisualEffectBlendingModeWithinWindow];
        [effectView setAutoresizingMask:NSViewWidthSizable|NSViewMinYMargin];
        
        [contentView addSubview:effectView positioned:NSWindowBelow relativeTo:nil];
    }

    [[self topInnerShadowView] setLayoutAttribute:NSLayoutAttributeTop];
    [[self bottomInnerShadowView] setLayoutAttribute:NSLayoutAttributeBottom];

    // Match PlayBar inactive color (used for top separator)
    [[self bottomSeparator] setBorderColor:[NSColor colorNamed:@"SetlistSeparator"]];
    [[self bottomSeparator] setLayoutAttribute:NSLayoutAttributeTop];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handlePreferencesDidChange:)            name:PreferencesDidChangeNotification                object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleTracksControllerDidModifyTracks:) name:TracksControllerDidModifyTracksNotificationName object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleTrackDidModifyDuration:)          name:TrackDidModifyDurationNotificationName  object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleTrackDidModifyTitle:)             name:TrackDidModifyTitleNotificationName             object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleTrackDidModifyExternalURL:)       name:TrackDidModifyExternalURLNotificationName       object:nil];

    [self _handlePreferencesDidChange:nil];

    [self setPlayer:[Player sharedInstance]];
    [self _setupPlayer];

    [[self volumeSlider] setDragDelegate:self];
    [self _updateDragSongsView];

    NSFont *font = [[self autoGapField] font];
    font = [NSFont monospacedDigitSystemFontOfSize:[font pointSize] weight:NSFontWeightMedium];
    [[self autoGapField] setFont:font];

    font = [[self playOffsetField] font];
    font = [NSFont monospacedDigitSystemFontOfSize:[font pointSize] weight:NSFontWeightMedium];
    [[self playOffsetField] setFont:font];

    font = [[self playRemainingField] font];
    font = [NSFont monospacedDigitSystemFontOfSize:[font pointSize] weight:NSFontWeightMedium];
    [[self playRemainingField] setFont:font];

    [window setExcludedFromWindowsMenu:YES];

    [window registerForDraggedTypes:[[self tracksController] readableDraggedTypes]];

    [(Application *)NSApp registerEventListener:self];
}


- (void) application:(Application *)application flagsChanged:(NSEvent *)event
{
    BOOL commandDown = ([event modifierFlags] & NSEventModifierFlagCommand) == NSEventModifierFlagCommand;
    
    if (_commandDown != commandDown) {
        if (commandDown) {
            _volumeBeforeKeyboard = [[Player sharedInstance] volume];
        } else {
            double volumeBeforeKeyboard = _volumeBeforeKeyboard;
            
            if (volumeBeforeKeyboard) {
                _volumeBeforeKeyboard = 0;
                [self _updatePlayButton];
                [self _doFadeStopIfNeededWithBeforeVolume:volumeBeforeKeyboard];
            }
        }

        _commandDown = commandDown;
    }
}


#pragma mark - Private Methods

- (NSDragOperation) draggingEntered:(id <NSDraggingInfo>)sender
{
    return [[self tracksController] validateDrop:sender proposedRow:-1 proposedDropOperation:NSTableViewDropOn];
}


- (BOOL) performDragOperation:(id <NSDraggingInfo>)sender
{
    return [[self tracksController] acceptDrop:sender row:-1 dropOperation:NSTableViewDropOn];
}


#pragma mark - Private Methods


- (void) _updatePlayButton
{
    PlaybackAction action  = [self preferredPlaybackAction];
    BOOL           enabled = [self isPreferredPlaybackActionEnabled];
    
    Player *player = [Player sharedInstance];

    NSString *tooltip  = nil;
    BOOL      outlined = NO;

    SetlistButtonIcon icon = SetlistButtonIconNone;

    SetlistButton *playButton = [self playButton];

    if (action == PlaybackActionShowIssue) {
        icon = SetlistButtonIconDeviceIssue;

        PlayerIssue issue = [player issue];

        if (issue == PlayerIssueDeviceMissing) {
            tooltip = NSLocalizedString(@"The selected output device is not connected", nil);
        } else if (issue == PlayerIssueDeviceHoggedByOtherProcess) {
            tooltip = NSLocalizedString(@"Another application is using the selected output device", nil);
        } else if (issue == PlayerIssueErrorConfiguringHogMode) {
            tooltip = NSLocalizedString(@"Failed to take exclusive access to the selected output device", nil);
        } else if (issue == PlayerIssueErrorConfiguringSampleRate) {
            tooltip = NSLocalizedString(@"The sample rate is not valid for the selected output device", nil);
        } else if (issue == PlayerIssueErrorConfiguringFrameSize) {
            tooltip = NSLocalizedString(@"The number of frames is not valid for the selected output device", nil);
        } else {
            tooltip = NSLocalizedString(@"The selected output device could not be configured", nil);
        }

    } else if (action == PlaybackActionStop) {
        if ([player isFadingOut]) {
            icon     = SetlistButtonIconPlay;
            outlined = YES;
            tooltip  = NSLocalizedString(@"Fading out, click to resume playback", nil);

        } else {
            if ([player isPlaying] && [self _shouldVolumeInvokeFadeStop] && (_volumeBeforeDrag || _volumeBeforeKeyboard)) {
                outlined = YES;
            }

            icon = _confirmStop ? SetlistButtonIconReallyStop : SetlistButtonIconStop;
        }

        enabled = YES;

    } else {
        icon = SetlistButtonIconPlay;

        Track *next = [[self tracksController] firstQueuedTrack];

        if (!next) {
            tooltip = NSLocalizedString(@"Add a track to enable playback", nil);
        }
    }

    [playButton setIcon:icon];
    [playButton setToolTip:tooltip];
    [playButton setOutlined:outlined];
    [playButton setEnabled:enabled];
}


- (void) _handlePreferencesDidChange:(NSNotification *)note
{
    Preferences *preferences = [Preferences sharedInstance];
    
    HugAudioDevice *device       = [preferences mainOutputAudioDevice];
    double          sampleRate   = [preferences mainOutputSampleRate];
    UInt32          frames       = [preferences mainOutputFrames];
    BOOL            hogMode      = [preferences mainOutputUsesHogMode];

    BOOL resetsVolume = hogMode && [preferences mainOutputResetsVolume];
    
    [[Player sharedInstance] updateOutputDevice:device sampleRate:sampleRate frames:frames hogMode:hogMode resetsVolume:resetsVolume];
    
    NSWindow *window = [self window];
    if ([preferences floatsOnTop]) {
        [window setLevel:NSFloatingWindowLevel];
        [window setCollectionBehavior:NSWindowCollectionBehaviorManaged|NSWindowCollectionBehaviorParticipatesInCycle];
        
    } else {
        [window setLevel:NSNormalWindowLevel];
        [window setCollectionBehavior:NSWindowCollectionBehaviorDefault];
    }
    
    [window display];
}


- (void) _handleTracksControllerDidModifyTracks:(NSNotification *)note
{
    [self _calculateStartAndEndTimes];
    [self _updatePlayButton];
    [self _updateDragSongsView];
}


- (void) _handleTrackDidModifyTitle:(NSNotification *)note
{
    DuplicateStatusMode duplicateStatusMode = [[Preferences sharedInstance] duplicateStatusMode];
    
    if (duplicateStatusMode == DuplicateStatusModeSameTitle || duplicateStatusMode == DuplicateStatusModeSimilarTitle) {
        [self detectDuplicates];
    }
}



- (void) _handleTrackDidModifyExternalURL:(NSNotification *)note
{
    [self detectDuplicates];
}



- (void) _handleTrackDidModifyDuration:(NSNotification *)note
{
    if (!_willCalculateStartAndEndTimes) {
        [self performSelector:@selector(_calculateStartAndEndTimes) withObject:nil afterDelay:10];
        _willCalculateStartAndEndTimes = YES;
    }
}


- (void) _loadState
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger silence = [defaults integerForKey:sMinimumSilenceKey];
    [self setMinimumSilenceBetweenTracks:silence];
}


- (void) _updateDragSongsView
{
    BOOL hidden = [[[self tracksController] tracks] count] > 0;
    
    if (hidden) {
        [_dragSongsView setAlphaValue:1];

        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            [[_dragSongsView animator] setAlphaValue:0];
        } completionHandler:^{
            [_dragSongsView removeFromSuperview];
        }];

    } else {
        NSView *scrollView  = [self scrollView];
        NSRect  scrollFrame = [scrollView frame];
        
        NSRect dragFrame = [_dragSongsView frame];
        
        dragFrame.origin.x = NSMinX(scrollFrame) + round((NSWidth( scrollFrame) - NSWidth( dragFrame)) / 2);
        dragFrame.origin.y = NSMinY(scrollFrame) + round((NSHeight(scrollFrame) - NSHeight(dragFrame)) / 2);

        [_dragSongsView setAutoresizingMask:NSViewMinXMargin|NSViewMaxXMargin|NSViewMaxYMargin|NSViewMinYMargin];
        [_dragSongsView setFrame:dragFrame];

        [_dragSongsView setAlphaValue:1];
        [[scrollView superview] addSubview:_dragSongsView];
    }
}


- (void) _markAsSaved
{
    NSTimeInterval t = [NSDate timeIntervalSinceReferenceDate];
    [[NSUserDefaults standardUserDefaults] setObject:@(t) forKey:sSavedAtKey];
}


- (BOOL) _shouldVolumeInvokeFadeStop
{
    double volume = [[Player sharedInstance] volume];
    return volume < 0.025; // around -96dBFS
}


- (void) _doFadeStopIfNeededWithBeforeVolume:(double)beforeVolume
{
    EmbraceLogMethod();

    PlaybackAction action = [self preferredPlaybackAction];
    SetlistButton *playButton = [self playButton];
    
    if ([playButton isEnabled] && beforeVolume) {
        BOOL shouldInvokeFadeStop = [self _shouldVolumeInvokeFadeStop];
        
        if (action == PlaybackActionStop && shouldInvokeFadeStop) {
            [[self playButton] setIcon:SetlistButtonIconPlay animated:YES];
            [[Player sharedInstance] hardStop];
            
            double delayInSeconds = [[NSUserDefaults standardUserDefaults] doubleForKey:sFadeStopPreviousVolumeDelay];

            if (delayInSeconds > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [[Player sharedInstance] setVolume:beforeVolume];
                });

            } else {
                [[Player sharedInstance] setVolume:beforeVolume];
            }
        }
    }
}


- (void) _clearConfirmStop
{
    EmbraceLogMethod();

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_clearConfirmStop) object:nil];

    _confirmStop = NO;
    
    [[self playButton] setIcon:SetlistButtonIconStop animated:YES];
    [self _updatePlayButton];
}


- (void) _increaseOrDecreaseVolumeByAmount:(CGFloat)amount
{
    EmbraceLogMethod();

    Player *player = [Player sharedInstance];

    double oldVolume = [player volume];
    double newVolume = oldVolume + amount;

    if (newVolume > 1.0) newVolume = 1.0;
    if (newVolume < 0.0) newVolume = 0.0;

    [player setVolume:newVolume];
    [_volumeTooLowFloater hide];
}


- (void) _calculateStartAndEndTimes
{
    _willCalculateStartAndEndTimes = NO;

    Player *player = [Player sharedInstance];

    NSTimeInterval now = [player isPlaying] ? [NSDate timeIntervalSinceReferenceDate] : 0.0;
    NSTimeInterval time = 0;

    Track *lastTrack = nil;

    for (Track *track in [[self tracksController] tracks]) {
        NSTimeInterval endTime = 0;

        TrackStatus status = [track trackStatus];
        
        if (status == TrackStatusPlayed) {
            continue;

        } else if (status == TrackStatusPreparing || status == TrackStatusPlaying) {
            if ([track isEqual:[player currentTrack]]) {
                NSTimeInterval expectedDuration = [track expectedDuration];
                NSTimeInterval remaining = (status == TrackStatusPreparing) ? [track playDuration] : [player timeRemaining];
                
                if (expectedDuration) {
                    remaining = expectedDuration - [player timeElapsed];
                    if (remaining < 0) remaining = 0;
                }

                time += remaining;
                endTime = now + time;
            }

        } else if (status == TrackStatusQueued) {
            NSTimeInterval duration = [track expectedDuration];
            if (!duration) duration = [track playDuration];

            time += duration;
            endTime = now + time;
            
            if (lastTrack) {
                NSTimeInterval padding = 0;

                NSTimeInterval minimumSilence = [self minimumSilenceBetweenTracks];

                NSTimeInterval totalSilence = [lastTrack silenceAtEnd] + [track silenceAtStart];
                padding = minimumSilence - totalSilence;
                if (padding < 0) padding = 0;
                
                if (minimumSilence > 0 && padding == 0) {
                    padding = 1.0;
                }

                time += padding;
            }
        }
        
        if (endTime) {
            [track setEstimatedEndTime:endTime];
        }

        lastTrack = track;
    }
}


#pragma mark - Public Methods

- (void) clear
{
    EmbraceLogReopenLogFile();
    EmbraceLog(@"SetlistController", @"-clear");

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:sSavedAtKey];

    [[self tracksController] removeAllTracks];
}


- (void) resetPlayedTracks
{
    EmbraceLogMethod();
    [[self tracksController] resetPlayedTracks];
}


- (BOOL) shouldPromptForClear
{
    NSTimeInterval modifiedAt = [[self tracksController] modificationTime];
    NSTimeInterval savedAt    = [[NSUserDefaults standardUserDefaults] doubleForKey:sSavedAtKey];
    
    NSInteger playedCount = 0;
    for (Track *track in [[self tracksController] tracks]) {
        if ([track trackStatus] == TrackStatusPlayed) {
            playedCount++;
            break;
        }
    }
    
    if ((modifiedAt > savedAt) && (playedCount > 0)) {
        return YES;
    }
    
    return NO;
}


- (BOOL) addTracksWithURLs:(NSArray<NSURL *> *)urls
{
    EmbraceLog(@"SetlistController", @"-addTracksWithURLs: %@", urls);
    return [[self tracksController] addTracksWithURLs:urls];
}



- (void) copyToPasteboard:(NSPasteboard *)pasteboard
{
    EmbraceLogMethod();
    
    NSArray  *tracks   = [[self tracksController] tracks];
    NSString *contents = [[ExportManager sharedInstance] stringWithFormat:ExportManagerFormatPlainText tracks:tracks];

    NSPasteboardItem *item = [[NSPasteboardItem alloc] initWithPasteboardPropertyList:contents ofType:NSPasteboardTypeString];

    [pasteboard clearContents];
    [pasteboard writeObjects:[NSArray arrayWithObject:item]];
}


- (void) exportToFile
{
    NSArray  *tracks = [[self tracksController] tracks];
    NSInteger result = [[ExportManager sharedInstance] runModalWithTracks:tracks];

    if (result == NSModalResponseOK) {
        [self _markAsSaved];
    }
}


- (void) exportToPlaylist
{
    EmbraceLogMethod();

    ExportManager *exportManager = [ExportManager sharedInstance];

    NSArray *tracks = [[self tracksController] tracks];

    NSString *suggestedName = [exportManager suggestedNameWithTracks:tracks];
    NSString *contents = [exportManager stringWithFormat:ExportManagerFormatM3U tracks:tracks];

    NSString *fileName = [suggestedName stringByAppendingPathExtension:@"m3u8"];
    NSString *UUIDString = [[NSUUID UUID] UUIDString];
    
    NSError *error = nil;

    NSString *toPath = [NSTemporaryDirectory() stringByAppendingPathComponent:UUIDString];

    if (!error && toPath) {
        [[NSFileManager defaultManager] createDirectoryAtPath:toPath withIntermediateDirectories:YES attributes:nil error:&error];
        toPath = [toPath stringByAppendingPathComponent:fileName];
    }

    if (!error && toPath) {
        [contents writeToFile:toPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    }

    if (!error && toPath) {
        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];

        NSURL *musicAppURL = [workspace URLForApplicationWithBundleIdentifier:@"com.apple.Music"];
        NSURL *toPathURL = [NSURL fileURLWithPath:toPath];

        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        
        [configuration setAddsToRecentItems:NO];
        [configuration setActivates:NO];
        
        if (toPathURL) {
            [workspace openURLs:@[ toPathURL ] withApplicationAtURL:musicAppURL configuration:configuration completionHandler:nil];
        }
        
        [self _markAsSaved];
    }
}


- (void) detectDuplicates
{
    [_tracksController detectDuplicates];
}


- (PlaybackAction) preferredPlaybackAction
{
    Player *player = [Player sharedInstance];

    PlayerIssue issue = [player issue];

    if (issue != PlayerIssueNone) {
        return PlaybackActionShowIssue;
    
    } else if ([player isPlaying]) {
        return PlaybackActionStop;

    } else {
        return PlaybackActionPlay;
    }
}


- (BOOL) isPlaybackActionEnabled:(PlaybackAction)action
{
    if (action == PlaybackActionPlay) {
        Track *next = [[self tracksController] firstQueuedTrack];
        return next != nil;
    }
    
    return YES;
}


- (BOOL) isPreferredPlaybackActionEnabled
{
    return [self isPlaybackActionEnabled:[self preferredPlaybackAction]];
}


- (void) showAlertForIssue:(PlayerIssue)issue
{
    NSString *messageText     = nil;
    NSString *informativeText = nil;
    NSString *otherButton     = nil;

    HugAudioDevice *device = [[Preferences sharedInstance] mainOutputAudioDevice];
    NSString *deviceName = [device name];

    if (issue == PlayerIssueDeviceMissing) {
        messageText = NSLocalizedString(@"The selected output device is not connected.", nil);
        
        NSString *format = NSLocalizedString(@"Verify that \\U201c%@\\U201d is connected and powered on.", nil);

        informativeText = [NSString stringWithFormat:format, deviceName];
        otherButton = NSLocalizedString(@"Show Preferences", nil);

    } else if (issue == PlayerIssueDeviceHoggedByOtherProcess) {
        messageText = NSLocalizedString(@"Another application is using the selected output device.", nil);

        pid_t hogModeOwner = [device hogModeOwner];
        NSRunningApplication *owner = [NSRunningApplication runningApplicationWithProcessIdentifier:hogModeOwner];
        
        if (owner > 0) {
            NSString *format = NSLocalizedString(@"The application \\U201c%@\\U201d has exclusive access to \\U201c%@\\U201d.", nil);
            NSString *applicationName = [owner localizedName];
            
            informativeText = [NSString stringWithFormat:format, applicationName, deviceName];
        }

    } else if (issue == PlayerIssueErrorConfiguringHogMode) {
        messageText = NSLocalizedString(@"Failed to take exclusive access to the output device.", nil);
        otherButton = NSLocalizedString(@"Show Preferences", nil);

    } else if (issue == PlayerIssueErrorConfiguringSampleRate) {
        messageText = NSLocalizedString(@"The sample rate is not valid for the selected output device.", nil);
        otherButton = NSLocalizedString(@"Show Preferences", nil);

    } else if (issue == PlayerIssueErrorConfiguringFrameSize) {
        messageText = NSLocalizedString(@"The number of frames is not valid for the selected output device.", nil);
        otherButton = NSLocalizedString(@"Show Preferences", nil);

    } else {
        messageText = NSLocalizedString(@"The selected output device could not be configured.", nil);
        otherButton = NSLocalizedString(@"Show Preferences", nil);
    }

    NSAlert *alert = [[NSAlert alloc] init];
    
    [alert setMessageText:messageText];
    [alert setAlertStyle:NSAlertStyleCritical];
    [alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];

    if (informativeText) [alert setInformativeText:informativeText];
    if (otherButton)     [alert addButtonWithTitle:otherButton];
    
    if ([alert runModal] == NSAlertSecondButtonReturn) {
        [GetAppDelegate() showPreferences];
    }
}


- (void) handleNonSpaceKeyDown
{
    if (_confirmStop) {
        [self _clearConfirmStop];
    }
}



#pragma mark - IBActions

- (IBAction) performPreferredPlaybackAction:(id)sender
{
    EmbraceLogMethod();

    PlaybackAction action = [self preferredPlaybackAction];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_clearConfirmStop) object:nil];

    if (action == PlaybackActionShowIssue) {
        [self showAlertForIssue:[[Player sharedInstance] issue]];

    } else if (action == PlaybackActionStop) {
        Player *player = [Player sharedInstance];
        NSInteger fadeOutDuration = [[Preferences sharedInstance] stopFadeOutDuration];

        EmbraceLog(@"SetlistController", @"Performing PlaybackActionStop, _confirmStop is %ld", (long)_confirmStop);

        if ([player isFadingOut]) {
            EmbraceLog(@"SetlistController", @"Resuming playback, fade-out was in progress");

            _confirmStop = NO;

            [player resumeFromFadeOut];
            [[self playButton] setIcon:SetlistButtonIconStop animated:YES];
            [self _updatePlayButton];

            return;
        }

        // A fade-out is reversible for as long as it runs, so it stands in for the
        // confirmation press.  Only ask twice when fading is turned off.
        if ((fadeOutDuration == StopFadeOutDurationNone) && !_confirmStop) {
            _confirmStop = YES;

            [[self playButton] setIcon:SetlistButtonIconReallyStop animated:YES];
            
            [self _updatePlayButton];
            [self performSelector:@selector(_clearConfirmStop) withObject:nil afterDelay:2];

        } else {
            NSEvent *currentEvent = [NSApp currentEvent];
            NSEventType type = [currentEvent type];
            
            BOOL isDoubleClick = NO;

            EmbraceLog(@"SetlistController", @"About to stop with event: %@", currentEvent);

            if ((type == NSEventTypeLeftMouseDown) || (type == NSEventTypeRightMouseDown) || (type == NSEventTypeOtherMouseDown)) {
                isDoubleClick = [currentEvent clickCount] >= 2;
            }
        
            if (!isDoubleClick) {
                _confirmStop = NO;

                if (fadeOutDuration == StopFadeOutDurationNone) {
                    [player hardStop];

                } else {
                    [player fadeOutAndStopWithDuration:fadeOutDuration];

                    [[self playButton] setIcon:SetlistButtonIconPlay animated:YES];
                    [self _updatePlayButton];
                }
            }

            [_volumeTooLowFloater hide];
        }

    } else {
        [[Player sharedInstance] play];

        if ([[Player sharedInstance] volume] < 0.25) {
            if (!_volumeTooLowFloater) _volumeTooLowFloater = [[TipArrowFloater alloc] init];
            [_volumeTooLowFloater showWithView:_volumeSlider rect:[_volumeSlider knobRect]];
        }
    }
}


- (IBAction) increaseVolume:(id)sender
{
    EmbraceLogMethod();
    [self _increaseOrDecreaseVolumeByAmount:0.04];
}


- (IBAction) decreaseVolume:(id)sender
{
    EmbraceLogMethod();
    [self _increaseOrDecreaseVolumeByAmount:-0.04];
}


- (IBAction) increaseAutoGap:(id)sender
{
    EmbraceLogMethod();
    NSInteger value = [self minimumSilenceBetweenTracks] + 1;
    if (value > sAutoGapMaximum) value = sAutoGapMaximum;
    [self setMinimumSilenceBetweenTracks:value];
}


- (IBAction) decreaseAutoGap:(id)sender
{
    EmbraceLogMethod();
    NSInteger value = [self minimumSilenceBetweenTracks] - 1;
    if (value < sAutoGapMinimum) value = sAutoGapMinimum;
    [self setMinimumSilenceBetweenTracks:value];
}


- (IBAction) changeVolume:(id)sender
{
    EmbraceLogMethod();
    [sender setNeedsDisplay];
}


- (IBAction) copy:(id)sender
{
    EmbraceLogMethod();
    [[self tracksController] copy:sender];
}


- (IBAction) paste:(id)sender
{
    EmbraceLogMethod();
    [[self tracksController] paste:sender];
}


- (IBAction) delete:(id)sender
{
    EmbraceLogMethod();
    [[self tracksController] delete:sender];
}


- (void) changeLabel:(id)sender
{
    NSInteger selectedTag = [sender selectedTag];
    
    if (selectedTag >= TrackLabelNone && selectedTag <= TrackLabelPurple) {
        for (Track *track in [[self tracksController] selectedTracks]) {
            [track setTrackLabel:selectedTag];
        }
    }
}


- (void) revealTime:(id)sender
{
    EmbraceLogMethod();

    NSArray *tracks = [[self tracksController] selectedTracks];
    if ([tracks count] == 0) return;

    [self _calculateStartAndEndTimes];

    [[self tracksController] revealTime:self];
}


- (IBAction) toggleStopsAfterPlaying:(id)sender
{
    EmbraceLogMethod();
    [[self tracksController] toggleStopsAfterPlaying:self];
    [self _updatePlayButton];
}


- (IBAction) toggleIgnoreAutoGap:(id)sender
{
    EmbraceLogMethod();
    [[self tracksController] toggleIgnoreAutoGap:self];
    [self _updatePlayButton];
}


- (IBAction) toggleMarkAsPlayed:(id)sender
{
    EmbraceLogMethod();
    [[self tracksController] toggleMarkAsPlayed:self];
    [self _updatePlayButton];
}


- (IBAction) showGearMenu:(id)sender
{
    EmbraceLogMethod();

    NSButton *gearButton = [self gearButton];

    NSRect bounds = [gearButton bounds];
    NSPoint point = NSMakePoint(1, CGRectGetMaxY(bounds) + 6);
    [[gearButton menu] popUpMenuPositioningItem:nil atLocation:point inView:gearButton];
}


- (IBAction) showEffects:(id)sender
{
    [GetAppDelegate() showEffectsWindow];
}


- (IBAction) showCurrentTrack:(id)sender
{
    [GetAppDelegate() showCurrentTrack];
}


#pragma mark - Delegates

- (BOOL) validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = [menuItem action];

    if (action == @selector(copy:)   ||
        action == @selector(paste:)  ||
        action == @selector(delete:) ||
        action == @selector(toggleMarkAsPlayed:) ||
        action == @selector(toggleStopsAfterPlaying:) ||
        action == @selector(toggleIgnoreAutoGap:) ||
        action == @selector(revealTime:))
    {
        return [[self tracksController] validateMenuItem:menuItem];
    }
    
    return YES;
}


- (void) menuWillOpen:(NSMenu *)menu
{
    BOOL showLabels = [[Preferences sharedInstance] showsLabelDots] ||
                      [[Preferences sharedInstance] showsLabelStripes];

    NSMutableSet *selectedLabels = [NSMutableSet set];
    TrackLabel    trackLabel     = TrackLabelNone;
    
    for (Track *track in [[self tracksController] selectedTracks]) {
        [selectedLabels addObject:@([track trackLabel])];
    }

    NSInteger selectedLabelsCount = [selectedLabels count];
    if (selectedLabelsCount > 1) {
        trackLabel = TrackLabelMultiple;
    } else if (selectedLabelsCount == 1) {
        trackLabel = [[selectedLabels anyObject] integerValue];
    } else if (selectedLabelsCount == 0) {
        trackLabel = TrackLabelNone;
        showLabels = NO;
    }
    
    if ([menu isEqual:[self gearMenu]]) {
        [[self gearMenuLabelSeparator] setHidden:!showLabels];
        [[self gearMenuLabelItem] setHidden:!showLabels];
        [[self gearMenuLabelItem] setView:showLabels ? [self gearMenuLabelView] : nil];

        [[self gearMenuLabelView] setSelectedTag:trackLabel];
    
    } else if ([menu isEqual:[self tableMenu]]) {
        [[self tableMenuLabelSeparator] setHidden:!showLabels];
        [[self tableMenuLabelItem] setHidden:!showLabels];
        [[self tableMenuLabelItem] setView:showLabels ? [self tableMenuLabelView] : nil];
       
        [[self tableMenuLabelView] setSelectedTag:trackLabel];
    }
}


- (void) sliderDidStartDrag:(SetlistSlider *)slider
{
    if (slider == _volumeSlider) {
        _volumeBeforeDrag = [slider doubleValue];

        [self _updatePlayButton];
        [_volumeTooLowFloater hide];
    }
}


- (void) sliderDidEndDrag:(SetlistSlider *)slider
{
    if (slider == _volumeSlider) {
        CGFloat volumeBeforeDrag = _volumeBeforeDrag;

        if (volumeBeforeDrag) {
            _volumeBeforeDrag = 0;
            [self _updatePlayButton];
            [self _doFadeStopIfNeededWithBeforeVolume:volumeBeforeDrag];
        }
    }
}


- (BOOL) window:(EmbraceWindow *)window cancelOperation:(id)sender
{
    NSArray *selectedTracks = [[self tracksController] selectedTracks];
    
    if ([selectedTracks count] > 0) {
        [[self tracksController] deselectAllTracks];
        return YES;
    }

    return NO;
}


#pragma mark - Player

- (void) _setupPlayer
{
    Player *player = [Player sharedInstance];

    [player addListener:self];
    [player setTrackProvider:self];

    [self player:player didUpdatePlaying:NO];
}


- (void) player:(Player *)player didUpdatePlaying:(BOOL)playing
{
    EmbraceLog(@"SetlistController", @"player:didUpdatePlaying:%ld", (long)playing);

    if (playing) {
        [[self dangerView] setMetering:YES];
        [[self meterView] setMetering:YES];
        [[self playBar] setPlaying:YES];
        
        [[self playOffsetField]    setHidden:NO];
        [[self playRemainingField] setHidden:NO];
        
    } else {
        [[self playOffsetField] setStringValue:GetStringForTime(0)];
        [[self playRemainingField] setStringValue:GetStringForTime(0)];

        [[self playOffsetField]    setHidden:YES];
        [[self playRemainingField] setHidden:YES];

        [[self playBar] setPercentage:0];
        [[self playBar] setPlaying:NO];

        [[self dangerView] setMetering:NO];
        [[self meterView] setMetering:NO];
    }

    [self _updatePlayButton];
    [self _calculateStartAndEndTimes];
}


- (void) player:(Player *)player didUpdateIssue:(PlayerIssue)issue
{
    [self _updatePlayButton];
}


- (void) player:(Player *)player didUpdateVolume:(double)volume
{
    [self _updatePlayButton];
}


- (void) player:(Player *)player didInterruptPlaybackWithReason:(PlayerInterruptionReason)reason
{
    NSString *messageText = NSLocalizedString(@"Another application interrupted playback.", nil);

    HugAudioDevice *device = [[Preferences sharedInstance] mainOutputAudioDevice];
    NSString *deviceName = [device name];

    if (reason == PlayerInterruptionReasonHoggedByOtherProcess) {
        pid_t hogModeOwner = [device hogModeOwner];
        NSRunningApplication *owner = hogModeOwner > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:hogModeOwner] : 0;
        
        if (owner) {
            NSString *format = NSLocalizedString(@"%@ interrupted playback by taking exclusive access to \\U201c%@\\U201d.", nil);
            NSString *applicationName = [owner localizedName];
            messageText = [NSString stringWithFormat:format, applicationName, deviceName];

        } else {
            NSString *format = NSLocalizedString(@"Another application interrupted playback by taking exclusive access to \\U201c%@\\U201d.", nil);
            messageText = [NSString stringWithFormat:format, deviceName];
        }

    } else if (reason == PlayerInterruptionReasonSampleRateChanged ||
               reason == PlayerInterruptionReasonFramesChanged     ||
               reason == PlayerInterruptionReasonChannelLayoutChanged)
    {
        NSString *format = NSLocalizedString(@"Another application interrupted playback by changing the configuration of \\U201c%@\\U201d.", nil);
        messageText = [NSString stringWithFormat:format, deviceName];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    
    [alert setMessageText:messageText];
    [alert setAlertStyle:NSAlertStyleCritical];
    [alert setInformativeText:NSLocalizedString(@"You can prevent this by quitting other applications when using Embrace, or by giving Embrace exclusive access in Preferences.", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Show Preferences", nil)];

    if ([alert runModal] == NSAlertSecondButtonReturn) {
        [GetAppDelegate() showPreferences];
    }
}


- (void) playerDidTick:(Player *)player
{
    NSTimeInterval timeElapsed   = [player timeElapsed];
    NSTimeInterval timeRemaining = [player timeRemaining];

    Float32        dangerPeak       = [player dangerPeak];
    NSTimeInterval lastOverloadTime = [player lastOverloadTime];
    
    NSTimeInterval duration = timeElapsed + timeRemaining;
    if (!duration) duration = 1;
    
    double percentage = 0;
    if (timeElapsed > 0) {
        percentage = timeElapsed / duration;
    }

    if (![player isPlaying]) {
        percentage = 0;
    }

    [[self playBar] setPercentage:percentage];

    [[self dangerView] addDangerPeak:dangerPeak lastOverloadTime:lastOverloadTime];

    [[self meterView] setLeftMeterData:[player leftMeterData]
                        rightMeterData:[player rightMeterData]];
    
    [self _updatePlayButton];
}


- (void) player:(Player *)player getNextTrack:(Track **)outNextTrack getPadding:(NSTimeInterval *)outPadding
{
    Track *currentTrack = [player currentTrack];

    [[self tracksController] saveState];

    Track *trackToPlay = [[self tracksController] firstQueuedTrack];
    NSTimeInterval padding = 0;
    
    NSInteger minimumSilence = [self minimumSilenceBetweenTracks];
   
    if ((minimumSilence == sAutoGapMaximum) && currentTrack) {
        padding = HUGE_VAL;

    } else if (currentTrack && trackToPlay) {
        NSTimeInterval totalSilence = [currentTrack silenceAtEnd] + [trackToPlay silenceAtStart];
        padding = minimumSilence - totalSilence;
        if (padding < 0) padding = 0;
        
        if (minimumSilence > 0 && padding == 0) {
            padding = 1.0;
        }
        
        if ([currentTrack error]) {
            padding = 0;
        }
    }

    EmbraceLog(@"SetlistController", @"-player:getNextTrack:getPadding:, currentTrack=%@, nextTrack=%@, padding=%g", currentTrack, trackToPlay, padding);
    
    *outNextTrack = trackToPlay;
    *outPadding   = padding;
}


- (void) player:(Player *)player didFinishTrack:(Track *)finishedTrack
{
    [[self tracksController] didFinishTrack:finishedTrack];
}


- (void) setMinimumSilenceBetweenTracks:(NSInteger)minimumSilenceBetweenTracks
{
    if (minimumSilenceBetweenTracks > sAutoGapMaximum) minimumSilenceBetweenTracks = sAutoGapMaximum;
    if (minimumSilenceBetweenTracks < sAutoGapMinimum) minimumSilenceBetweenTracks = sAutoGapMinimum;

    if (_minimumSilenceBetweenTracks != minimumSilenceBetweenTracks) {
        [self willChangeValueForKey:@"autoGapTimeString"];

        _minimumSilenceBetweenTracks = minimumSilenceBetweenTracks;

        [[NSUserDefaults standardUserDefaults] setInteger:minimumSilenceBetweenTracks forKey:sMinimumSilenceKey];
        [self _calculateStartAndEndTimes];

        [self didChangeValueForKey:@"autoGapTimeString"];
    }
}


- (NSString *) autoGapTimeString
{
    if (_minimumSilenceBetweenTracks == sAutoGapMinimum) {
        return NSLocalizedString(@"Off", nil);
    } else if (_minimumSilenceBetweenTracks == sAutoGapMaximum) {
        return NSLocalizedString(@"Stop", nil);
    } else {
        return GetStringForTime(_minimumSilenceBetweenTracks);
    }
}


@end
