// (c) 2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>

// Lets a unit explain and reset its own parameters without ParameterFormView
// knowing anything about that unit.  Both are optional: a unit that implements
// neither gets a plain form with no help text and no reset.
//
@protocol ParameterDescribing <NSObject>
@optional
- (AUValue) embrace_defaultValueForParameterAddress:(AUParameterAddress)address;
- (NSString *) embrace_helpTextForParameterAddress:(AUParameterAddress)address;
@end


// A label, slider and editable value field per parameter, for effects whose audio
// unit brings no view of its own.  Double-clicking a slider returns that one
// parameter to its default.

@interface ParameterFormView : NSView

- (instancetype) initWithAudioUnit:(AUAudioUnit *)audioUnit;

// Picks the values back up after something outside the form changed them
- (void) reloadData;

@property (nonatomic, readonly) CGSize fittingSize;

@end
