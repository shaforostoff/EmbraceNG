// (c) 2018-2026 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "InnerShadowView.h"


@implementation InnerShadowView


- (void) drawRect:(NSRect)dirtyRect
{
    CGRect insetBounds = GetInsetBounds(self);
    NSRectClip(insetBounds);

    CGFloat scale    = [[self window] backingScaleFactor];
    CGFloat onePixel = scale > 1 ? 0.5 : 1;
    
    CGRect darkerRect  = insetBounds;
    CGRect lighterRect = insetBounds;

    darkerRect.size.height = lighterRect.size.height = onePixel;

    if (_layoutAttribute == NSLayoutAttributeTop) {
        darkerRect.origin.y  = CGRectGetMaxY(insetBounds) - onePixel;
        lighterRect.origin.y = darkerRect.origin.y - onePixel;

    } else if (_layoutAttribute == NSLayoutAttributeBottom) {
        darkerRect.origin.y = CGRectGetMinY(insetBounds);
        lighterRect.origin.y = darkerRect.origin.y + onePixel;
    }

    [[[NSColor blackColor] colorWithAlphaComponent:0.15] set];
    NSRectFill(darkerRect);

    if (scale >= 2) {
        [[[NSColor blackColor] colorWithAlphaComponent:0.05] set];
        NSRectFill(lighterRect);
    }
}


#pragma mark - Accessors

- (void) setLayoutAttribute:(NSLayoutAttribute)layoutAttribute
{
    if (_layoutAttribute != layoutAttribute) {
        _layoutAttribute = layoutAttribute;
        [self setNeedsDisplay:YES];
    }
}


@end
