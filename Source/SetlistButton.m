// (c) 2014-2026 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "SetlistButton.h"
#import "NoDropImageView.h"
#import "Preferences.h"

static CGFloat sBorderLayerPadding = 2;

  
typedef NS_ENUM(NSInteger, SetlistButtonStyle) {
    SetlistButtonStyleNone         = 0,
    SetlistButtonStyleNormal       = 1,
    SetlistButtonStylePressed      = 2,
    SetlistButtonStyleInactive     = 3,
    SetlistButtonStyleDisabled     = 4,
    SetlistButtonStyleAlertPressed = 5,
    SetlistButtonStyleAlert        = 6
};


@interface SetlistButtonBorderView : NSView <CALayerDelegate, NSViewLayerContentScaleDelegate> 
- (void) performAnimate:(BOOL)orderIn;
@end


@interface SetlistButtonIconView : NSView <CALayerDelegate, NSViewLayerContentScaleDelegate> 

- (void) performZoomAnimationToIcon:(SetlistButtonIcon)toIcon style:(SetlistButtonStyle)toStyle;
- (void) performJumpAnimationToIcon:(SetlistButtonIcon)toIcon style:(SetlistButtonStyle)toStyle;
- (void) performFadeAnimationToIcon:(SetlistButtonIcon)toIcon style:(SetlistButtonStyle)toStyle;

@property (nonatomic) SetlistButtonIcon icon;
@property (nonatomic) SetlistButtonStyle style;

@end



@implementation SetlistButton {
    BOOL                     _highlighted;
    SetlistButtonIconView   *_iconView;
    SetlistButtonBorderView *_borderView;
    
    NSImageView       *_backgroundView;
    SetlistButtonStyle _backgroundStyle;
}


- (id) initWithFrame:(NSRect)frameRect
{
    if ((self = [super initWithFrame:frameRect])) {
        [self _commonSetlistButtonInit];
    }

    return self;
}


- (id) initWithCoder:(NSCoder *)aDecoder
{
    if ((self = [super initWithCoder:aDecoder])) {
        [self _commonSetlistButtonInit];
    }

    return self;
}


- (void) _commonSetlistButtonInit
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_update:) name:NSWindowDidBecomeMainNotification        object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_update:) name:NSApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_update:) name:NSApplicationDidResignActiveNotification object:nil];
    
    CGRect bounds = [self bounds];

    _backgroundView = [[NoDropImageView alloc] initWithFrame:[self bounds]];
    [self addSubview:_backgroundView];

    [_backgroundView setImageScaling:NSImageScaleNone];

    _iconView = [[SetlistButtonIconView alloc] initWithFrame:bounds];
    [self addSubview:_iconView];

    [self setWantsLayer:YES];
    [self setLayer:[CALayer layer]];
    [[self layer] setMasksToBounds:NO];
    [self setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawNever];
    [self setAutoresizesSubviews:NO];
    
    [self setButtonType:NSButtonTypeMomentaryChange];
    
    [self _update:nil];
}


- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (void) layout
{
    [_iconView setFrame:[self bounds]];
}


- (void) mouseDown:(NSEvent *)theEvent
{
    _highlighted = YES;
    [self _update:nil];

    [super mouseDown:theEvent];

    _highlighted = NO;
    [self _update:nil];
}


- (void) viewDidChangeEffectiveAppearance
{
    PerformWithAppearance([self effectiveAppearance], ^{
        [self _update:nil];
    });
}


- (void) viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self _update:nil];
}


- (void) windowDidUpdateMain:(NSWindow *)window
{
    [self _update:nil];
}


