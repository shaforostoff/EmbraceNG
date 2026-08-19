// (c) 2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "ParameterFormView.h"

static const CGFloat sMargin      = 20;
static const CGFloat sRowHeight   = 21;
static const CGFloat sRowGap      = 9;
static const CGFloat sLabelWidth  = 116;
static const CGFloat sSliderWidth = 180;
static const CGFloat sValueWidth  = 74;
static const CGFloat sGap         = 8;


// NSSlider has no double-click action of its own.  Swallowing the second click
// rather than passing it to super is deliberate: the knob must not also jump to
// where the pointer happens to be.
//
@interface ParameterSlider : NSSlider
@property (nonatomic, weak) id doubleTarget;
@property (nonatomic) SEL doubleSelector;
@end


@implementation ParameterSlider

- (void) mouseDown:(NSEvent *)event
{
    if ([event clickCount] == 2) {
        if (_doubleTarget && _doubleSelector) {
            [NSApp sendAction:_doubleSelector to:_doubleTarget from:self];
        }

        return;
    }

    [super mouseDown:event];
}

@end


@implementation ParameterFormView {
    AUAudioUnit *_audioUnit;
    id<ParameterDescribing> _describing;
    NSArray<AUParameter *> *_parameters;

    NSMutableArray<ParameterSlider *> *_sliders;
    NSMutableArray<NSTextField *>     *_valueFields;

    CGSize _fittingSize;
}

@synthesize fittingSize = _fittingSize;


- (instancetype) initWithAudioUnit:(AUAudioUnit *)audioUnit
{
    NSArray<AUParameter *> *parameters = [[audioUnit parameterTree] allParameters];

    NSInteger count  = [parameters count];
    CGFloat   width  = sMargin + sLabelWidth + sGap + sSliderWidth + sGap + sValueWidth + sMargin;
    CGFloat   height = (sMargin * 2) + (count * sRowHeight) + (MAX(count - 1, 0) * sRowGap);

    if ((self = [super initWithFrame:NSMakeRect(0, 0, width, height)])) {
        _audioUnit   = audioUnit;
        _describing  = (id<ParameterDescribing>)audioUnit;
        _parameters  = parameters;
        _fittingSize = CGSizeMake(width, height);

        _sliders     = [NSMutableArray arrayWithCapacity:count];
        _valueFields = [NSMutableArray arrayWithCapacity:count];

        [self _buildRows];
        [self reloadData];
    }

    return self;
}


- (BOOL) isFlipped { return YES; }


#pragma mark - Private Methods

- (void) _buildRows
{
    NSInteger row = 0;

    for (AUParameter *parameter in _parameters) {
        CGFloat y = sMargin + (row * (sRowHeight + sRowGap));
        CGFloat x = sMargin;

        NSTextField *label = [NSTextField labelWithString:[parameter displayName]];
        [label setFrame:NSMakeRect(x, y + 3, sLabelWidth, sRowHeight - 3)];
        [label setAlignment:NSTextAlignmentRight];
        [label setTag:row];
        [label setTextColor:[NSColor controlTextColor]];
        [self addSubview:label];

        x += sLabelWidth + sGap;

        ParameterSlider *slider = [[ParameterSlider alloc] initWithFrame:NSMakeRect(x, y, sSliderWidth, sRowHeight)];

        [slider setMinValue:[parameter minValue]];
        [slider setMaxValue:[parameter maxValue]];
        [slider setContinuous:YES];
        [slider setTag:row];
        [slider setTarget:self];
        [slider setAction:@selector(_handleSlider:)];
        [slider setDoubleTarget:self];
        [slider setDoubleSelector:@selector(_handleSliderDoubleClick:)];

        // On all three, so the row explains itself wherever the pointer lands
        NSString *toolTip = [self _toolTipForParameter:parameter];
        [label  setToolTip:toolTip];
        [slider setToolTip:toolTip];

        // Indexed parameters only take whole numbers, so let the slider snap
        if ([parameter unit] == kAudioUnitParameterUnit_Indexed) {
            NSInteger steps = (NSInteger)([parameter maxValue] - [parameter minValue]);

            if (steps > 0 && steps <= 64) {
                [slider setNumberOfTickMarks:(steps + 1)];
                [slider setAllowsTickMarkValuesOnly:YES];
                [slider setTickMarkPosition:NSTickMarkPositionBelow];
            }
        }

        [self addSubview:slider];
        [_sliders addObject:slider];

        x += sSliderWidth + sGap;

        NSTextField *valueField = [[NSTextField alloc] initWithFrame:NSMakeRect(x, y, sValueWidth, sRowHeight)];
        [valueField setAlignment:NSTextAlignmentRight];
        [valueField setTag:row];
        [valueField setTarget:self];
        [valueField setAction:@selector(_handleValueField:)];
        [[valueField cell] setLineBreakMode:NSLineBreakByClipping];
        [valueField setToolTip:toolTip];
        [self addSubview:valueField];
        [_valueFields addObject:valueField];

        row++;
    }
}


