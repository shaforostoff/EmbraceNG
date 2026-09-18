// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "TrackTableCellView.h"

#import "Track.h"
#import "TrackErrorButton.h"
#import "AppDelegate.h"
#import "NoDropImageView.h"
#import "Preferences.h"
#import "TrackLabelView.h"
#import "TrackTableView.h"
#import "TrackStripeView.h"
#import "MaskView.h"


@interface TrackTableCellView () <ApplicationEventListener>

@property (nonatomic, weak) IBOutlet NSLayoutConstraint *titleDurationConstraint;

@property (nonatomic, weak) IBOutlet TrackStripeView *stripeView;

@property (nonatomic, weak) IBOutlet NSTextField *titleField;
@property (nonatomic, weak) IBOutlet NSTextField *durationField;

@property (nonatomic, weak) IBOutlet NSTextField *lineTwoLeftField;
@property (nonatomic, weak) IBOutlet NSTextField *lineTwoRightField;

@property (nonatomic, weak) IBOutlet NSTextField *lineThreeLeftField;
@property (nonatomic, weak) IBOutlet NSTextField *lineThreeRightField;

@property (nonatomic, weak) IBOutlet NoDropImageView *speakerImageView;
@property (nonatomic, weak) IBOutlet TrackErrorButton *errorButton;

@property (nonatomic, weak) IBOutlet NSLayoutConstraint *speakerLeftConstraint;

@property (nonatomic, weak) IBOutlet NSLayoutConstraint *firstLineTopConstraint;
@property (nonatomic, weak) IBOutlet NSLayoutConstraint *secondLineTopConstraint;
@property (nonatomic, weak) IBOutlet NSLayoutConstraint *thirdLineTopConstraint;

@property (nonatomic, strong)          TrackLabelView *dotLabelView;
@property (nonatomic, weak)   IBOutlet TrackLabelView *edgeLabelView;

@end


#pragma mark - Shared Formatters

// Both of these used to be built from scratch every time a cell refilled
// itself, and a cell refills on every scroll, every selection change and every
// modification to the set list.  Building one is not cheap -- it loads locale
// data through ICU -- and measured here a fresh NSDateFormatter costs 85us
// against 3.6us for reusing one, and a fresh NSNumberFormatter 49us against
// 1.5us.  A cell wants one date and up to two numbers, so forty visible rows
// went from 7.4ms of formatter construction to 0.26ms.  The frame budget is
// 16.7ms.
//
// Cached rather than recreated, and thrown away when the things they were
// built from move: a formatter captures the locale and the time zone at
// creation and will happily keep printing yesterday's answer otherwise.
// Main thread only, which every caller below is.

static NSDateFormatter   *sTimeFormatter   = nil;
static NSNumberFormatter *sDecimalFormatter = nil;

static void sInvalidateSharedFormatters(void)
{
    sTimeFormatter    = nil;
    sDecimalFormatter = nil;
}

static void sObserveFormatterInvalidation(void)
{
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

        for (NSNotificationName name in @[ NSCurrentLocaleDidChangeNotification,
                                           NSSystemTimeZoneDidChangeNotification ])
        {
            [center addObserverForName: name
                                object: nil
                                 queue: [NSOperationQueue mainQueue]
                            usingBlock: ^(NSNotification *note) { sInvalidateSharedFormatters(); }];
        }
    });
}

static NSDateFormatter *sGetTimeFormatter(void)
{
    sObserveFormatterInvalidation();

    if (!sTimeFormatter) {
        sTimeFormatter = [[NSDateFormatter alloc] init];
        [sTimeFormatter setDateStyle:NSDateFormatterNoStyle];
        [sTimeFormatter setTimeStyle:NSDateFormatterMediumStyle];
    }

    return sTimeFormatter;
}

#pragma mark - Observed Keys

// Everything about a track that changes what a row looks like.  The list is
// fixed, and -setObjectValue: runs on every scroll and every selection change,
// so it is built once rather than rebuilt per cell per reuse.
//
// It had @"pausesAfterPlaying" in it, which is not a key Track has -- the
// property is stopsAfterPlaying.  KVO does not complain about a key path that
// does not exist, it simply never notifies, so the row's stripe was not
// repainting when that flag changed.
//
// Turning the flag *on* hid it: -setStopsAfterPlaying: calls
// -setIgnoresAutoGap:NO on the way, and that key is observed correctly, so the
// row redrew for the wrong reason.  Turning it off calls nothing, which is why
// the symptom was a stop-after-playing stripe that stayed on screen after the
// setting had been switched off.
//
// @"artist" was also in the list twice, so every artist change ran -_updateView
// twice.
//
static NSArray<NSString *> *sObservedKeyPaths(void)
{
    static NSArray<NSString *> *sKeyPaths = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sKeyPaths = @[
            @"title",
            @"artist",
            @"playDuration",
            @"error",
            @"estimatedEndTime",
            @"stopsAfterPlaying",
            @"ignoresAutoGap",
            @"tonality",
            @"comments",
            @"grouping",
            @"beatsPerMinute",
            @"detectedBeatsPerMinute",
            @"trackStatus",
            @"trackLabel",
            @"duplicate"
        ];
    });

    return sKeyPaths;
}