- (void) _update:(NSNotification *)note
{
    SetlistButtonStyle style = SetlistButtonStyleNormal;
    SetlistButtonStyle backgroundStyle = SetlistButtonStyleNormal;

    SetlistButtonIcon icon = _icon;
    BOOL isInactive = ![[self window] isMainWindow] || ![NSApp isActive];

    if (![self isEnabled]) {
        style = SetlistButtonStyleDisabled;

    } else if (isInactive) {
        style = SetlistButtonStyleInactive;

    } else if (icon == SetlistButtonIconDeviceIssue || icon == SetlistButtonIconReallyStop) {
        style = _highlighted ? SetlistButtonStyleAlertPressed : SetlistButtonStyleAlert;

    } else if (_highlighted) {
        style = SetlistButtonStylePressed;
    }
    
    if (isInactive) {
        backgroundStyle = SetlistButtonStyleInactive;
    } else if (_highlighted) {
        backgroundStyle = SetlistButtonStylePressed;
    }

    [_iconView setIcon:[self icon]];
    [_iconView setStyle:style];
    
    if (_backgroundStyle != backgroundStyle) {
        if (backgroundStyle == SetlistButtonStyleInactive) {
            [_backgroundView setImage:[NSImage imageNamed:@"SetlistButtonInactive"]];
        } else if (backgroundStyle == SetlistButtonStylePressed) {
            [_backgroundView setImage:[NSImage imageNamed:@"SetlistButtonPressed"]];
        } else {
            [_backgroundView setImage:[NSImage imageNamed:@"SetlistButtonNormal"]];
        }
        
        _backgroundStyle = backgroundStyle;
    }
}


- (void) setEnabled:(BOOL)flag
{
    [super setEnabled:flag];
    [self _update:nil];
}


- (void) drawRect:(NSRect)dirtyRect
{ }


- (void) setOutlined:(BOOL)outlined
{
    if (outlined != _outlined) {
        if (outlined && !_borderView) {
            CGRect borderFrame = CGRectInset([self bounds], 0, 2);
            _borderView = [[SetlistButtonBorderView alloc] initWithFrame:borderFrame];
            [self addSubview:_borderView];
        }
    
        _outlined = outlined;
        [_borderView performAnimate:outlined];
    }
}


- (void) setIcon:(SetlistButtonIcon)icon animated:(BOOL)animated
{
    if (animated) {
        if (icon == SetlistButtonIconReallyStop) {
            [_iconView performJumpAnimationToIcon:SetlistButtonIconReallyStop style:SetlistButtonStyleAlert];
        } else if (icon == SetlistButtonIconStop) {
            [_iconView performFadeAnimationToIcon:SetlistButtonIconStop style:SetlistButtonStyleNormal];
        } else if (icon == SetlistButtonIconPlay) {
            [_iconView performZoomAnimationToIcon:SetlistButtonIconPlay style:SetlistButtonStyleNormal];
        }
    }

    if (_icon != icon) {
        _icon = icon;
        [self _update:nil];
    }
}


- (void) setIcon:(SetlistButtonIcon)icon
{
    if (_icon != icon) {
        _icon = icon;
        [self _update:nil];
    }
}


@end


@implementation SetlistButtonBorderView {
    CALayer *_mainLayer;
}


- (id) initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _mainLayer = [CALayer layer];
        
        [_mainLayer setMasksToBounds:NO];
        [_mainLayer setDelegate:self];

        [self setWantsLayer:YES];
        [self setLayer:[CALayer layer]];
        [self setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawNever];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handlePreferencesDidChange:) name:PreferencesDidChangeNotification object:nil];

        CALayer *selfLayer = [self layer];

        [selfLayer setMasksToBounds:NO];
        [selfLayer addSublayer:_mainLayer];
    }

    return self;
}


- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (void) layout
{
    [_mainLayer setFrame:CGRectInset([self bounds], -sBorderLayerPadding, -sBorderLayerPadding)];
}


- (BOOL) wantsUpdateLayer
{
    return YES;
}


