// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "TrackTableView.h"
#import "TrackTableCellView.h"
#import "Preferences.h"
#import "TracksController.h"
#import "SetlistController.h"


extern NSColor * const TrackTableViewGetPlayingTextColor(void)
{
    BOOL darkAqua = IsAppearanceDarkAqua(nil);

    NSColor *color = [[NSColor selectedContentBackgroundColor] colorUsingType:NSColorTypeComponentBased];
    
    CGFloat saturation = 0;
    
    if ([[color colorSpace] colorSpaceModel] == NSColorSpaceModelRGB) {
        [color getHue:NULL saturation:&saturation brightness:NULL alpha:NULL];
    }

    if (saturation > 0.1) {
        if (darkAqua) {
            return [[NSColor whiteColor] blendedColorWithFraction:0.5 ofColor:color];
        } else {
            return [[NSColor blackColor] blendedColorWithFraction:0.9 ofColor:color];
        }
    }
    
    return [NSColor colorNamed:@"SetlistPlayingText"];
}


extern NSColor * const TrackTableViewGetRowHighlightColor(BOOL emphasized)
{
    if (emphasized) {
        return [NSColor selectedContentBackgroundColor];
    } else {
        return [NSColor unemphasizedSelectedContentBackgroundColor];
    }
}


@implementation TrackTableView {
    NSHashTable       *_cellsWithMouseInside;
    NSMutableIndexSet *_rowsNeedingUpdatedHeight;

    BOOL _dragInside;
    BOOL _inLocalDrag;
}


- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (void) awakeFromNib
{
    [super awakeFromNib];

    [self setTarget:nil];
    [self setDoubleAction:@selector(playSelectedTrack:)];
}


- (void) viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    _rowWithMouseInside = NSNotFound;
}


- (void) keyDown:(NSEvent *)event
{
    NSUInteger modifiers =
        NSEventModifierFlagCommand |
        NSEventModifierFlagOption  |
        NSEventModifierFlagControl ;

    NSString *characters = [event charactersIgnoringModifiers];
    unichar character = [characters length] ? [characters characterAtIndex:0] : 0;

    BOOL isReturn = (character == NSCarriageReturnCharacter) || (character == NSEnterCharacter);
    BOOL isDelete = (character == NSDeleteCharacter)          || (character == NSBackspaceCharacter);

    if (([event modifierFlags] & modifiers) == 0) {
        if (isReturn && [NSApp sendAction:@selector(playSelectedTrack:) to:nil from:self]) {
            return;
        }

        if (isDelete && [NSApp sendAction:@selector(delete:) to:nil from:self]) {
            return;
        }
    }

    [super keyDown:event];
}


- (NSMenu *) menuForEvent:(NSEvent *)theEvent
{
    NSEventType type = [theEvent type];
    
    if (type == NSEventTypeRightMouseDown || type == NSEventTypeRightMouseUp ||
        type == NSEventTypeLeftMouseDown  || type == NSEventTypeLeftMouseUp  ||
        type == NSEventTypeOtherMouseDown || type == NSEventTypeOtherMouseUp)
    {
        NSPoint location = [theEvent locationInWindow];
        
        location = [self convertPoint:location fromView:nil];
        NSInteger row = [self rowAtPoint:location];
        
        if ([[self selectedRowIndexes] containsIndex:row]) {
            return [self menu];

        } else if (row >= 0) {
            [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
            return [self menu];

        } else {
            [self deselectAll:self];
            return nil;
        }
    }

    return [super menuForEvent:theEvent];
}


#pragma mark - Private Methods

- (void) _dispatchHeightUpdate
{
    if ([_rowsNeedingUpdatedHeight count]) {
        [self beginUpdates];

        [self enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
            [[rowView viewAtColumn:0] setExpandedPlayedTrack:(row == _rowWithMouseInside)];
        }];

        [self noteHeightOfRowsWithIndexesChanged:_rowsNeedingUpdatedHeight];
        [self endUpdates];
    }

    _rowsNeedingUpdatedHeight = nil;
}