static NSString *sLocalizedDecimalString(NSInteger value)
{
    sObserveFormatterInvalidation();

    if (!sDecimalFormatter) {
        sDecimalFormatter = [[NSNumberFormatter alloc] init];
        [sDecimalFormatter setNumberStyle:NSNumberFormatterDecimalStyle];
    }

    return [sDecimalFormatter stringFromNumber:@(value)];
}


@interface TrackTableView (Private)
- (void) _trackTableViewCell:(TrackTableCellView *)cellView mouseInside:(BOOL)mouseInside;
@end


@implementation TrackTableCellView {
    NSArray        *_observedKeyPaths;
    id              _observedObject;

    NSTextField    *_timeField;
    MaskView       *_timeMaskView;
    BOOL            _showsTime;
    
    NSArray        *_errorButtonConstraints;
    NSArray        *_endTimeConstraints;

    NoDropImageView    *_duplicateImageView;
    NSArray            *_duplicateConstraints;
    NSLayoutConstraint *_duplicateRightConstraint;
    
    NSArray            *_dotConstraints;
    NSLayoutConstraint *_dotRightConstraint;

    NSTrackingArea *_trackingArea;
    BOOL            _mouseInside;
    BOOL            _timeRequested;
    BOOL            _animatesTime;
    BOOL            _animatesSpeakerImage;

    // Where a measured BPM sits inside the line-two-right string, and the two
    // colors that string is currently drawn in.  -_updateFieldStrings knows the
    // first, -updateColors knows the other two, and either can be called on its
    // own -- a selection change recolors without rebuilding the strings, and a
    // new BPM rebuilds the strings without changing the colors -- so each keeps
    // what it knows where the other can find it.
    NSRange         _detectedBPMRange;
    NSColor        *_secondaryTextColor;
    NSColor        *_detectedBPMColor;
    BOOL            _detectedBPMMarked;
}


- (id) initWithFrame:(NSRect)frameRect
{
    if ((self = [super initWithFrame:frameRect])) {
        [self _commonTrackTableCellViewInit];
    }
    
    return self;
}


- (id) initWithCoder:(NSCoder *)aDecoder
{
    if ((self = [super initWithCoder:aDecoder])) {
        [self _commonTrackTableCellViewInit];
    }
    
    return self;
}


- (void) application:(Application *)application flagsChanged:(NSEvent *)event
{
    [self _updateTimeVisibilityAnimated:NO];
}


- (void) dealloc
{
    [self _removeObservers];

    [_errorButton setTarget:nil];
    [_errorButton setAction:NULL];
}


- (void) viewDidMoveToSuperview
{
    [super viewDidMoveToSuperview];
    _mouseInside = NO;
}


- (void) viewDidChangeEffectiveAppearance
{
    PerformWithAppearance([self effectiveAppearance], ^{
        [self _updateView];
    });
}


- (TrackTableView *) _tableView
{
    NSView *view = [self superview];
    
    while (view) {
        if ([view isKindOfClass:[TrackTableView class]]) {
            return (TrackTableView *)view;
        }

        view = [view superview];
    }
    
    return nil;
}


- (void) _commonTrackTableCellViewInit
{
    [(Application *)NSApp registerEventListener:self];

   
    NSTrackingAreaOptions options = NSTrackingInVisibleRect | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways;
    _trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil];
    [self addTrackingArea:_trackingArea];
}


- (void) awakeFromNib
{
    [_errorButton setAutoresizingMask:NSViewMinXMargin];
    [_errorButton setTarget:self];
    [_errorButton setAction:@selector(_errorButtonClicked:)];

    _timeField = [[NSTextField alloc] initWithFrame:NSZeroRect];

    [_timeField setBezeled:NO];
    [_timeField setSelectable:NO];
    [_timeField setEditable:NO];
    [_timeField setDrawsBackground:NO];
    [_timeField setAlignment:NSTextAlignmentRight];
    [_timeField setAlphaValue:0];
    [_timeField setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_timeField setContentCompressionResistancePriority:(NSLayoutPriorityDefaultHigh + 1) forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_timeField setTranslatesAutoresizingMaskIntoConstraints:NO];

    _timeMaskView = [[MaskView alloc] initWithFrame:NSZeroRect];
    [_timeMaskView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [_timeMaskView setGradientLength:32];
    [_timeMaskView setGradientLayoutAttribute:NSLayoutAttributeLeft];

#if 0
    [_titleField setBackgroundColor:[NSColor yellowColor]];
    [_titleField setDrawsBackground:YES];
    [_lineThreeLeftField setBackgroundColor:[NSColor yellowColor]];
    [_lineThreeLeftField setDrawsBackground:YES];
    [_lineTwoLeftField setBackgroundColor:[NSColor yellowColor]];
    [_lineTwoLeftField setDrawsBackground:YES];
    [_lineThreeRightField setBackgroundColor:[NSColor yellowColor]];
    [_lineThreeRightField setDrawsBackground:YES];
    [_lineTwoRightField setBackgroundColor:[NSColor yellowColor]];
    [_lineTwoRightField setDrawsBackground:YES];
#endif

    _errorButtonConstraints = @[
        [NSLayoutConstraint constraintWithItem:_titleField         attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:_errorButton attribute:NSLayoutAttributeLeft multiplier:1.0 constant:-8.0],
        [NSLayoutConstraint constraintWithItem:_lineTwoLeftField   attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:_errorButton attribute:NSLayoutAttributeLeft multiplier:1.0 constant:-8.0],
        [NSLayoutConstraint constraintWithItem:_lineThreeLeftField attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:_errorButton attribute:NSLayoutAttributeLeft multiplier:1.0 constant:-8.0]
    ];
    
    [NSLayoutConstraint activateConstraints:_errorButtonConstraints];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        [context setDuration:0];
        [self _updateView];
    } completionHandler:^{
        _animatesSpeakerImage = YES;
    }];
}


