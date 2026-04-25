// (c) 2018-2026 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <AppKit/AppKit.h>


@interface InnerShadowView : NSView

// Either NSLayoutAttributeTop or NSLayoutAttributeBottom, edge where inner shadow comes from
@property (nonatomic) NSLayoutAttribute layoutAttribute;

@end
