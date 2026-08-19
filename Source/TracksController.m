// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "TracksController.h"
#import "Track.h"
#import "TrackTableCellView.h"
#import "AppDelegate.h"
#import "Player.h"
#import "Preferences.h"
#import "TrackTableView.h"
#import "TrackTableRowView.h"
#import "MusicAppManager.h"
#import "ExportManager.h"


NSString * const TracksControllerDidModifyTracksNotificationName = @"TracksControllerDidModifyTracks";

NSString *EmbraceLockedTrackPasteboardType = nil;
NSString *EmbraceQueuedTrackPasteboardType = nil;

static NSString * const sTrackUUIDsKey = @"track-uuids";
static NSString * const sModifiedAtKey = @"modified-at";

@interface TracksController () <NSMenuItemValidation>
@property (nonatomic) NSUInteger count;
@property (nonatomic, weak) IBOutlet TrackTableView *tableView;
@end


@implementation TracksController {
    BOOL _didInit;
    NSMutableArray *_tracks;

    NSIndexSet *_draggedIndexSet;
    BOOL _draggedIndexSetIsContiguous;

    BOOL       _dragCacheIsExternal;
    NSArray   *_dragCacheMetadataArray;
    NSArray   *_dragCacheFileURLs;
    NSInteger  _dragCacheChangeCount;
}

+ (void) initialize
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        long pid = (long)getpid();

        NSString *lockedSuffix = [NSString stringWithFormat:@"%ld.Track.Locked", pid];
        NSString *queuedSuffix = [NSString stringWithFormat:@"%ld.Track.Queued", pid];

        EmbraceLockedTrackPasteboardType = GetBundleIdentifierWithSuffix(lockedSuffix);
        EmbraceQueuedTrackPasteboardType = GetBundleIdentifierWithSuffix(queuedSuffix);
    });
}


- (void) awakeFromNib
{
    if (_didInit) return;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handlePreferencesDidChange:) name:PreferencesDidChangeNotification object:nil];

    [[self tableView] registerForDraggedTypes:@[
        EmbraceQueuedTrackPasteboardType,
        EmbraceLockedTrackPasteboardType
    ]];

    [[self tableView] registerForDraggedTypes:[self readableDraggedTypes]];

    [[self tableView] setGridStyleMask:NSTableViewSolidHorizontalGridLineMask];
    
    NSNib *nib = [[NSNib alloc] initWithNibNamed:@"TrackTableCellView" bundle:nil];
    [[self tableView] registerNib:nib forIdentifier:@"TrackCell"];

    [self _loadState];
    [self detectDuplicates];
    [[self tableView] reloadData];
    
    _didInit = YES;
}


#pragma mark - Importing Tracks

static NSString *sGetFileType(NSURL *url)
{
    NSString *typeIdentifier = nil;
    NSError  *error = nil;
    [url getResourceValue:&typeIdentifier forKey:NSURLTypeIdentifierKey error:&error];

    return typeIdentifier;
}


static void sCollectURL(NSURL *inURL, NSMutableArray *results, NSInteger depth)
{
    static const NSInteger sMaxDepth = 5;

    if (depth > sMaxDepth) {
        return;
    }
    
    NSString *type = sGetFileType(inURL);
    if (!type) return;

    if (UTTypeConformsTo((__bridge CFStringRef)type, kUTTypeM3UPlaylist)) {
        if (depth < sMaxDepth) {
            sCollectM3UPlaylistURL(inURL, results, depth + 1);
        }

    } else if (UTTypeConformsTo((__bridge CFStringRef)type, kUTTypeFolder)) {
        if (depth < sMaxDepth) {
            sCollectFolderURL(inURL, results, depth + 1);
        }

    } else if (UTTypeConformsTo((__bridge CFStringRef)type, kUTTypeAudiovisualContent) || (depth == 0)) {
        [results addObject:inURL];
    }
}


static void sCollectFolderURL(NSURL *inURL, NSMutableArray *results, NSInteger depth)
{
    NSDirectoryEnumerationOptions options =
        NSDirectoryEnumerationSkipsSubdirectoryDescendants |
        NSDirectoryEnumerationSkipsPackageDescendants |    
        NSDirectoryEnumerationSkipsHiddenFiles;
        
    NSError *error = nil;
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:inURL includingPropertiesForKeys:@[ NSURLTypeIdentifierKey ] options:options error:&error];

    for (NSURL *url in contents) {
        sCollectURL(url, results, depth);
    }
}