- (void) performAnimate:(BOOL)orderIn
{
    CABasicAnimation *frameAnimation   = [CABasicAnimation animationWithKeyPath:@"bounds"];
    CABasicAnimation *opacityAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];

    CGRect bounds = [self bounds];
    CGRect outRect = CGRectInset(bounds, -8, -8);
    CGRect inRect  = CGRectInset(bounds, -sBorderLayerPadding, -sBorderLayerPadding);

    CGFloat duration = 0.2;

    [opacityAnimation setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];

    if (orderIn) {
        [opacityAnimation setFromValue:@0.0];
        [opacityAnimation setToValue:@1.0];

        [frameAnimation setFromValue:[NSValue valueWithRect:outRect]];
        [frameAnimation setToValue:  [NSValue valueWithRect:inRect]];

        [frameAnimation setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];

        [frameAnimation setDuration:duration];
        [opacityAnimation setDuration:duration];

        [_mainLayer setOpacity:1];

    } else {
        CALayer *presentationLayer = [_mainLayer presentationLayer];

        CGFloat currentOpacity = [presentationLayer opacity];
        CGRect  currentBounds  = [presentationLayer bounds];
        
        duration = duration - ((1.0 - currentOpacity) * duration);

        [opacityAnimation setFromValue:@(currentOpacity)];
        [opacityAnimation setToValue:@0.0];

        [frameAnimation setFromValue:[NSValue valueWithRect:currentBounds]];
        [frameAnimation setToValue:[NSValue valueWithRect:outRect]];
        [frameAnimation setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn]];

        [frameAnimation   setDuration:duration];
        [opacityAnimation setDuration:duration];
        
        [_mainLayer setOpacity:0];
    }
    
    [_mainLayer addAnimation:frameAnimation   forKey:@"frame"];
    [_mainLayer addAnimation:opacityAnimation forKey:@"opacity"];
}



- (void) updateLayer { }


- (NSColor *) _glowColor
{
    BOOL darkAqua = IsAppearanceDarkAqua(nil);

    NSColor *color = [[NSColor selectedContentBackgroundColor] colorUsingType:NSColorTypeComponentBased];
    
    if (darkAqua) {
        return [[NSColor whiteColor] blendedColorWithFraction:0.5 ofColor:color];
    } else {
        return color;
    }
}


- (void) _updateMainLayerContentsWithScale:(CGFloat)scale
{
    CGSize imageSize = CGSizeMake(32, 32);

    CGImageRef mainImage = CreateImage(imageSize, NO, scale, ^(CGContextRef context) {
        NSRect bounds = CGRectMake(0, 0, 32, 32);
        bounds = CGRectInset(bounds, sBorderLayerPadding + 1, sBorderLayerPadding + 1);
                
        [[self _glowColor] set];
        
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:4.5 yRadius:4.5];
        [path setLineWidth:2];
        [path stroke];
    });

    [_mainLayer setContents:(__bridge id)mainImage];
    [_mainLayer setContentsCenter:CGRectMake(0.5, 0.5, 0, 0)];
    [_mainLayer setContentsScale:scale];

    CGImageRelease(mainImage);
}


- (void) viewDidMoveToWindow
{
    [self _updateMainLayerContentsWithScale:[[self window] backingScaleFactor]];
}


- (void) viewDidChangeEffectiveAppearance
{
    [self _updateMainLayerContentsWithScale:[[self window] backingScaleFactor]];
}


- (void) _handlePreferencesDidChange:(NSNotification *)note
{
    [self _updateMainLayerContentsWithScale:[[self window] backingScaleFactor]];
}


- (BOOL) layer:(CALayer *)layer shouldInheritContentsScale:(CGFloat)newScale fromWindow:(NSWindow *)window
{
    if (layer == _mainLayer) {
        [self _updateMainLayerContentsWithScale:newScale];
    }

    return NO;
}


@end


@implementation SetlistButtonIconView {
    CALayer *_backgroundLayer;
    CALayer *_mainLayer;
    CALayer *_auxLayer;

    SetlistButtonIcon  _auxIcon;
    SetlistButtonStyle _auxStyle;
}


- (id) initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _backgroundLayer = [CALayer layer];
        _mainLayer = [CALayer layer];
        _auxLayer  = [CALayer layer];
        
        [_backgroundLayer setBackgroundColor:[[NSColor redColor] CGColor]];
        [_backgroundLayer setCornerCurve:kCACornerCurveContinuous];
        [_backgroundLayer setCornerRadius:6];
        
        [_backgroundLayer setMasksToBounds:NO];
        [_mainLayer setMasksToBounds:NO];
        [_auxLayer  setMasksToBounds:NO];

        [_backgroundLayer setDelegate:self];
        [_mainLayer setDelegate:self];
        [_auxLayer  setDelegate:self];
        
        [_mainLayer setContentsGravity:kCAGravityLeft];
        [_auxLayer  setContentsGravity:kCAGravityLeft];

        [_mainLayer setNeedsDisplayOnBoundsChange:YES];
        [_auxLayer  setNeedsDisplayOnBoundsChange:YES];
        
        [_auxLayer setHidden:YES];

        [self setWantsLayer:YES];
        [self setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawNever];
        
        [[self layer] addSublayer:_backgroundLayer];
        [[self layer] addSublayer:_mainLayer];
        [[self layer] setMasksToBounds:NO];

        NSTrackingAreaOptions options = 
            NSTrackingMouseEnteredAndExited |
            NSTrackingActiveInKeyWindow     |
            NSTrackingInVisibleRect;
        
        NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:[self bounds] options:options owner:self userInfo:nil];
        [self addTrackingArea:area];
    }

    return self;
}


