// (c) 2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>

// A label, slider and editable value field per parameter, for effects whose audio
// unit brings no view of its own.  Double-clicking a slider returns that one
// parameter to its default, which the unit supplies by implementing
//
//     - (AUValue) embrace_defaultValueForParameterAddress:(AUParameterAddress)address
//
// Units that don't have it simply don't reset.

@interface ParameterFormView : NSView

- (instancetype) initWithAudioUnit:(AUAudioUnit *)audioUnit;

// Picks the values back up after something outside the form changed them
- (void) reloadData;

@property (nonatomic, readonly) CGSize fittingSize;

@end