static void sCollectM3UPlaylistURL(NSURL *inURL, NSMutableArray *results, NSInteger depth)
{
    EmbraceLog(@"TrackController", @"Parsing M3U at: %@", inURL);

    NSData *data = [NSData dataWithContentsOfURL:inURL];
    if (!data) return;
    
    NSString *contents = nil;
    if (!contents || [contents length] < 8) {
        EmbraceLog(@"TrackController", @"Trying UTF-8 encoding");
        contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }

    if (!contents || [contents length] < 8) {
        EmbraceLog(@"TrackController", @"Trying UTF-16 encoding");
        contents = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    }

    if (!contents || [contents length] < 8) {
        EmbraceLog(@"TrackController", @"Trying Latin-1 encoding");
        contents = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    
    NSURL *baseURL = [inURL URLByDeletingLastPathComponent];
    
    if ([contents length] >= 8) {
        for (NSString *line in [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            if ([line hasPrefix:@"#"]) {
                continue;

            } else if ([line hasPrefix:@"file:"]) {
                NSURL *url = [NSURL URLWithString:line];
                
                if ([url isFileURL]) {
                    sCollectURL(url, results, depth);
                }
                
            } else {
                NSString *trimmedPath = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                NSURL *url = [NSURL fileURLWithPath:trimmedPath relativeToURL:baseURL];
                
                if ([url isFileURL]) {
                    sCollectURL(url, results, depth);
                }
            }
        }
    }
}


- (BOOL) _addTracksWithURLs:(NSArray<NSURL *> *)inURLs atIndex:(NSUInteger)index
{
    EmbraceLog(@"TracksController", @"Collecting tracks at URLs: %@", inURLs);

    NSMutableArray *results = [NSMutableArray array];

    for (NSURL *inURL in inURLs) {
        sCollectURL(inURL, results, 0);
    }

    NSInteger resultsCount = [results count];

    EmbraceLog(@"TracksController", @"Found %ld tracks", (long)resultsCount);

    if (resultsCount > 0) {
        BOOL okToAdd = YES;
        
        if (resultsCount > 100) {
            NSAlert *alert = [[NSAlert alloc] init];

            NSString *messageFormat = NSLocalizedString(@"Add %@ Tracks", nil);
            NSString *numberString = [NSNumberFormatter localizedStringFromNumber:@(resultsCount) numberStyle:NSNumberFormatterDecimalStyle];

            [alert setMessageText:[NSString stringWithFormat:messageFormat, numberString]];
            [alert setInformativeText:NSLocalizedString(@"Do you really want to add these tracks to your Set List?", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"Add Tracks", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
            
            [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
            okToAdd = ([alert runModal] == NSAlertFirstButtonReturn);

        } else {
            EmbraceLog(@"TracksController", @"Found tracks: %@", results);
        }
        
        if (okToAdd) {
            NSMutableIndexSet *indexSet = [NSMutableIndexSet indexSet];

            [[self tableView] beginUpdates];

            for (NSURL *url in results) {
                Track *track = [Track trackWithFileURL:url];
                
                if (track) {
                    [_tracks insertObject:track atIndex:index];
                    [indexSet addIndex:index];
                    index++;
                }
            }

            [[self tableView] insertRowsAtIndexes:indexSet withAnimation:NSTableViewAnimationEffectFade];

            [[self tableView] endUpdates];
            
            [self _didModifyTracks];

            return YES;
        }
    }

    return NO;
}


#pragma mark - Private Methods

- (void) _saveState
{
    NSMutableArray *trackUUIDsArray = [NSMutableArray array];

    for (Track *track in [self tracks]) {
        NSUUID *uuid = [track UUID];
        if (uuid) [trackUUIDsArray addObject:[uuid UUIDString]];
    }

    [[NSUserDefaults standardUserDefaults] setObject:trackUUIDsArray forKey:sTrackUUIDsKey];
}


- (void) _loadState
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *tracks = [NSMutableArray array];

    NSArray *trackUUIDs  = [defaults objectForKey:sTrackUUIDsKey];

    if ([trackUUIDs isKindOfClass:[NSArray class]]) {
        for (NSString *uuidString in trackUUIDs) {
            NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
            Track *track = [Track trackWithUUID:uuid];

            if (track) [tracks addObject:track];
            
            TrackStatus trackStatus = [track trackStatus];
            
            if ((trackStatus == TrackStatusPreparing) || (trackStatus == TrackStatusPlaying)) {
                [track setTrackStatus:TrackStatusPlayed];
            }
        }
    }
    
    _tracks = tracks;
}


- (void) _handlePreferencesDidChange:(NSNotification *)note
{
    [[self tableView] reloadData];
}


- (void) _didModifyTracks
{
    [self detectDuplicates];

    NSTimeInterval t = [NSDate timeIntervalSinceReferenceDate];
    [[NSUserDefaults standardUserDefaults] setObject:@(t) forKey:sModifiedAtKey];

    [[NSNotificationCenter defaultCenter] postNotificationName:TracksControllerDidModifyTracksNotificationName object:self];

    [self _saveState];
}


- (BOOL) _isIndexSetContiguous:(NSIndexSet *)indexSet
{
    NSUInteger row = [indexSet firstIndex];
    if (row == NSNotFound) return NO;

    while (row != NSNotFound) {
        NSUInteger nextRow = [indexSet indexGreaterThanIndex:row];
        
        if ((nextRow != NSNotFound) && (nextRow != (row + 1))) {
            return NO;
        }
        
        row = nextRow;
    }

    return YES;
}


#pragma mark - Dragging

- (void) _updateDragCacheWithPasteboard:(NSPasteboard *)pasteboard
{
    if ([pasteboard changeCount] == _dragCacheChangeCount) {
        return;
    }
    
    MusicAppPasteboardParseResult *parseResult = [[MusicAppManager sharedInstance] parsePasteboard:pasteboard];

    BOOL isQueuedTrack = ([pasteboard dataForType:EmbraceQueuedTrackPasteboardType] != nil);
    BOOL isLockedTrack = ([pasteboard dataForType:EmbraceLockedTrackPasteboardType] != nil);
    BOOL isExternalTrack = !isQueuedTrack && !isLockedTrack;

    _dragCacheIsExternal    = isExternalTrack;
    _dragCacheMetadataArray = isExternalTrack ? [parseResult metadataArray] : nil;
    _dragCacheFileURLs      = isExternalTrack ? [parseResult fileURLs]      : nil;
    _dragCacheChangeCount   = [pasteboard changeCount];
}


- (NSArray<NSString *> *) readableDraggedTypes
{
    return @[
        (__bridge NSString *)kUTTypeFileURL,
        (__bridge NSString *)kPasteboardTypeFileURLPromise,
        @"com.apple.music.metadata",
        @"com.apple.tv.metadata",
        NSPasteboardTypeURL,
        @"NSFilenamesPboardType",
    ];
}


- (BOOL) writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pboard
{
    NSArray *tracksToDrag = [_tracks objectsAtIndexes:rowIndexes];

    BOOL hasQueued    = NO;
    BOOL hasNotQueued = NO;

    for (Track *track in tracksToDrag) {
        if ([track trackStatus] != TrackStatusQueued) {
            hasNotQueued = YES;
        } else {
            hasQueued = YES;
        }
    }
    
    // Don't allow queued and non-queued
    if (hasNotQueued && hasQueued) {
        return NO;
    }
    
    [pboard setData:[NSData data] forType:(hasQueued ? EmbraceQueuedTrackPasteboardType : EmbraceLockedTrackPasteboardType)];

    _draggedIndexSet = rowIndexes;
    _draggedIndexSetIsContiguous = [self _isIndexSetContiguous:_draggedIndexSet];
    
    return YES;
}


- (NSDragOperation) validateDrop:(id <NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation
{
    NSPasteboard *pasteboard = [info draggingPasteboard];

    [self _updateDragCacheWithPasteboard:pasteboard];

    BOOL isQueuedTrack   =  ([pasteboard dataForType:EmbraceQueuedTrackPasteboardType] != nil);
    BOOL isExternalTrack = _dragCacheIsExternal;

    NSDragOperation mask = [info draggingSourceOperationMask];
    BOOL isCopy = (mask & (NSDragOperationGeneric|NSDragOperationCopy)) == NSDragOperationCopy;
    
    if (isExternalTrack) {
        if (![_dragCacheFileURLs count]) {
            return NSDragOperationNone;
        }

        isCopy = YES;
        
        [info setNumberOfValidItemsForDrop:[_dragCacheFileURLs count]];
    }
    
    if (dropOperation == NSTableViewDropAbove) {
        Track *track = [self trackAtIndex:row];

        if (!track || [track trackStatus] == TrackStatusQueued) {
            if (isCopy) {
                return NSDragOperationCopy;

            } else if (!_draggedIndexSetIsContiguous) {
                return NSDragOperationGeneric;

            } else if (isQueuedTrack) {
                if ((row >= [_draggedIndexSet firstIndex]) && (row <= ([_draggedIndexSet lastIndex] + 1))) {
                    return NSDragOperationNone;
                } else {
                    if (isCopy) {
                        return NSDragOperationCopy;
                    } else {
                        return NSDragOperationGeneric;
                    }
                }

            } else {
                return NSDragOperationNone;
            }
        }
    }

    if (isExternalTrack) {
        if (dropOperation == NSTableViewDropOn) {
            Track *track = [self trackAtIndex:row];

            if (!track || [track trackStatus] == TrackStatusQueued) {
                [_tableView setDropRow:(row + 1) dropOperation:NSTableViewDropAbove];
                return NSDragOperationCopy;
            }
        }
    
        // Always accept a drag from Music.app, target end of table in this case
        [_tableView setDropRow:-1 dropOperation:NSTableViewDropOn];
        return NSDragOperationCopy;
    }

    return NSDragOperationNone;
}


- (BOOL) acceptDrop:(id <NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation;
{
    EmbraceLog(@"TracksController", @"Accepting drop: %@ -> %ld, %ld", _draggedIndexSet, (long)row, (long)dropOperation);

    NSPasteboard *pboard = [info draggingPasteboard];
    BOOL result = NO;

    // Dump pasteboard to log:
    {
        EmbraceLog(@"TracksController", @"Pasteboard contains %ld items", (long)[[pboard pasteboardItems] count]);
        NSInteger index = 0;

        for (NSPasteboardItem *item in [pboard pasteboardItems]) {
            EmbraceLog(@"Pasteboard", @"Pasteboard item %ld: %@", (long)index, item);
            
            for (NSString *type in [item types]) {
                EmbraceLog(@"Pasteboard", @"Type: %@\n%@", type, [pboard propertyListForType:type]);
            }
            
            index++;
        }
    }

    [self _updateDragCacheWithPasteboard:pboard];

    if (_dragCacheMetadataArray) {
        [[MusicAppManager sharedInstance] addPasteboardMetadataArray:_dragCacheMetadataArray];
    }

    NSDragOperation dragOperation = [self validateDrop:info proposedRow:row proposedDropOperation:dropOperation];

    if ((row == -1) && (dropOperation == NSTableViewDropOn)) {
        row = [_tracks count];
    }
    
    if (_dragCacheIsExternal) {
        EmbraceLog(@"TracksController", @"adding tracks at row %ld: %@", (long)row, _dragCacheFileURLs);
        result = [self _addTracksWithURLs:_dragCacheFileURLs atIndex:row];

    } else {
        [[self tableView] beginUpdates];

        if (dragOperation == NSDragOperationCopy) {
            EmbraceLog(@"TracksController", @"Duplicating track from %@ to %ld", _draggedIndexSet, row);

            NSMutableArray *duplicatedTracks = [NSMutableArray array];
            
            for (Track *oldTrack in [_tracks objectsAtIndexes:_draggedIndexSet]) {
                [duplicatedTracks addObject:[oldTrack duplicatedTrack]];
            }
            
            NSIndexSet *indexSet = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(row, [duplicatedTracks count])];
            
            [[self tableView] insertRowsAtIndexes:indexSet withAnimation:NSTableViewAnimationEffectFade];
            [_tracks insertObjects:duplicatedTracks atIndexes:indexSet];

        } else if (dragOperation == NSDragOperationGeneric) {
            EmbraceLog(@"TracksController", @"Moving track from %@ to %ld", _draggedIndexSet, row);

            __block NSInteger oldIndexOffset = 0;
            __block NSInteger newIndexOffset = 0;

            [_draggedIndexSet enumerateIndexesUsingBlock:^(NSUInteger oldIndex, BOOL *stop) {
                Track *track = [self trackAtIndex:(oldIndex + oldIndexOffset)];
                
                if (track) {
                    NSInteger toIndex, fromIndex;

                    if (oldIndex < row) {
                        fromIndex = oldIndex + oldIndexOffset;
                        toIndex   = row - 1;
                        oldIndexOffset--;
                    } else {
                        fromIndex = oldIndex;
                        toIndex = row + newIndexOffset;
                        newIndexOffset++;
                    }

                    [_tableView moveRowAtIndex:fromIndex toIndex:toIndex];
                    [_tracks removeObjectAtIndex:fromIndex];
                    [_tracks insertObject:track atIndex:toIndex];
                }
            }];
        }

        [self _didModifyTracks];

        [[self tableView] endUpdates];
        
        result = YES;
    } 

    EmbraceLog(@"TracksController", @"acceptDrop:... returning %ld", (long)result);
    
    return result;
}


#pragma mark - Table View Delegate

- (NSInteger) numberOfRowsInTableView:(NSTableView *)tableView
{
    return [_tracks count];
}


- (id) tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    return [_tracks objectAtIndex:row];
}


#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

- (BOOL) tableView:(NSTableView *)tableView writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pboard
{
    return [self writeRowsWithIndexes:rowIndexes toPasteboard:pboard];
}

#pragma clang diagnostic pop


- (NSView *) tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row
{
    TrackTableRowView *rowView = [tableView makeViewWithIdentifier:@"TrackRow" owner:self];

    if (!rowView) {
        rowView = [[TrackTableRowView alloc] initWithFrame:CGRectZero];
        [rowView setIdentifier:@"TrackRow"];
    }

    return rowView;
}


- (NSView *) tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    return [tableView makeViewWithIdentifier:@"TrackCell" owner:self];
}


- (CGFloat) tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row
{
    Preferences *preferences = [Preferences sharedInstance];

    NSInteger numberOfLines = [preferences numberOfLayoutLines];
    BOOL shortensPlayedTracks = [preferences shortensPlayedTracks];
    BOOL usesLargerText = [preferences usesLargerText];
    
    BOOL usesOneLine = (numberOfLines == 1);
    
    Track *track = [self trackAtIndex:row];
    if (shortensPlayedTracks && ([track trackStatus] == TrackStatusPlayed)) {
        if (row != [[self tableView] rowWithMouseInside]) {
            usesOneLine = YES;
        }
    }
    
    if (usesOneLine) {
        return usesLargerText ? 32 : 24;
    } else if (numberOfLines == 2) {
        return usesLargerText ? 52 : 39;
    } else {
        return usesLargerText ? 74 : 56;
    }
}


- (void) tableView:(NSTableView *)tableView draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation
{
    if (operation == NSDragOperationNone) {
        NSRect frame = [[[self tableView] window] frame];

        BOOL isLockedTrack = [[session draggingPasteboard] dataForType:EmbraceLockedTrackPasteboardType] != nil;

        if (!NSPointInRect(screenPoint, frame)) {
            if (!isLockedTrack && ([_draggedIndexSet count] != 0)) {
                [[self tableView] beginUpdates];
                [[self tableView] removeRowsAtIndexes:_draggedIndexSet withAnimation:NSTableViewAnimationEffectFade];
                [_tracks removeObjectsAtIndexes:_draggedIndexSet];
                [[self tableView] endUpdates];
 
                [self _didModifyTracks];
                
                NSShowAnimationEffect(NSAnimationEffectPoof, [NSEvent mouseLocation], NSZeroSize, nil, nil, nil);
            }
        }
    }

    _draggedIndexSet = nil;
    _draggedIndexSetIsContiguous = NO;

    _dragCacheFileURLs = nil;
    _dragCacheMetadataArray = nil;
}


- (NSDragOperation) tableView:(NSTableView *)tableView validateDrop:(id <NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation
{
    return [self validateDrop:info proposedRow:row proposedDropOperation:dropOperation];
}


- (BOOL) tableView:(NSTableView *)tableView acceptDrop:(id <NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation;
{
    return [self acceptDrop:info row:row dropOperation:dropOperation];
}


- (void) trackTableView:(TrackTableView *)tableView isModifyingViaDrag:(BOOL)isModifyingViaDrag
{
    [[Player sharedInstance] setPreventNextTrack:isModifyingViaDrag];
}


#pragma mark - Menu Item Validation

- (BOOL) validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = [menuItem action];

    if (action == @selector(paste:)) {
        return [[NSPasteboard generalPasteboard] canReadItemWithDataConformingToTypes:@[ (__bridge NSString *)kUTTypeFileURL, @"NSFilenamesPboardType" ]];

    } else if (action == @selector(copy:)) {
        return [[self selectedTracks] count] > 0;
    
    } else if (action == @selector(delete:)) {
        return [self _validateDeleteWithMenuItem:menuItem];

    } else if (action == @selector(toggleMarkAsPlayed:)) {
        return [self _validateToggleMarkAsPlayedWithMenuItem:menuItem];
        
    } else if (action == @selector(toggleStopsAfterPlaying:)) {
        return [self _validateToggleStopsAfterPlayingWithMenuItem:menuItem];
 
    } else if (action == @selector(toggleIgnoreAutoGap:)) {
        return [self _validateToggleIgnoreAutoGapWithMenuItem:menuItem];
    
    } else if (action == @selector(revealTime:)) {
        return [self _validateRevealTimeWithMenuItem:menuItem];
    }
    
    return YES;
}


- (BOOL) _containsOnlyPlayedTracks:(NSArray *)tracks
{
    if (![tracks count]) return NO;

    for (Track *track in tracks) {
        if ([track trackStatus] != TrackStatusPlayed) return NO;
    }

    return YES;
}


- (BOOL) canDeleteSelectedTracks
{
    NSArray *selectedTracks = [self selectedTracks];

    if (![selectedTracks count]) return NO;
    if ([self _containsOnlyPlayedTracks:selectedTracks]) return YES;

    for (Track *track in selectedTracks) {
        if ([track trackStatus] != TrackStatusQueued) return NO;
    }

    return YES;
}


- (BOOL) _validateDeleteWithMenuItem:(NSMenuItem *)menuItem
{
    NSString *deleteTitle  = NSLocalizedString(@"Delete", nil);
    NSString *confirmTitle = NSLocalizedString(@"Delete\\U2026", nil);

    if ([self _containsOnlyPlayedTracks:[self selectedTracks]]) {
        [menuItem setTitle:confirmTitle];
    } else {
        [menuItem setTitle:deleteTitle];
    }

    return [self canDeleteSelectedTracks];
}


- (BOOL) _validateToggleStopsAfterPlayingWithMenuItem:(NSMenuItem *)menuItem
{
    NSArray *selectedTracks = [self selectedTracks];
    
    BOOL isEnabled = YES;
    BOOL isOn      = NO;
    BOOL isOff     = NO;
    
    for (Track *track in selectedTracks) {
        BOOL canStop = [track trackStatus] != TrackStatusPlayed;
        if (!canStop) isEnabled = NO;

        BOOL stopsAfterPlaying = (canStop && [track stopsAfterPlaying]);
        if ( stopsAfterPlaying) isOn  = YES;
        if (!stopsAfterPlaying) isOff = YES;
    }
    
    if (isOff && isOn) {
        [menuItem setState:NSControlStateValueMixed];
        isEnabled = NO;
    } else if (isOn) {
        [menuItem setState:NSControlStateValueOn];
    } else {
        [menuItem setState:NSControlStateValueOff];
    }

    return isEnabled;
}


- (BOOL) _validateToggleIgnoreAutoGapWithMenuItem:(NSMenuItem *)menuItem
{
    NSArray *selectedTracks = [self selectedTracks];
    
    BOOL isEnabled = YES;
    BOOL isOn      = NO;
    BOOL isOff     = NO;
    
    for (Track *track in selectedTracks) {
        BOOL canIgnore = [track trackStatus] != TrackStatusPlayed;
        if (!canIgnore) isEnabled = NO;

        BOOL ignoresAutoGap = (canIgnore && [track ignoresAutoGap]);
        if ( ignoresAutoGap) isOn  = YES;
        if (!ignoresAutoGap) isOff = YES;
    }
    
    if (isOff && isOn) {
        [menuItem setState:NSControlStateValueMixed];
        isEnabled = NO;
    } else if (isOn) {
        [menuItem setState:NSControlStateValueOn];
    } else {
        [menuItem setState:NSControlStateValueOff];
    }

    return isEnabled;
}


- (NSControlStateValue) _controlStateForToggleMarkAsPlayed
{
    BOOL isOn = NO;
    BOOL isOff = NO;

    for (Track *track in [self selectedTracks]) {
        if ([track trackStatus] == TrackStatusPlayed) {
            isOn = YES;
        } else {
            isOff = YES;
        }
    }

    if (isOn && isOff) {
        return NSControlStateValueMixed;
    } else if (isOn) {
        return NSControlStateValueOn;
    } else {
        return NSControlStateValueOff;
     }
}


- (BOOL) _validateToggleMarkAsPlayedWithMenuItem:(NSMenuItem *)menuItem
{
    [menuItem setState:[self _controlStateForToggleMarkAsPlayed]];

    if ([[Player sharedInstance] currentTrack]) {
        return NO;
    }

    NSIndexSet *selectedRows = [[self tableView] selectedRowIndexes];

    if (![self _isIndexSetContiguous:selectedRows]) {
        return NO;
    }

    NSInteger firstSelectedRow = [selectedRows firstIndex];
    NSInteger lastSelectedRow  = [selectedRows lastIndex];
    NSInteger count            = [_tracks count];
    
    Track *previousTrack = firstSelectedRow      > 0       ? [_tracks objectAtIndex:(firstSelectedRow - 1)] : nil;
    Track *nextTrack     = (lastSelectedRow + 1) < count   ? [_tracks objectAtIndex:(lastSelectedRow  + 1)] : nil;
    
    BOOL isPreviousPlayed = !previousTrack || ([previousTrack trackStatus] == TrackStatusPlayed);
    BOOL isNextPlayed     =                    [nextTrack     trackStatus] == TrackStatusPlayed;

    return (isPreviousPlayed != isNextPlayed);
}


- (BOOL) _validateRevealTimeWithMenuItem:(NSMenuItem *)menuItem
{
    BOOL hasPlayedTime = NO;
    BOOL hasEndTime    = NO;

    for (Track *track in [self selectedTracks]) {
        if ([track trackStatus] == TrackStatusPlayed) {
            hasPlayedTime = YES;
        } else {
            hasEndTime = YES;
        }
    }

    NSString *title = NSLocalizedString(@"Reveal Time", nil);
    if (hasPlayedTime && !hasEndTime) {
        title = NSLocalizedString(@"Reveal Played Time", nil);
    } else if (!hasPlayedTime && hasEndTime) {
        title = NSLocalizedString(@"Reveal End Time", nil);
    }
    
    [menuItem setTitle:title];

    return [[self selectedTracks] count] > 0;
}


#pragma mark - Selected Track Actions

- (void) delete:(id)sender
{
    if (![self canDeleteSelectedTracks]) return;

    BOOL needsPrompt = [self _containsOnlyPlayedTracks:[self selectedTracks]];

    if (needsPrompt) {
        BOOL isSingular = [[self selectedTracks] count] == 1;

        NSString *messageText = isSingular ?
            NSLocalizedString(@"Delete Track",  nil) :
            NSLocalizedString(@"Delete Tracks", nil) ;

        NSString *infoText    = isSingular ? 
            NSLocalizedString(@"Are you sure you want to delete this played track?",   nil) :
            NSLocalizedString(@"Are you sure you want to delete these played tracks?", nil) ;

        NSAlert *alert = [[NSAlert alloc] init];

        [alert setMessageText:messageText];
        [alert setInformativeText:infoText];
        [alert addButtonWithTitle:NSLocalizedString(@"Delete",  nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];

        if ([alert runModal] != NSAlertFirstButtonReturn) {
            return;
        }
    }

    NSIndexSet *indexSet = [[self tableView] selectedRowIndexes];
    NSMutableIndexSet *indexSetToRemove = [NSMutableIndexSet indexSet];
    
    [indexSet enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        Track *track = [self trackAtIndex:index];
        if (!track) return;

        if ([track trackStatus] == TrackStatusQueued) {
            [track cancelLoad];
            [indexSetToRemove addIndex:index];
        }
    }];
    
    [[self tableView] beginUpdates];

    [[self tableView] removeRowsAtIndexes:indexSet withAnimation:NSTableViewAnimationEffectFade];
    [_tracks removeObjectsAtIndexes:indexSet];

    NSUInteger indexToSelect = [indexSet lastIndex];

    if (indexToSelect >= [_tracks count]) {
        indexToSelect--;
    }

    [[self tableView] selectRowIndexes:[NSIndexSet indexSetWithIndex:indexToSelect] byExtendingSelection:NO];

    [[self tableView] endUpdates];
    
    if ([_tracks count] == 0) {
        [self removeAllTracks];
    } else {
        [self _didModifyTracks];
    }
}


- (void) revealTime:(id)sender
{
    EmbraceLogMethod();

    for (Track *track in [self selectedTracks]) {
        NSInteger index = [_tracks indexOfObject:track];
        
        if (index != NSNotFound) {
            id view = [[self tableView] viewAtColumn:0 row:index makeIfNecessary:NO];
            
            if ([view respondsToSelector:@selector(revealTime)]) {
                [view revealTime];
            }
        }
    }
}


- (void) toggleStopsAfterPlaying:(id)sender
{
    EmbraceLogMethod();

    for (Track *track in [self selectedTracks]) {
        if ([track trackStatus] != TrackStatusPlayed) {
            [track setStopsAfterPlaying:![track stopsAfterPlaying]];
        }
    }
}


- (void) toggleIgnoreAutoGap:(id)sender
{
    EmbraceLogMethod();

    for (Track *track in [self selectedTracks]) {
        if ([track trackStatus] != TrackStatusPlayed) {
            [track setIgnoresAutoGap:![track ignoresAutoGap]];
        }
    }
}


- (void) markTracksAsPlayedBeforeTrack:(Track *)trackToPlay
{
    NSMutableIndexSet *changedRows = [NSMutableIndexSet indexSet];
    NSUInteger index = 0;

    for (Track *track in _tracks) {
        if (track == trackToPlay) break;

        if ([track trackStatus] == TrackStatusQueued) {
            [track setTrackStatus:TrackStatusPlayed];
            [changedRows addIndex:index];
        }

        index++;
    }

    if (![changedRows count]) return;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        [context setDuration:0];

        [[self tableView] beginUpdates];
        [[self tableView] noteHeightOfRowsWithIndexesChanged:changedRows];
        [[self tableView] endUpdates];
    } completionHandler:nil];
}


- (void) toggleMarkAsPlayed:(id)sender
{
    // Be paranoid and double-check the validity
    //
    if (![self _validateToggleMarkAsPlayedWithMenuItem:nil]) {
        return;
    }

    NSControlStateValue controlStateValue = [self _controlStateForToggleMarkAsPlayed];

    TrackStatus newTrackStatus;
    if (controlStateValue == NSControlStateValueOff || controlStateValue == NSControlStateValueMixed) {
        newTrackStatus = TrackStatusPlayed;
    } else {
        newTrackStatus = TrackStatusQueued;
    }

    for (Track *track in [self selectedTracks]) {
        [track setTrackStatus:newTrackStatus];
    }
    
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        [context setDuration:0];

        [[self tableView] beginUpdates];
        [[self tableView] noteHeightOfRowsWithIndexesChanged:[[self tableView] selectedRowIndexes]];
        [[self tableView] endUpdates];
    } completionHandler:nil];
}