- (BOOL) wantsUpdateLayer
{
    return YES;
}


- (void) updateLayer { }



- (void) viewDidChangeEffectiveAppearance
{
    [_mainLayer setNeedsDisplay];
}


- (void) layout
{
    [super layout];
    
    NSRect bounds = [self bounds];
   
    NSRect mainFrame = bounds;
    NSRect auxFrame  = bounds;

    NSImage *image    = [self _templateImageWithIcon:_icon];
    NSImage *auxImage = [self _templateImageWithIcon:_auxIcon];

    mainFrame.size = image ? [image size] : NSZeroSize;
    mainFrame.origin.x = round((bounds.size.width  - mainFrame.size.width)  / 2);
    mainFrame.origin.y = round((bounds.size.height - mainFrame.size.height) / 2);
    
    [_mainLayer setFrame:mainFrame];

    auxFrame.size = auxImage ? [auxImage size] : NSZeroSize;
    auxFrame.origin.x = round((bounds.size.width  - auxFrame.size.width)  / 2);
    auxFrame.origin.y = round((bounds.size.height - auxFrame.size.height) / 2);

    [_auxLayer setFrame:auxFrame];
}


- (void) _drawLayer:(CALayer *)layer icon:(SetlistButtonIcon)icon style:(SetlistButtonStyle)style inContext:(CGContextRef)context
{
    NSGraphicsContext *oldContext = [NSGraphicsContext currentContext];
    
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:context flipped:NO]];

    NSRect bounds = [layer bounds];
    
    NSImage *image = [self _templateImageWithIcon:icon];
    
    NSRect rect = NSZeroRect;
    rect.size = [image size];
    rect.origin.x = 0;
    rect.origin.y = round((bounds.size.height - rect.size.height) / 2);
    
    [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    
    [[self _colorWithStyle:style] set];
    NSRectFillUsingOperation(bounds, NSCompositingOperationSourceIn);
    
    [NSGraphicsContext setCurrentContext:oldContext];
}


- (void) _inheritContentsScaleFromWindow:(NSWindow *)window
{
    CGFloat scale = [window backingScaleFactor];
    
    if (scale) {
        [_mainLayer setContentsScale:scale];
        [_auxLayer  setContentsScale:scale];
    }
}


- (void) drawLayer:(CALayer *)layer inContext:(CGContextRef)ctx
{
    PerformWithAppearance([self effectiveAppearance], ^{
        if (layer == _mainLayer) {
            [self _drawLayer:layer icon:_icon style:_style inContext:ctx];
        
        } else if (layer == _auxLayer) {
            [self _drawLayer:layer icon:_auxIcon style:_auxStyle inContext:ctx];
        }
    });
}


- (void) viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self _inheritContentsScaleFromWindow:[self window]];
}


- (BOOL) layer:(CALayer *)layer shouldInheritContentsScale:(CGFloat)newScale fromWindow:(NSWindow *)window
{
    [self _inheritContentsScaleFromWindow:window];
    return YES;
}


#pragma mark - Animations

