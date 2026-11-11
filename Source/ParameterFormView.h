// (c) 2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>

// Lets a unit explain, reset and hide its own parameters without
// ParameterFormView knowing anything about that unit.  All are optional: a unit
// that implements none gets a plain form of every parameter with no help text
// and no reset.  A hidden parameter is one the unit keeps only so that old saved
// state still loads.
//
@protocol ParameterDescribing <NSObject>
@optional
- (AUValue) embrace_defaultValueForParameterAddress:(AUParameterAddress)address;
- (NSString *) embrace_helpTextForParameterAddress:(AUParameterAddress)address;
- (BOOL) embrace_isParameterHiddenAtAddress:(AUParameterAddress)address;
@end


// A label, slider and editable value field per parameter, for effects whose audio
// unit brings no view of its own; a Boolean parameter gets a checkbox instead.
// Double-clicking a slider returns that one parameter to its default.

@interface ParameterFormView : NSView

- (instancetype) initWithAudioUnit:(AUAudioUnit *)audioUnit;

// Picks the values back up after something outside the form changed them
- (void) reloadData;

@property (nonatomic, readonly) CGSize fittingSize;

@end