- (void) didFinishTrack:(Track *)finishedTrack
{
    NSInteger row = finishedTrack ? [_tracks indexOfObject:finishedTrack] : NSNotFound;

    if (row != NSNotFound) {
        [[self tableView] beginUpdates];
        [[self tableView] noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndex:row]];
        [[self tableView] endUpdates];
    }
}


#pragma mark - Public

- (void) copy:(id)sender
{
    NSArray  *tracks   = [self selectedTracks];
    NSString *contents = [[ExportManager sharedInstance] stringWithFormat:ExportManagerFormatPlainText tracks:tracks];

    NSPasteboardItem *item = [[NSPasteboardItem alloc] initWithPasteboardPropertyList:contents ofType:NSPasteboardTypeString];

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard writeObjects:[NSArray arrayWithObject:item]];
}


- (void) paste:(id)sender
{
    NSPasteboard *pboard = [NSPasteboard generalPasteboard];

    NSArray  *filenames = [pboard propertyListForType:@"NSFilenamesPboardType"];
    NSString *URLString = [pboard stringForType:(__bridge NSString *)kUTTypeFileURL];

    if (filenames) {
        NSMutableArray *fileURLs = [NSMutableArray array];

        for (NSString *filename in filenames) {
            NSURL *fileURL = [NSURL fileURLWithPath:filename];
            if (fileURL) [fileURLs addObject:fileURL];
        }

        [self addTracksWithURLs:fileURLs];

    } else if (URLString) {
        NSURL *fileURL = [NSURL URLWithString:URLString];

        if (fileURL) {
            [self addTracksWithURLs:@[ fileURL ]];
        }
    }
}


