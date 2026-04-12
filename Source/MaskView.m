// (c) 2018-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "MaskView.h"

@interface MaskColorView : NSView
@property (nonatomic, weak) MaskView *parentView;
@end


static void sDrawGradient(NSRect rect, NSColor *color, NSLayoutAttribute attribute, CGFloat length)
{
    if (!color) return;

    CGPoint startPoint = CGPointZero;
    CGPoint endPoint   = CGPointZero;
    
    if (attribute == NSLayoutAttributeRight) {
        startPoint = CGPointMake(CGRectGetMaxX(rect),   0);
        endPoint   = CGPointMake(startPoint.x - length, 0);

    } else {
        startPoint = CGPointMake(CGRectGetMinX(rect),   0);
        endPoint   = CGPointMake(startPoint.x + length, 0);
    }
    
    NSRectClip(rect);

    [[[NSGradient alloc] initWithColors:@[
        [NSColor clearColor],
        [NSColor blackColor]
    ]] drawFromPoint:startPoint toPoint:endPoint options:NSGradientDrawsAfterEndingLocation];
    
    [color set];
    NSRectFillUsingOperation(rect, NSCompositingOperationSourceIn);
}


@implementation MaskView {
    NSVisualEffectView *_effectView;
    MaskColorView *_colorView;
    NSImage *_maskImage;
}


- (instancetype) initWithFrame:(NSRect)frameRect
{
    if ((self = [super initWithFrame:frameRect])) {
        [self _commonMaskViewInit];
    }

    return self;
}


- (instancetype) initWithCoder:(NSCoder *)decoder
{
    if ((self = [super initWithCoder:decoder])) {
        [self _commonMaskViewInit];
    }

    return self;
}


- (void) _commonMaskViewInit
{
    _colorView = [[MaskColorView alloc] initWithFrame:[self bounds]];
    [_colorView setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
    [_colorView setParentView:self];

    [self addSubview:_colorView];
}


- (void) _update
{
    if (_material) {
        if (!_effectView) {
            _effectView = [[NSVisualEffectView alloc] initWithFrame:[self bounds]];

            [_effectView setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
            [_effectView setBlendingMode:NSVisualEffectBlendingModeWithinWindow];
            
            [self addSubview:_effectView positioned:NSWindowBelow relativeTo:_colorView];
        }
        
        if (!_maskImage) {
            if (_gradientLength) {
                NSLayoutAttribute attribute = _gradientLayoutAttribute;
                CGFloat           length    = _gradientLength;
                
                CGRect rect = CGRectMake(0, 0, length + 2, 8);

                CGImageRef cgImage = CreateImage(rect.size, NO, 1, ^(CGContextRef context) {
                    sDrawGradient(rect, [NSColor blackColor], attribute, length);
                });

                NSImage *maskImage = [[NSImage alloc] initWithCGImage:cgImage size:rect.size];
                
                if (attribute == NSLayoutAttributeLeft) {
                    [maskImage setCapInsets:NSEdgeInsetsMake(1, length, 1, 1)];
                } else {
                    [maskImage setCapInsets:NSEdgeInsetsMake(0, 1, 0, length)];
                }

                CGImageRelease(cgImage);

                [_effectView setMaskImage:maskImage];
                _maskImage = maskImage;

            } else {
                [_effectView setMaskImage:nil];
            }
        }

        [_effectView setMaterial:_material];
        [_effectView setEmphasized:_emphasized];
        [_effectView setHidden:NO];
        [_colorView setHidden:YES];

    } else {
        [_effectView setHidden:YES];
        [_colorView setHidden:NO];
        [_colorView setNeedsDisplay:YES];
    }
}


- (void) setMaterial:(NSVisualEffectMaterial)material
{
    if (_material != material) {
        _material = material;
        [self _update];
    }
}


- (void) setEmphasized:(BOOL)emphasized
{
    if (_emphasized != emphasized) {
        _emphasized = emphasized;
        [self _update];
    }
}


- (void) setColor:(NSColor *)color
{
    if (_color != color) {
        _color = color;
        [self _update];
    }
}


- (void) setGradientLength:(CGFloat)gradientLength
{
    if (_gradientLength != gradientLength) {
        _gradientLength = gradientLength;
        _maskImage = nil;
        [self _update];
    }
}


- (void) setGradientLayoutAttribute:(NSLayoutAttribute)gradientLayoutAttribute
{
    if (_gradientLayoutAttribute != gradientLayoutAttribute) {
        _gradientLayoutAttribute = gradientLayoutAttribute;
        _maskImage = nil;
        [self _update];
    }
}


@end


@implementation MaskColorView

- (void) drawRect:(NSRect)dirtyRect
{
    MaskView *parentView = [self parentView];

    sDrawGradient(
        [self bounds],
        [parentView color],
        [parentView gradientLayoutAttribute],
        [parentView gradientLength]
    );
}

@end