- (void) _adjustConstraintsForLineLayout
{
    if (_endTimeConstraints) {
        [NSLayoutConstraint deactivateConstraints:_endTimeConstraints];
        _endTimeConstraints = nil;
    }
    
    NSInteger numberOfLines = [[Preferences sharedInstance] numberOfLayoutLines];

    NSTextField *targetField = nil;

    if (numberOfLines == 1) {
        targetField = [self durationField];
    } else if (numberOfLines == 2) {
        targetField = [self lineTwoRightField];
    } else if (numberOfLines == 3) {
        targetField = [self lineThreeRightField];
    }

    NSTextField *oldTargetField = [[_endTimeConstraints lastObject] secondItem];

    if (targetField && (targetField != oldTargetField)) {
        CGFloat length = [_timeMaskView gradientLength] + 8;
        
        _endTimeConstraints = @[
            [NSLayoutConstraint constraintWithItem:_timeField attribute:NSLayoutAttributeRight    relatedBy:NSLayoutRelationEqual              toItem:targetField attribute:NSLayoutAttributeRight    multiplier:1.0 constant:0.0],
            [NSLayoutConstraint constraintWithItem:_timeField attribute:NSLayoutAttributeBaseline relatedBy:NSLayoutRelationEqual              toItem:targetField attribute:NSLayoutAttributeBaseline multiplier:1.0 constant:0.0],
            [NSLayoutConstraint constraintWithItem:_timeField attribute:NSLayoutAttributeWidth    relatedBy:NSLayoutRelationGreaterThanOrEqual toItem:targetField attribute:NSLayoutAttributeWidth    multiplier:1.0 constant:0.0],

            [NSLayoutConstraint constraintWithItem:_timeMaskView attribute:NSLayoutAttributeTop      relatedBy:NSLayoutRelationEqual toItem:_timeField attribute:NSLayoutAttributeTop       multiplier:1.0 constant:0.0],
            [NSLayoutConstraint constraintWithItem:_timeMaskView attribute:NSLayoutAttributeBottom   relatedBy:NSLayoutRelationEqual toItem:_timeField attribute:NSLayoutAttributeBottom    multiplier:1.0 constant:0.0],
            [NSLayoutConstraint constraintWithItem:_timeMaskView attribute:NSLayoutAttributeRight    relatedBy:NSLayoutRelationEqual toItem:_timeField attribute:NSLayoutAttributeRight     multiplier:1.0 constant:0.0],
            [NSLayoutConstraint constraintWithItem:_timeMaskView attribute:NSLayoutAttributeLeft     relatedBy:NSLayoutRelationEqual toItem:_timeField attribute:NSLayoutAttributeLeft      multiplier:1.0 constant:-length]
        ];
        
        [[targetField superview] addSubview:_timeField    positioned:NSWindowAbove relativeTo:targetField];
        [[targetField superview] addSubview:_timeMaskView positioned:NSWindowAbove relativeTo:targetField];

        [NSLayoutConstraint activateConstraints:_endTimeConstraints];
    }
}


- (void) mouseEntered:(NSEvent *)theEvent
{
    [super mouseEntered:theEvent];
    _mouseInside = YES;

    [self _updateTimeVisibilityAnimated:NO];
    
    [[self _tableView] _trackTableViewCell:self mouseInside:YES];
}


- (void) mouseExited:(NSEvent *)theEvent
{
    [super mouseExited:theEvent];
    _mouseInside = NO;

    [self _updateTimeVisibilityAnimated:NO];

    [[self _tableView] _trackTableViewCell:self mouseInside:NO];
}


- (void) mouseDown:(NSEvent *)theEvent
{
    NSUInteger mask = (NSEventModifierFlagControl | NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption);
    
    if (([theEvent modifierFlags] & mask) == NSEventModifierFlagControl) {
        if ([self _tryToPresentContextMenuWithEvent:theEvent]) {
            return;
        }
    }

    [super mouseDown:theEvent];
}


- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (object == _observedObject) {
    
        if ([keyPath isEqualToString:@"trackStatus"]) {
            [self updateColors];
            
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ac) {
                [ac setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionDefault]];
                [ac setDuration:0.25];
                [self _updateSpeakerIconAnimated:YES];
            } completionHandler:nil];

        } else if ([keyPath isEqualToString:@"estimatedEndTime"]) {
            [self _updateFieldStrings];

        } else if ([_observedKeyPaths containsObject:keyPath]) {
            [self _updateView];
        }
    }
}


- (void) setObjectValue:(id)objectValue
{
    [self _removeObservers];

    [super setObjectValue:objectValue];

    // The range belongs to whichever track the cell was last filled for, and
    // this is a different one.
    _detectedBPMRange = NSMakeRange(NSNotFound, 0);
    
    _observedKeyPaths = sObservedKeyPaths();

    _observedObject = objectValue;

    for (NSString *keyPath in _observedKeyPaths) {
        [_observedObject addObserver:self forKeyPath:keyPath options:0 context:NULL];
    }

    [self _updateView];
}


