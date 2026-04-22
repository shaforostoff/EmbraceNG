// (c) 2018-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "HairlineView.h"


@implementation HairlineView


- (void) drawRect:(NSRect)dirtyRect
{
    if (!_borderColor) return;

    CGFloat scale    = [[self window] backingScaleFactor];
    CGFloat onePixel = scale > 1 ? 0.5 : 1;
    CGRect  rect     = GetInsetBounds(self);

    rect.origin.y =  (_layoutAttribute == NSLayoutAttributeTop) ?
        rect.size.height - onePixel :
        0;

    rect.size.height = onePixel;

    [_borderColor set];
    NSRectFill(rect);
}


#pragma mark - Accessors

- (void) setBorderColor:(NSColor *)borderColor
{
    if (_borderColor != borderColor) {
        _borderColor = borderColor;
        [self setNeedsDisplay:YES];
    }
}


- (void) setLayoutAttribute:(NSLayoutAttribute)layoutAttribute
{
    if (_layoutAttribute != layoutAttribute) {
        _layoutAttribute = layoutAttribute;
        [self setNeedsDisplay:YES];
    }
}


@end