- (void) _performJumpOrFadeAnimationToIcon:(SetlistButtonIcon)toIcon style:(SetlistButtonStyle)toStyle isJump:(BOOL)isJump
{
    CABasicAnimation    *contentsAnimation  = [CABasicAnimation    animationWithKeyPath:@"contents"];
    CAKeyframeAnimation *transformAnimation = [CAKeyframeAnimation animationWithKeyPath:@"transform"];

    CABasicAnimation    *mainHiddenAnimation = [CABasicAnimation animationWithKeyPath:@"hidden"];
    CABasicAnimation    *auxHiddenAnimation  = [CABasicAnimation animationWithKeyPath:@"hidden"];
    
    [mainHiddenAnimation setFromValue:@YES];
    [mainHiddenAnimation setToValue:@YES];

    [auxHiddenAnimation setFromValue:@NO];
    [auxHiddenAnimation setToValue:@NO];

    SetlistButtonIcon  fromIcon  = _icon;
    SetlistButtonStyle fromStyle = _style;

    PerformWithAppearance([self effectiveAppearance], ^{
        [contentsAnimation setFromValue:[self _imageWithIcon:fromIcon style:fromStyle]];
        [contentsAnimation setToValue:  [self _imageWithIcon:toIcon   style:toStyle]];
    });

    if (isJump) {
        CATransform3D popTransform = CATransform3DIdentity;

        NSPoint globalPoint = [NSEvent mouseLocation];
    
        NSRect  globalRect  = NSMakeRect(globalPoint.x, globalPoint.y, 0, 0);
        
        NSRect  windowRect = [[self window] convertRectFromScreen:globalRect];
        NSPoint windowPoint = windowRect.origin;

        NSPoint locationInSelf = [self convertPoint:windowPoint fromView:nil];
        CGFloat jumpY = ceil(locationInSelf.y);

        if (jumpY <  0) jumpY = 0;
        if (jumpY > 14) jumpY = 14;

        if (!NSPointInRect(locationInSelf, [self bounds])) {
            jumpY = 0;
        }
        
        popTransform = CATransform3DRotate(popTransform, 0.01 * M_PI, 0, 0, 1);
        popTransform = CATransform3DScale(popTransform, 1.5, 1.5, 1);
        popTransform = CATransform3DTranslate(popTransform, 0, jumpY + 2, 1);

        [transformAnimation setValues:@[
            [NSValue valueWithCATransform3D:CATransform3DMakeScale(1, 1, 1)],
            [NSValue valueWithCATransform3D:popTransform],
            [NSValue valueWithCATransform3D:CATransform3DMakeScale(1, 1, 1)],
        ]];
        
        [transformAnimation setTimingFunctions:@[
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]
        ]];

        [transformAnimation setKeyTimes:@[ @0, @0.5, @1.0 ] ];

        [_auxLayer addAnimation:transformAnimation forKey:@"transform"];
    }

    [contentsAnimation setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];

    _auxIcon = [self icon];
    [[self layer] addSublayer:_auxLayer];
    
    [_auxLayer addAnimation:contentsAnimation  forKey:@"contents"];
    
    [_mainLayer addAnimation:mainHiddenAnimation forKey:@"hidden"];
    [_auxLayer  addAnimation:auxHiddenAnimation  forKey:@"hidden"];
}


- (void) performFadeAnimationToIcon:(SetlistButtonIcon)toIcon style:(SetlistButtonStyle)toStyle;
{
    [self _performJumpOrFadeAnimationToIcon:toIcon style:toStyle isJump:NO];
}


- (void) performJumpAnimationToIcon:(SetlistButtonIcon)toIcon style:(SetlistButtonStyle)toStyle
{
    [self _performJumpOrFadeAnimationToIcon:toIcon style:toStyle isJump:YES];
}