#pragma mark - Private Methods

- (void) _removeObservers
{
    for (NSString *keyPath in _observedKeyPaths) {
        [_observedObject removeObserver:self forKeyPath:keyPath context:NULL];
    }

    _observedKeyPaths = nil;
    _observedObject   = nil;
}


- (BOOL) _tryToPresentContextMenuWithEvent:(NSEvent *)event
{
    NSView *superview = [self superview];
    NSMenu *menu = nil;

    while (superview) {
        if ([superview isKindOfClass:[NSTableView class]]) {
            menu = [superview menuForEvent:event];
            if (menu) break;
        }
        
        superview = [superview superview];
    }
    
    if (menu) {
        [NSMenu popUpContextMenu:menu withEvent:event forView:self];
        return YES;
    }
    
    return NO;
}


- (void) _errorButtonClicked:(id)sender
{
    [GetAppDelegate() displayErrorForTrack:[self track]];
}


- (void) _unrequestTime
{
    _timeRequested = NO;
    [self _updateTimeVisibilityAnimated:YES];
}


- (void) _updateTimeVisibilityAnimated:(BOOL)animated
{
    NSUInteger modifierFlags = [NSEvent modifierFlags];
    
    modifierFlags &= (
        NSEventModifierFlagOption  |
        NSEventModifierFlagCommand |
        NSEventModifierFlagControl |
        NSEventModifierFlagShift
    );
    
    BOOL isCommandKeyDown = (modifierFlags == NSEventModifierFlagOption);
    
    BOOL showsTime = ((isCommandKeyDown && _mouseInside) || _timeRequested);

    if (_showsTime != showsTime) {
        _showsTime = showsTime;
        _animatesTime = animated;
        [self _updateView];
    }
}


#pragma mark - Update

- (void) _updateView
{
    Track *track = [self track];

    [[NSAnimationContext currentContext] setDuration:0];
    
    [self _updateLabelEdgeAndStripe];
    [self updateColors];

    if ([self track]) {
        [self _updateRightIcons];
        [self _updateFieldStrings];
        [self _updateFieldHidden];
        [self _updateFieldAlphas];
    }

    [self _updateSpeakerIconAnimated:NO];
    
    [self _adjustConstraintsForLineLayout];
    
    [self _updateFieldFonts];

    // Update constraints
    if ([track error]) {
        [NSLayoutConstraint activateConstraints:_errorButtonConstraints];
    } else {
        [NSLayoutConstraint deactivateConstraints:_errorButtonConstraints];
    }
}


- (void) _updateSpeakerIconAnimated:(BOOL)animated
{
    TrackStatus trackStatus = [[self track] trackStatus];
    BOOL        isPlaying   = (trackStatus == TrackStatusPlaying);
    
    if (![[Preferences sharedInstance] showsPlayingStatus]) {
        isPlaying = NO;
    }
    
    CGFloat constant = isPlaying ? 8.0 : -13.0;
    CGFloat alpha    = isPlaying ? 1.0 :  0.0;

    if (animated) {
        [[_speakerLeftConstraint animator] setConstant:constant];
        [[_speakerImageView animator] setAlphaValue:alpha];
    } else {
        [_speakerLeftConstraint setConstant:constant];
        [_speakerImageView setAlphaValue:alpha];
    }
}


