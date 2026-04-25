// (c) 2018-2026 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "HairlineView.h"


@implementation HairlineView


- (void) viewDidChangeEffectiveAppearance
{
    [self setNeedsDisplay:YES];
}


- (void) drawRect:(NSRect)dirtyRect
{
    CGFloat scale    = [[self window] backingScaleFactor];
    CGFloat onePixel = scale > 1 ? 0.5 : 1;
    CGRect  rect     = GetInsetBounds(self);

    rect.origin.y =  (_layoutAttribute == NSLayoutAttributeTop) ?
        rect.size.height - onePixel :
        0;

    rect.size.height = onePixel;

    [[NSColor colorNamed:@"SetlistHairlineColor"] set];
    NSRectFill(rect);
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