- (void) performZoomAnimationToIcon:(SetlistButtonIcon)toIcon style:(SetlistButtonStyle)toStyle
{
    _auxIcon  = [self icon];
    _auxStyle = [self style];
    [_auxLayer setNeedsDisplay];
    
    [self setIcon:toIcon];
    [self setStyle:toStyle];
    
    [[self layer] addSublayer:_auxLayer];

    CABasicAnimation *auxTransformAnimation  = [CABasicAnimation animationWithKeyPath:@"transform"];
    CABasicAnimation *mainTransformAnimation = [CABasicAnimation animationWithKeyPath:@"transform"];

    CABasicAnimation *auxOpacityAnimation  = [CABasicAnimation animationWithKeyPath:@"opacity"];
    CABasicAnimation *mainOpacityAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];

    CABasicAnimation *auxHiddenAnimation = [CABasicAnimation animationWithKeyPath:@"hidden"];

    [auxTransformAnimation  setFromValue:[NSValue valueWithCATransform3D:CATransform3DMakeScale(1,  1,  1)]];
    [auxTransformAnimation  setToValue:  [NSValue valueWithCATransform3D:CATransform3DMakeScale(3,  3,  1)]];
    [auxTransformAnimation setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn]];

    [mainTransformAnimation setFromValue:[NSValue valueWithCATransform3D:CATransform3DMakeScale(0.01,  0.01,  1)]];
    [mainTransformAnimation setToValue:  [NSValue valueWithCATransform3D:CATransform3DMakeScale(1,  1,  1)]];
    [mainTransformAnimation setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];

    [auxOpacityAnimation  setFromValue:@(1)];
    [auxOpacityAnimation  setToValue:  @(0)];
    
    [mainOpacityAnimation setFromValue:@(0)];
    [mainOpacityAnimation setToValue:  @(1)];
    
    [auxHiddenAnimation setFromValue:@NO];
    [auxHiddenAnimation setToValue:@NO];
    
    [_mainLayer addAnimation:mainTransformAnimation forKey:@"transform"];
    [_auxLayer  addAnimation:auxTransformAnimation  forKey:@"transform"];

    [_mainLayer addAnimation:mainOpacityAnimation forKey:@"opacity"];
    [_auxLayer  addAnimation:auxOpacityAnimation  forKey:@"opacity"];

    [_auxLayer  addAnimation:auxHiddenAnimation  forKey:@"hidden"];
}


#pragma mark - Private Methods

- (NSColor *) _colorWithStyle:(SetlistButtonStyle)style
{
    if (style == SetlistButtonStyleNormal) {
        return [NSColor colorNamed:@"ButtonNormal"];

    } else if (style == SetlistButtonStyleDisabled) {
        return [NSColor colorNamed:@"ButtonDisabled"];

    } else if (style == SetlistButtonStyleInactive) {
        return [NSColor colorNamed:@"ButtonInactive"];

    } else if (style == SetlistButtonStylePressed) {
        return [NSColor colorNamed:@"ButtonPressed"];

    } else if (style == SetlistButtonStyleAlertPressed) {
        return [NSColor colorNamed:@"ButtonAlertPressed"];

    } else if (style == SetlistButtonStyleAlert) {
        return [NSColor colorNamed:@"ButtonAlert"];
    }
    
    return nil;
}


- (NSImage *) _templateImageWithIcon:(SetlistButtonIcon)icon
{
    if (icon == SetlistButtonIconPlay) {
        return [NSImage imageNamed:@"PlayTemplate"];

    } else if (icon == SetlistButtonIconStop) {
        return [NSImage imageNamed:@"StopTemplate"];

    } else if (icon == SetlistButtonIconReallyStop) {
        return [NSImage imageNamed:@"ConfirmTemplate"];

    } else if (icon == SetlistButtonIconDeviceIssue) {
        return [NSImage imageNamed:@"DeviceIssueTemplate"];

    } else if (icon == SetlistButtonIconGear) {
        return [NSImage imageNamed:@"ActionTemplate"];
    }
    
    return nil;
}


- (NSImage *) _imageWithIcon:(SetlistButtonIcon)icon style:(SetlistButtonStyle)style
{
    NSImage *image = [self _templateImageWithIcon:icon];
    
    NSSize size = [image size];
    NSImage *result = [[NSImage alloc] initWithSize:size];
    
    [result lockFocus];

    NSRect rect = NSZeroRect;
    rect.size = size;

    [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    
    [[self _colorWithStyle:style] set];
    NSRectFillUsingOperation(rect, NSCompositingOperationSourceIn);
    
    [result unlockFocus];
    
    return result;
}


#pragma mark - Accessors

- (void) setIcon:(SetlistButtonIcon)icon
{
    if (_icon != icon) {
        _icon = icon;
        [self setNeedsLayout:YES];

        [_mainLayer setNeedsDisplay];
    }
}


- (void) setStyle:(SetlistButtonStyle)style
{
    if (_style != style) {
        _style = style;
        [self setNeedsLayout:YES];

        [_mainLayer setNeedsDisplay];
    }
}


@end