- (void) _trackTableViewCell:(TrackTableCellView *)cellView mouseInside:(BOOL)mouseInside
{
    if (!_cellsWithMouseInside) {
        _cellsWithMouseInside = [NSHashTable weakObjectsHashTable];
    }

    if (!_rowsNeedingUpdatedHeight) {
        _rowsNeedingUpdatedHeight = [NSMutableIndexSet indexSet];
    }

    NSInteger row = [self rowForView:cellView];
    if (row != NSNotFound) {
        [_rowsNeedingUpdatedHeight addIndex:row];
    }
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_dispatchHeightUpdate) object:nil];
    [self performSelector:@selector(_dispatchHeightUpdate) withObject:nil afterDelay:0.25];

    if (mouseInside) {
        [_cellsWithMouseInside addObject:cellView];
    } else {
        [_cellsWithMouseInside removeObject:cellView];
    }

    NSInteger rowWithMouseInside = _rowWithMouseInside;
    NSInteger count = [_cellsWithMouseInside count];

    if (count == 1) {
        rowWithMouseInside = [self rowForView:[_cellsWithMouseInside anyObject]];
    } else if (count == 0) {
        rowWithMouseInside = NSNotFound;
    }

    _rowWithMouseInside = rowWithMouseInside;
}


- (void) drawGridInClipRect:(NSRect)clipRect
{
    PerformWithAppearance([self effectiveAppearance], ^{
        [[NSColor controlBackgroundColor] set];
        [[NSBezierPath bezierPathWithRect:clipRect] fill];
    });
}


#pragma mark - Dragging

- (void) _updateDrag
{
    id delegate = [self delegate];

    if ([delegate respondsToSelector:@selector(trackTableView:isModifyingViaDrag:)]) {
        [delegate trackTableView:self isModifyingViaDrag:(_inLocalDrag || _dragInside)];
    }
}


- (void) draggingSession:(NSDraggingSession *)session willBeginAtPoint:(NSPoint)screenPoint
{
    if ([[NSTableView class] instancesRespondToSelector:@selector(draggingSession:willBeginAtPoint:)]) {
        [super draggingSession:session willBeginAtPoint:screenPoint];
    }

    _inLocalDrag = YES;
    [self _updateDrag];
}


- (NSDragOperation) draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
    if (context == NSDraggingContextOutsideApplication) {
        return NSDragOperationDelete;
    }
    
    return NSDragOperationCopy|NSDragOperationGeneric;
}


- (NSImage *) dragImageForRowsWithIndexes:(NSIndexSet *)dragRows tableColumns:(NSArray *)tableColumns event:(NSEvent *)dragEvent offset:(NSPointPointer)dragImageOffset
{
    return [NSImage imageNamed:@"DragIcon"];
}


- (NSDragOperation) draggingEntered:(id <NSDraggingInfo>)sender;
{
    NSDragOperation result = [super draggingEntered:sender];

    _dragInside = YES;
    [self _updateDrag];

    return result;
}


- (void) draggingExited:(id <NSDraggingInfo>)sender
{
    if ([[NSTableView class] instancesRespondToSelector:@selector(draggingExited:)]) {
        [super draggingExited:sender];
    }

    _dragInside = NO;
    [self _updateDrag];
}


- (void) draggingEnded:(id <NSDraggingInfo>)sender
{
    if ([[NSTableView class] instancesRespondToSelector:@selector(draggingEnded:)]) {
        [super draggingEnded:sender];
    }
    
    _dragInside = NO;
    _inLocalDrag = NO;
    [self _updateDrag];
}


- (void) concludeDragOperation:(id<NSDraggingInfo>)sender
{
    if ([[NSTableView class] instancesRespondToSelector:@selector(concludeDragOperation:)]) {
        [super concludeDragOperation:sender];
    }

    _dragInside = NO;
    _inLocalDrag = NO;
    [self _updateDrag];
}


- (void) draggingSession:(NSDraggingSession *)session movedToPoint:(NSPoint)screenPoint
{
    NSRect frame = [[self window] frame];

    BOOL isLockedTrack = [[session draggingPasteboard] dataForType:EmbraceLockedTrackPasteboardType] != nil;

    if (NSPointInRect(screenPoint, frame)) {
        [session setAnimatesToStartingPositionsOnCancelOrFail:YES];

    } else {
        if (isLockedTrack) {
            [[NSCursor operationNotAllowedCursor] set];
            [session setAnimatesToStartingPositionsOnCancelOrFail:YES];

        } else {
            [[NSCursor disappearingItemCursor] set];
            [session setAnimatesToStartingPositionsOnCancelOrFail:NO];
        }
    }
}


@end
