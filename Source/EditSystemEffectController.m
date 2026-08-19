// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "EditSystemEffectController.h"
#import "Effect.h"
#import "EffectAdditions.h"
#import "EffectType.h"
#import "ParameterFormView.h"
#import <objc/runtime.h>

#import <CoreAudioKit/CoreAudioKit.h>

@interface EditSystemEffectController ()

@property (nonatomic, weak) IBOutlet NSToolbar *toolbar;

@property (nonatomic, weak) IBOutlet NSToolbarItem *modeToolbarItem;
@property (nonatomic, weak) IBOutlet NSSegmentedControl *modeControl;

@end


@implementation EditSystemEffectController {
    NSView *_effectView;
    NSViewController *_effectViewController;
    ParameterFormView *_parameterFormView;
    BOOL _inViewFrameCallback;
}


- (NSString *) windowNibName
{
    return @"EditSystemEffectWindow";
}


- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (void) windowDidLoad
{
    [super windowDidLoad];

    Effect *effect = [self effect];
    if (!effect) return;

    // Units with no view of their own -- ours, and any third-party effect that
    // ships without one -- get a form built from the parameter tree.
    if (![[effect audioUnit] providesUserInterface]) {
        _parameterFormView = [[ParameterFormView alloc] initWithAudioUnit:[effect audioUnit]];

        NSViewController *viewController = [[NSViewController alloc] init];
        [viewController setView:_parameterFormView];

        // Deferred for the same reason the audio unit path is: -contentLayoutRect
        // is only meaningful once the window and its toolbar have been laid out.
        __weak id weakFormSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakFormSelf _didReceiveViewController:viewController];
        });

        return;
    }

    __weak id weakSelf = self;

    [[effect audioUnit] requestViewControllerWithCompletionHandler:^(AUViewControllerBase *viewController) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf _didReceiveViewController:viewController];
        });
    }];
}


- (void) reloadData
{
    [_parameterFormView reloadData];
}


#pragma mark - Private Methods

- (void) _didReceiveViewController:(NSViewController *)vc
{
    // A unit can decline to supply one, and -addSubview:nil throws
    if (![vc view]) return;

    NSWindow *window = [self window];

    NSRect contentLayoutRect = [window contentLayoutRect];
        
    NSViewController *contentViewController = [self contentViewController];
    
    [contentViewController addChildViewController:vc];
    
    NSView *effectView = [vc view];
    _effectView = effectView;
    _effectViewController = vc;
    
    NSRect effectViewFrame = [_effectView frame];

    NSRect newWindowFrame = [window frame];
    newWindowFrame.size.width  += (effectViewFrame.size.width  - contentLayoutRect.size.width);
    newWindowFrame.size.height += (effectViewFrame.size.height - contentLayoutRect.size.height);

    NSAutoresizingMaskOptions oldAutoresizingMask = [_effectView autoresizingMask];
    
    if ((oldAutoresizingMask & (NSViewWidthSizable|NSViewHeightSizable)) == 0) {
        NSWindowStyleMask styleMask = [[self window] styleMask];
        styleMask &= ~NSWindowStyleMaskResizable;
        [window setStyleMask:styleMask];
    }   
    
    [_effectView setAutoresizingMask:0];
    [window setFrame:newWindowFrame display:NO animate:NO];

    [_effectView setFrame:[[self window] contentLayoutRect]];
    [_effectView setAutoresizingMask:oldAutoresizingMask];

    [[[self window] contentView] addSubview:_effectView];

    [self _tweakView:_effectView];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleViewFrameDidChange:) name:NSViewFrameDidChangeNotification object:_effectView];
}


- (void) _tweakView:(NSView *)view
{
    Class AppleAUCustomViewBase   = NSClassFromString(@"AppleAUCustomViewBase");
    Class CAAppleAUCustomViewBase = NSClassFromString(@"CAAppleAUCustomViewBase");

    if ((  AppleAUCustomViewBase && [view isKindOfClass:  AppleAUCustomViewBase]) ||
        (CAAppleAUCustomViewBase && [view isKindOfClass:CAAppleAUCustomViewBase]))
    {
        for (NSView *subview in [view subviews]) {
            if ([subview isKindOfClass:[NSTextField class]]) {
                if ([[(NSTextField *)subview font] pointSize] >= 16) {
                    [subview setHidden:YES];
                }
            }
        }
    }
}


- (void) _resizeWindowWithOldSize:(NSSize)oldSize newSize:(NSSize)newSize
{
    CGFloat deltaW = newSize.width  - oldSize.width;
    CGFloat deltaH = newSize.height - oldSize.height;

    NSRect windowFrame = [[self window] frame];
    windowFrame.size.width  += deltaW;
    windowFrame.size.height += deltaH;
    windowFrame.origin.y -= deltaH;

    [_effectView setAutoresizingMask:0];
    [[self window] setFrame:windowFrame display:NO animate:NO];
    [_effectView setFrame:[[[self window] contentView] bounds]];
    [_effectView setAutoresizingMask:NSViewHeightSizable|NSViewWidthSizable];
}


- (void) _handleViewFrameDidChange:(NSNotification *)note
{
    if (!_inViewFrameCallback && ![[self window] inLiveResize]) {
        _inViewFrameCallback = YES;

        NSRect contentLayoutRect = [[self window] contentLayoutRect];
        NSRect effectViewFrame   = [_effectView frame];

        [self _resizeWindowWithOldSize:contentLayoutRect.size newSize:effectViewFrame.size];

        _inViewFrameCallback = NO;
    }
}

@end