- (void) saveState
{
    [self _saveState];
}


- (Track *) firstQueuedTrack
{
    Track *result = nil;

    for (Track *track in _tracks) {
        if ([track trackStatus] == TrackStatusQueued) {
            result = track;
            break;
        }
    }

    return result;
}


- (NSArray *) selectedTracks
{
    NSIndexSet *selectedRows = [[self tableView] selectedRowIndexes];
    
    return selectedRows ? [_tracks objectsAtIndexes:selectedRows] : nil;
}


- (BOOL) addTracksWithURLs:(NSArray<NSURL *> *)fileURLs
{
    NSUInteger index = [_tracks count];
    return [self _addTracksWithURLs:fileURLs atIndex:index];
}


- (void) removeAllTracks
{
    EmbraceLogMethod();

    NSMutableArray *tracksToRemove = [_tracks mutableCopy];
    Track *trackToKeep = [[Player sharedInstance] currentTrack];

    if (trackToKeep) {
        [tracksToRemove removeObject:trackToKeep];
    }

    for (Track *track in tracksToRemove) {
        [track cancelLoad];
    }

    [_tracks removeObjectsInArray:tracksToRemove];
    
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:sModifiedAtKey];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"tracks"];

    for (Track *track in tracksToRemove) {
        [track clearAndCleanup];
    }

    if (!trackToKeep) {
        [Track clearPersistedState];
    }

    [[self tableView] deselectAll:nil];
    [[self tableView] reloadData];

    [self _didModifyTracks];
}


