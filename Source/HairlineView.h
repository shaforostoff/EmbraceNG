// (c) 2018-2026 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <AppKit/AppKit.h>


@interface HairlineView : NSView

@property (nonatomic) NSColor *borderColor;

// Either NSLayoutAttributeTop or NSLayoutAttributeBottom, edge where line is attached
@property (nonatomic) NSLayoutAttribute layoutAttribute;

@end
