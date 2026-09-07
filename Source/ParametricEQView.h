// (c) 2026 EmbraceNG contributors
// MIT License (or) 1-clause BSD License

#import <Cocoa/Cocoa.h>

@class AUAudioUnit;


// The editor for ParametricEQAudioUnit: a response curve over a console strip,
// read left to right as filter, LF, LMF, HMF, HF, output.
//
// The four gain knobs are drawn larger than the rest, which is the whole point
// of the layout rather than decoration.  Frequency and Q get set once for a box
// of records; the gains are what an operator actually reaches for, and they
// should be the four things the eye lands on.
//
// The controls are deliberately plain NSControls with no nested mouse-tracking
// loop and no NSPopUpButton anywhere.  Both choices are for the test harness in
// Tests/: a tracking loop pulls from the same event queue synthetic events are
// posted to, and clicking a popup opens a modal menu loop a synthetic event
// stream cannot escape -- which is what wedged the N-band EQ mouse suite.
//
@interface ParametricEQView : NSView

- (instancetype) initWithAudioUnit:(AUAudioUnit *)audioUnit;

// Picks the values back up after something outside the view changed them.  Not
// normally needed -- a parameter observer catches preset loads and Restore
// Defaults on its own -- but harmless, and the editor protocol allows for it.
- (void) reloadData;

// Every gain and the output trim to 0 dB, leaving frequencies and Q where they
// are.  The counterpart of the graphic EQ's Flatten, and the right gesture here
// for the same reason: the setup is worth keeping, the curve is not.
- (void) flatten;

@property (nonatomic, readonly) AUAudioUnit *audioUnit;

@end