- (void) deselectAllTracks
{
    EmbraceLogMethod();

    [[self tableView] deselectAll:nil];
}


- (void) resetPlayedTracks
{
    EmbraceLogMethod();

    if ([[Player sharedInstance] isPlaying]) return;

    for (Track *track in _tracks) {
        [track setTrackStatus:TrackStatusQueued];
    }

    [[self tableView] reloadData];
    [self _didModifyTracks];
}


- (Track *) trackAtIndex:(NSUInteger)index
{
    if (index < [_tracks count]) {
        return [_tracks objectAtIndex:index];
    }

    return nil;
}


- (void) detectDuplicates
{
    NSUInteger tracksCount = [_tracks count];

    NSMutableDictionary *urlToTrackMap   = [NSMutableDictionary dictionaryWithCapacity:tracksCount];
    NSMutableDictionary *titleToTrackMap = [NSMutableDictionary dictionaryWithCapacity:tracksCount];

    DuplicateStatusMode duplicateStatusMode = [[Preferences sharedInstance] duplicateStatusMode];

    BOOL (^check)(NSMutableDictionary *, id, Track *) = ^(NSMutableDictionary *map, id key, Track *track) {
        if (key) {
            Track *existingTrack = [map objectForKey:key];

            [map setObject:track forKey:key];

            if (existingTrack) {
                [existingTrack setDuplicate:YES];
                return YES;
            }
        }
        
        return NO;
    };

    for (Track *track in _tracks) {
        BOOL isDuplicate = NO;

        if (duplicateStatusMode == DuplicateStatusModeSameTitle) {
            isDuplicate = isDuplicate || check(titleToTrackMap, [track title], track);

        } else if (duplicateStatusMode == DuplicateStatusModeSimilarTitle) {
            isDuplicate = isDuplicate || check(titleToTrackMap, [track titleForSimilarTitleDetection], track);
        }

        isDuplicate = isDuplicate || check(urlToTrackMap, [track externalURL], track);
    
        [track setDuplicate:isDuplicate];
    }
}


#pragma mark - Accessors

- (NSTimeInterval) modificationTime
{
    return [[NSUserDefaults standardUserDefaults] doubleForKey:sModifiedAtKey];
}


@end