- (NSString *) _toolTipForParameter:(AUParameter *)parameter
{
    NSString *help = nil;

    if ([_describing respondsToSelector:@selector(embrace_helpTextForParameterAddress:)]) {
        help = [_describing embrace_helpTextForParameterAddress:[parameter address]];
    }

    if ([help length]) return help;

    // Nothing to say about the parameter itself, so at least surface the gesture
    return NSLocalizedString(@"Double-click to restore the default value.", nil);
}


- (NSString *) _stringForParameter:(AUParameter *)parameter
{
    NSString *string = [parameter stringFromValue:NULL];
    NSString *suffix = nil;

    AudioUnitParameterUnit unit = [parameter unit];

    if (unit == kAudioUnitParameterUnit_Hertz) {
        suffix = NSLocalizedString(@"Hz", nil);
    } else if (unit == kAudioUnitParameterUnit_Milliseconds) {
        suffix = NSLocalizedString(@"ms", nil);
    } else if (unit == kAudioUnitParameterUnit_Decibels) {
        suffix = NSLocalizedString(@"dB", nil);
    }

    if (suffix) {
        string = [NSString stringWithFormat:@"%@ %@", string, suffix];
    }

    return string;
}


- (void) _updateRow:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)[_parameters count]) return;

    AUParameter *parameter = [_parameters objectAtIndex:row];

    [[_sliders     objectAtIndex:row] setDoubleValue:[parameter value]];
    [[_valueFields objectAtIndex:row] setStringValue:[self _stringForParameter:parameter]];
}


#pragma mark - Actions

- (void) _handleSlider:(ParameterSlider *)sender
{
    NSInteger row = [sender tag];
    if (row < 0 || row >= (NSInteger)[_parameters count]) return;

    AUParameter *parameter = [_parameters objectAtIndex:row];
    [parameter setValue:(AUValue)[sender doubleValue] originator:NULL];

    [[_valueFields objectAtIndex:row] setStringValue:[self _stringForParameter:parameter]];
}


- (void) _handleSliderDoubleClick:(ParameterSlider *)sender
{
    NSInteger row = [sender tag];
    if (row < 0 || row >= (NSInteger)[_parameters count]) return;

    if (![_describing respondsToSelector:@selector(embrace_defaultValueForParameterAddress:)]) return;

    AUParameter *parameter = [_parameters objectAtIndex:row];
    [parameter setValue:[_describing embrace_defaultValueForParameterAddress:[parameter address]] originator:NULL];

    [self _updateRow:row];
}


- (void) _handleValueField:(NSTextField *)sender
{
    NSInteger row = [sender tag];
    if (row < 0 || row >= (NSInteger)[_parameters count]) return;

    AUParameter *parameter = [_parameters objectAtIndex:row];

    // Accepts what the field displays, unit suffix and all
    AUValue value = [parameter value];

    NSScanner *scanner = [NSScanner scannerWithString:[sender stringValue]];
    double scanned = 0;

    if ([scanner scanDouble:&scanned]) {
        value = (AUValue)scanned;
    }

    if (value < [parameter minValue]) value = [parameter minValue];
    if (value > [parameter maxValue]) value = [parameter maxValue];

    [parameter setValue:value originator:NULL];

    [self _updateRow:row];
}


#pragma mark - Public Methods

- (void) reloadData
{
    for (NSInteger row = 0; row < (NSInteger)[_parameters count]; row++) {
        [self _updateRow:row];
    }
}

@end