- (void) _updateRightIcons
{
    TrackLabel trackLabel = [[self track] trackLabel];

    BOOL showsDuplicateIcon = [[Preferences sharedInstance] showsDuplicateStatus] && [[self track] isDuplicate];
    BOOL showsDot           = [[Preferences sharedInstance] showsLabelDots] && (trackLabel != TrackLabelNone);

    if (showsDuplicateIcon && !_duplicateImageView) {
        NSImage *image = [NSImage imageNamed:@"DuplicateTemplate"];
        [image setTemplate:YES];
        
        _duplicateImageView = [[NoDropImageView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
        [_duplicateImageView setTranslatesAutoresizingMaskIntoConstraints:NO];
        [_duplicateImageView setImage:image];
        [[_durationField superview] addSubview:_duplicateImageView positioned:NSWindowBelow relativeTo:nil];

        _duplicateRightConstraint = [NSLayoutConstraint constraintWithItem:_duplicateImageView attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:_durationField attribute:NSLayoutAttributeLeft multiplier:1.0 constant:-4.0];
        
        _duplicateConstraints = @[
            _duplicateRightConstraint,
            [NSLayoutConstraint constraintWithItem:_duplicateImageView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:_durationField attribute:NSLayoutAttributeTop     multiplier:1.0 constant:4.0]
        ];

        [NSLayoutConstraint activateConstraints:_duplicateConstraints];

    } else if (!showsDuplicateIcon && _duplicateImageView) {
        [_duplicateImageView removeFromSuperview];
        _duplicateImageView = nil;
        
        [NSLayoutConstraint deactivateConstraints:_duplicateConstraints];
        _duplicateConstraints = nil;
        _duplicateRightConstraint = nil;
    }


    if (showsDot && !_dotLabelView) {
        _dotLabelView = [[TrackLabelView alloc] initWithFrame:CGRectMake(0, 0, 20, 20)];
        [_dotLabelView setStyle:TrackLabelViewDot];
        [_dotLabelView setTranslatesAutoresizingMaskIntoConstraints:NO];

        [[_durationField superview] addSubview:_dotLabelView positioned:NSWindowBelow relativeTo:nil];

        _dotRightConstraint = [NSLayoutConstraint constraintWithItem:_dotLabelView attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:_durationField attribute:NSLayoutAttributeLeft multiplier:1.0 constant:-4.0];

        _dotConstraints = @[
            _dotRightConstraint,
            [NSLayoutConstraint constraintWithItem:_dotLabelView attribute:NSLayoutAttributeTop      relatedBy:NSLayoutRelationEqual toItem:_durationField attribute:NSLayoutAttributeTop     multiplier:1.0 constant:4.0],
            [NSLayoutConstraint constraintWithItem:_dotLabelView attribute:NSLayoutAttributeWidth    relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute     multiplier:1.0 constant:10.0],
            [NSLayoutConstraint constraintWithItem:_dotLabelView attribute:NSLayoutAttributeHeight   relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute     multiplier:1.0 constant:10.0]
        ];

        [NSLayoutConstraint activateConstraints:_dotConstraints];

        
    } else if (!showsDot && _dotLabelView) {
        [_dotLabelView removeFromSuperview];
        _dotLabelView = nil;
        
        [NSLayoutConstraint deactivateConstraints:_dotConstraints];
        _dotConstraints = nil;
        _dotRightConstraint = nil;
    }


    NSInteger constant = 8;
    
    if (showsDuplicateIcon && showsDot) {
        constant = 28 + 4;
        [_duplicateRightConstraint setConstant:-18];
        [_dotRightConstraint setConstant:-4];

    } else if (showsDuplicateIcon) {
        constant = 18;
        [_duplicateRightConstraint setConstant:-4];

    } else if (showsDot) {
        constant = 8;
        [_dotRightConstraint setConstant:-4];
    }

    if (showsDot) {
        [_dotLabelView setLabel:trackLabel];
    }

    [_titleDurationConstraint setConstant:constant];
}

- (NSTableRowView *) _rowView
{
    NSView *superview = [self superview];
    
    if ([superview isKindOfClass:[NSTableRowView class]]) {
        return (NSTableRowView *)superview;
    } else {
        return nil;
    }
}



- (void) updateColors
{
    NSTableRowView *rowView = [self _rowView];

    BOOL rowIsSelected   = [rowView isSelected];
    BOOL rowIsEmphasized = [rowView isEmphasized];

    NSColor *primaryColor   = nil;
    NSColor *secondaryColor = nil;

    // nil where a measured BPM is to be left the same color as everything
    // around it.  The mark is a hue against a row drawn in plain black or
    // white; a row that is already drawn in a color of its own has no plain
    // to stand out from, and would only end up with two colors fighting.
    NSColor *detectedBPMColor = nil;

    TrackStatus trackStatus = [[self track] trackStatus];

    if (trackStatus == TrackStatusPlayed) {
        primaryColor     = [NSColor colorNamed:@"SetlistPrimaryPlayed"];
        secondaryColor   = [NSColor colorNamed:@"SetlistSecondaryPlayed"];
        detectedBPMColor = [NSColor colorNamed:@"SetlistDetectedBPMPlayed"];
    
    } else {
        primaryColor     = [NSColor colorNamed:@"SetlistPrimary"];
        secondaryColor   = [NSColor colorNamed:@"SetlistSecondary"];
        detectedBPMColor = [NSColor colorNamed:@"SetlistDetectedBPM"];
    }
    
    if (rowIsSelected && rowIsEmphasized) {
        primaryColor     = [NSColor colorNamed:@"SetlistPrimaryEmphasized"];
        secondaryColor   = [NSColor colorNamed:@"SetlistSecondaryEmphasized"];
        detectedBPMColor = nil;

    } else if ((trackStatus == TrackStatusPreparing) || (trackStatus == TrackStatusPlaying)) {
        primaryColor     = TrackTableViewGetPlayingTextColor();
        secondaryColor   = primaryColor;
        detectedBPMColor = nil;
    }
   
    [[self titleField]    setTextColor:primaryColor];
    [[self durationField] setTextColor:primaryColor];

    [[self lineTwoLeftField]    setTextColor:secondaryColor];
    [[self lineTwoRightField]   setTextColor:secondaryColor];
    [[self lineThreeLeftField]  setTextColor:secondaryColor];
    [[self lineThreeRightField] setTextColor:secondaryColor];
    [_timeField                 setTextColor:secondaryColor];

    _secondaryTextColor = secondaryColor;
    _detectedBPMColor   = detectedBPMColor;
    [self _updateDetectedBPMMark];

    [_duplicateImageView setTintColor:primaryColor];
    [_speakerImageView   setTintColor:primaryColor];
    
    if (rowIsSelected && rowIsEmphasized) {
        [_errorButton setNormalColor:primaryColor];
        [_errorButton setPressedColor:primaryColor];

        [_dotLabelView setNeedsWhiteBorder:YES];

    } else {
        [_errorButton setNormalColor: [NSColor colorNamed:@"ButtonAlert"]];
        [_errorButton setPressedColor:[NSColor colorNamed:@"ButtonAlertPressed"]];

        [_dotLabelView setNeedsWhiteBorder:NO];
    }
  
    
    NSVisualEffectMaterial material = 0;
    NSColor *color = nil;

    if (rowIsSelected) {
        color = TrackTableViewGetRowHighlightColor(rowIsEmphasized);
    } else {
        if (@available(macOS 10.14, *)) {
            material = NSVisualEffectMaterialContentBackground;
        } else {
            color = [NSColor controlBackgroundColor];
        }
    }

    [_timeMaskView setColor:color];
    [_timeMaskView setMaterial:material];
    [_timeMaskView setEmphasized:rowIsEmphasized];
}


- (void) _updateLabelEdgeAndStripe
{
    Track *track = [self track];
    if (!track) return;

    TrackStripeView *stripeView = [self stripeView];

    NSColor *stripeSolidColor = nil;
    NSColor *stripeDashColor  = nil;

    if ([track trackStatus] != TrackStatusPlayed) {
        if ([track stopsAfterPlaying]) {
            stripeSolidColor = [NSColor colorNamed:@"SetlistStopAfterPlayingStripe2"];
            stripeDashColor  = [NSColor colorNamed:@"SetlistStopAfterPlayingStripe1"];

        } else if ([track ignoresAutoGap]) {
            stripeSolidColor = [NSColor colorNamed:@"SetlistIgnoreAutoGapStripe"];
        }
    }

    if (stripeSolidColor || stripeDashColor) {
        [stripeView setSolidColor:stripeSolidColor];
        [stripeView setDashColor:stripeDashColor];
        [stripeView setHidden:NO];
    } else {
        [stripeView setHidden:YES];
    }

    TrackLabel trackLabel = [track trackLabel];
    [[self edgeLabelView] setLabel:trackLabel];
    [[self edgeLabelView] setHidden:![[Preferences sharedInstance] showsLabelStripes]];
}


- (void) _updateFieldStrings
{
    Preferences *preferences = [Preferences sharedInstance];

    Track *track = [self track];
    if (!track) return;

    NSInteger numberOfLines = [preferences numberOfLayoutLines];

    NSMutableArray *a_2L = [NSMutableArray array];
    NSMutableArray *a_2R = [NSMutableArray array];
    NSMutableArray *a_3L = [NSMutableArray array];
    NSMutableArray *a_3R = [NSMutableArray array];

    NSMutableArray *(^sparsest)(NSArray<NSMutableArray *> *) = ^(NSArray<NSMutableArray *> *arrays) {
        NSMutableArray *result = nil;
        NSInteger minCount = NSIntegerMax;
        
        for (NSMutableArray *array in arrays) {
            NSInteger arrayCount = [array count];

            if (arrayCount < minCount) {
                result = array;
                minCount = arrayCount;
            }
        }

        return result;
    };

    // outMarkRange comes back as the range of the BPM inside the returned string
    // when that BPM was measured rather than read off a tag, and as a zero
    // length range otherwise.
    NSString *(^collectAttributes)(NSArray *, NSRange *) = ^(NSArray *attributes, NSRange *outMarkRange) {
        NSMutableArray *strings = [NSMutableArray array];
        NSInteger markIndex = NSNotFound;

        for (NSNumber *attributeNumber in attributes) {
            TrackViewAttribute attribute = [attributeNumber integerValue];
            NSString *string = nil;

            if (attribute == TrackViewAttributeAlbumArtist) {
                string = [track albumArtist];

            } else if (attribute == TrackViewAttributeArtist) {
                string = [track artist];

            } else if (attribute == TrackViewAttributeBeatsPerMinute) {
                NSInteger bpm = [track effectiveBeatsPerMinute];

                if (bpm) {
                    string = sLocalizedDecimalString(bpm);

                    // A number the DJ typed reads as plain as the rest of the
                    // line; one this app worked out gets marked.  This is the
                    // index it is about to be added at.
                    if ([track beatsPerMinuteWasMeasured]) markIndex = [strings count];
                }

            } else if (attribute == TrackViewAttributeComments) {
                string = [track comments];

            } else if (attribute == TrackViewAttributeEnergyLevel) {
                NSInteger energyLevel = [track energyLevel];
                if (energyLevel) string = sLocalizedDecimalString(energyLevel);
        
            } else if (attribute == TrackViewAttributeGenre) {
                string = [track genre];

            } else if (attribute == TrackViewAttributeGrouping) {
                string = [track grouping];

            } else if (attribute == TrackViewAttributeKeySignature) {
                KeySignatureDisplayMode displayMode = [preferences keySignatureDisplayMode];
        
                if (displayMode == KeySignatureDisplayModeRaw) {
                    string = [track initialKey];

                } else if (displayMode == KeySignatureDisplayModeTraditional) {
                    string = GetTraditionalStringForTonality([track tonality]);

                } else if (displayMode == KeySignatureDisplayModeOpenKeyNotation) {
                    string = GetOpenKeyNotationStringForTonality([track tonality]);
                }

            } else if (attribute == TrackViewAttributeYear) {
                NSInteger year = [track year];
                if (year) string = [NSString stringWithFormat:@"%ld", (long)year];

            } else if (attribute == TrackViewAttributeRecordedDate) {
                string = [track recordedDate];
            }
            
            if (string) [strings addObject:string];
        }

        NSString *joiner = NSLocalizedString(@" \\U2013 ", nil);
        NSString *result = [strings componentsJoinedByString:joiner];

        if (outMarkRange) {
            *outMarkRange = NSMakeRange(NSNotFound, 0);

            if (markIndex != NSNotFound) {
                // Count the pieces in front of it rather than searching the
                // joined string for the number: two attributes on one line can
                // easily read the same, and the wrong one would get marked.
                NSUInteger location = markIndex * [joiner length];

                for (NSInteger i = 0; i < markIndex; i++) {
                    location += [[strings objectAtIndex:i] length];
                }

                *outMarkRange = NSMakeRange(location, [[strings objectAtIndex:markIndex] length]);
            }
        }

        return result;
    };

    if ([preferences showsArtist]) {
        [a_2L addObject:@(TrackViewAttributeArtist)];
    }

    if ([preferences showsAlbumArtist]) {
        [a_2L addObject:@(TrackViewAttributeAlbumArtist)];
    }

    if ([preferences showsYear]) {
        [a_2L addObject:@(TrackViewAttributeYear)];
    }

    if ([preferences showsRecordedDate]) {
        [a_2L addObject:@(TrackViewAttributeRecordedDate)];
    }

    if ([preferences showsBPM]) {
        [a_2R addObject:@(TrackViewAttributeBeatsPerMinute)];
    }
    
    if ([preferences showsEnergyLevel]) {
        [a_2R addObject:@(TrackViewAttributeEnergyLevel)];
    }

    if ([preferences showsKeySignature]) {
        [a_2R addObject:@(TrackViewAttributeKeySignature)];
    }

    if ([preferences showsComments]) {
        [(numberOfLines == 3 ? a_3L : a_2R) addObject:@(TrackViewAttributeComments)];
    }

    if ([preferences showsGrouping]) {
        NSMutableArray *array;

        if (numberOfLines == 2) {
            array = sparsest(@[ a_2R, a_2L ]);
        } else {
            array = sparsest(@[ a_3R, a_3L, a_2R, a_2L ]);
        }

        [array addObject:@(TrackViewAttributeGrouping)];
    }

    if ([preferences showsGenre]) {
        NSMutableArray *array;

        if (numberOfLines == 2) {
            array = sparsest(@[ a_2R, a_2L ]);
        } else {
            array = sparsest(@[ a_3L, a_3R, a_2R, a_2L ]);
        }

        [array addObject:@(TrackViewAttributeGenre)];
    }

  
    NSRange detectedBPMRange = NSMakeRange(NSNotFound, 0);

    [[self lineTwoLeftField]    setStringValue:collectAttributes(a_2L, NULL)];
    [[self lineTwoRightField]   setStringValue:collectAttributes(a_2R, &detectedBPMRange)];
    [[self lineThreeLeftField]  setStringValue:collectAttributes(a_3L, NULL)];
    [[self lineThreeRightField] setStringValue:collectAttributes(a_3R, NULL)];

    _detectedBPMRange = detectedBPMRange;
    [self _updateDetectedBPMMark];

    NSString *timeString = @"";
    NSString *timeStringFormat;
    NSDate   *date;
    
    if ([track trackStatus] == TrackStatusPlayed) {
        date = [track playedTimeDate];
        timeStringFormat = NSLocalizedString(@"Played at %@", nil);
    } else {
        date = [track estimatedEndTimeDate];
        timeStringFormat = NSLocalizedString(@"Ends at %@", nil);
    }

    if (date) {
        timeString = [NSString stringWithFormat:timeStringFormat, [sGetTimeFormatter() stringFromDate:date]];
    }
       
    [_timeField setStringValue:timeString];
    
    NSString *titleString = [track title];
    if (!titleString) titleString = @"";
    [[self titleField] setStringValue:titleString];
    
    NSString *durationString = GetStringForTime(round([track playDuration]));
    if (!durationString) durationString = @"";
    [[self durationField] setStringValue:durationString];
}


// Draws the line-two-right field, in the mark color where a measured BPM is on
// it and in the plain secondary color everywhere else.  Every run carries its
// own font and color: an attributed string is not obliged to take any notice of
// what -setTextColor: and -setFont: say, so it is told the whole answer rather
// than half of one.
- (void) _updateDetectedBPMMark
{
    NSTextField *field = [self lineTwoRightField];
    NSString    *string = [field stringValue];

    // The range belongs to whatever -_updateFieldStrings last built.  A cell
    // reused for another track can be recolored before it is refilled, so the
    // range is checked against the string in hand rather than trusted.
    BOOL marks = _detectedBPMColor &&
                 _secondaryTextColor &&
                 _detectedBPMRange.length &&
                 NSMaxRange(_detectedBPMRange) <= [string length];

    if (!marks) {
        // -setStringValue: drops the attributes an earlier pass left behind,
        // and the field's own text color takes the line back over.  Only worth
        // doing where there are attributes to drop: this runs for every visible
        // cell every time the selection moves, and most of them have no mark on
        // them to begin with.
        if (_detectedBPMMarked) {
            [field setStringValue:string];
            _detectedBPMMarked = NO;
        }

        return;
    }

    NSDictionary *attributes = @{
        NSFontAttributeName:            [self _secondaryFont],
        NSForegroundColorAttributeName: _secondaryTextColor
    };

    NSMutableAttributedString *value = [[NSMutableAttributedString alloc] initWithString:string attributes:attributes];
    [value addAttribute:NSForegroundColorAttributeName value:_detectedBPMColor range:_detectedBPMRange];

    [field setAttributedStringValue:value];
    _detectedBPMMarked = YES;
}


- (void) _updateFieldHidden
{
    NSInteger numberOfLines = [[Preferences sharedInstance] numberOfLayoutLines];

    NSTextField *line1Right  = [self durationField];
    NSTextField *line2Left   = [self lineTwoLeftField];
    NSTextField *line2Right  = [self lineTwoRightField];
    NSTextField *line3Left   = [self lineThreeLeftField];
    NSTextField *line3Right  = [self lineThreeRightField];
    NSView      *errorButton = [self errorButton];

    BOOL showError = [[self track] error] != nil;
    
    [line1Right  setHidden:showError];
    [line2Left   setHidden:(numberOfLines < 2)];
    [line2Right  setHidden:showError || (numberOfLines < 2)];
    [line3Left   setHidden:(numberOfLines < 3)];
    [line3Right  setHidden:showError || (numberOfLines < 3)];
    [errorButton setHidden:!showError];
}


- (void) _updateFieldAlphas
{
    BOOL shortensPlayedTracks = [[Preferences sharedInstance] shortensPlayedTracks];
    BOOL isPlayedTrack        = [[self track] trackStatus] == TrackStatusPlayed;
    
    if (shortensPlayedTracks && isPlayedTrack) {
        [[[self lineTwoLeftField]    animator] setAlphaValue:_expandedPlayedTrack ? 1.0 : 0.0];
        [[[self lineThreeLeftField]  animator] setAlphaValue:_expandedPlayedTrack ? 1.0 : 0.0];
        [[[self lineTwoRightField]   animator] setAlphaValue:_expandedPlayedTrack ? 1.0 : 0.0];
        [[[self lineThreeRightField] animator] setAlphaValue:_expandedPlayedTrack ? 1.0 : 0.0];
    } else {
        [[self lineTwoLeftField]    setAlphaValue:1.0];
        [[self lineThreeLeftField]  setAlphaValue:1.0];
        [[self lineTwoRightField]   setAlphaValue:1.0];
        [[self lineThreeRightField] setAlphaValue:1.0];
    }

    CGFloat endTimeAlpha = _showsTime ? 1.0 : 0.0;
    
    if (_animatesTime) {
        [[_timeField    animator] setAlphaValue:endTimeAlpha];
        [[_timeMaskView animator] setAlphaValue:endTimeAlpha];

    } else {
        [_timeField    setAlphaValue:endTimeAlpha];
        [_timeMaskView setAlphaValue:endTimeAlpha];
    }

    [_timeField setContentCompressionResistancePriority:(_showsTime ? (NSLayoutPriorityDefaultHigh + 1) : 1) forOrientation:NSLayoutConstraintOrientationHorizontal];
}


- (NSFont *) _secondaryFont
{
    BOOL usesLargerText = [[Preferences sharedInstance] usesLargerText];
    return [NSFont systemFontOfSize:(usesLargerText ? 14.0 : 11.0) weight:NSFontWeightRegular];
}


- (void) _updateFieldFonts
{
    BOOL usesLargerText = [[Preferences sharedInstance] usesLargerText];
    
    CGFloat primaryFontSize   = usesLargerText ? 16.0 : 13.0;
    CGFloat secondaryFontSize = usesLargerText ? 14.0 : 11.0;

    NSFont *titleFont     = [NSFont systemFontOfSize:primaryFontSize                  weight:NSFontWeightRegular];
    NSFont *secondaryFont = [self _secondaryFont];
    NSFont *durationFont  = [NSFont monospacedDigitSystemFontOfSize:primaryFontSize   weight:NSFontWeightRegular];
    NSFont *timeFont      = [NSFont monospacedDigitSystemFontOfSize:secondaryFontSize weight:NSFontWeightRegular];

    [[self titleField]    setFont:titleFont];
    [[self durationField] setFont:durationFont];

    [[self lineTwoLeftField]    setFont:secondaryFont];
    [[self lineTwoRightField]   setFont:secondaryFont];
    [[self lineThreeLeftField]  setFont:secondaryFont];
    [[self lineThreeRightField] setFont:secondaryFont];
    
    [[self firstLineTopConstraint]  setConstant:(usesLargerText ? 6 : 2)];
    [[self secondLineTopConstraint] setConstant:2];
    [[self thirdLineTopConstraint]  setConstant:2];
        
    [_timeField setFont:timeFont];
}


#pragma mark - Public Methods

- (void) revealTime
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_unrequestTime) object:nil];
    [self performSelector:@selector(_unrequestTime) withObject:nil afterDelay:2];

    _timeRequested = YES;
    [self _updateTimeVisibilityAnimated:YES];
}


#pragma mark - Accessors

- (void) setBackgroundStyle:(NSBackgroundStyle)backgroundStyle
{
    [super setBackgroundStyle:backgroundStyle];
    [self updateColors];
}


- (void) setExpandedPlayedTrack:(BOOL)expandedPlayedTrack
{
    if (_expandedPlayedTrack != expandedPlayedTrack) {
        _expandedPlayedTrack = expandedPlayedTrack;
        [self _updateView];
    }
}


- (Track *) track
{
    return (Track *)[self objectValue];
}


@end
