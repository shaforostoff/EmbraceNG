// (c) 2026 EmbraceNG contributors
// MIT License (or) 1-clause BSD License

// Prefix.pch defines `auto` as __auto_type for the Objective-C sources.  This is
// Objective-C++, where libc++ needs `auto` to mean what C++ says it means.
#undef auto

#import "ParametricEQView.h"
#import "ParametricEQAudioUnit.h"
#import "ParameterFormView.h"    // ParameterDescribing

#import <AVFoundation/AVFoundation.h>

#include <cmath>
#include <vector>


static const CGFloat sMargin        = 20;
static const CGFloat sColumnWidth   = 52;
static const CGFloat sSectionGap    = 12;

static const CGFloat sCurveHeight   = 132;
static const CGFloat sCurveGap      = 16;

static const CGFloat sTitleHeight   = 13;
static const CGFloat sLabelHeight   = 12;
static const CGFloat sKnobRowHeight = 42;
static const CGFloat sValueHeight   = 14;
static const CGFloat sSwitchHeight  = 21;

static const CGFloat sLargeKnob     = 40;
static const CGFloat sSmallKnob     = 30;

// Pixels of vertical drag for the full range of a knob.  Roughly the height of
// the window, which is the distance a hand expects to move for "all of it".
static const CGFloat sDragTravel    = 170;

static const double  sCurveMinHz    = 20.0;
static const double  sCurveMaxHz    = 20000.0;
static const double  sCurveMaxDb    = 24.0;


static double sClamp(double v, double lo, double hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}


#pragma mark - Knob

@interface ParametricEQKnob : NSControl

@property (nonatomic) double minValue;
@property (nonatomic) double maxValue;
@property (nonatomic) double defaultValue;
@property (nonatomic) BOOL   logarithmic;
@property (nonatomic) BOOL   bipolar;

@end


@implementation ParametricEQKnob {
    double  _value;
    double  _dragStartValue;
    CGFloat _dragStartY;
}


- (instancetype) initWithFrame:(NSRect)frameRect
{
    if ((self = [super initWithFrame:frameRect])) {
        _minValue = 0;
        _maxValue = 1;
        [self setContinuous:YES];
    }

    return self;
}


- (double) doubleValue        { return _value; }
- (void) setDoubleValue:(double)v
{
    double clamped = sClamp(v, _minValue, _maxValue);

    if (clamped != _value) {
        _value = clamped;
        [self setNeedsDisplay:YES];
    }
}


#pragma mark - Scale

// A frequency knob has to be logarithmic or its whole bottom half is unusable:
// on a linear 1.5-16 kHz sweep, everything below 3 kHz lives in the first tenth
// of the travel.
//
- (double) _normalizedFromValue:(double)value
{
    if (_logarithmic && _minValue > 0 && _maxValue > _minValue) {
        return log(value / _minValue) / log(_maxValue / _minValue);
    }

    if (_maxValue <= _minValue) return 0;

    return (value - _minValue) / (_maxValue - _minValue);
}


- (double) _valueFromNormalized:(double)normalized
{
    normalized = sClamp(normalized, 0, 1);

    if (_logarithmic && _minValue > 0 && _maxValue > _minValue) {
        return _minValue * pow(_maxValue / _minValue, normalized);
    }

    return _minValue + (normalized * (_maxValue - _minValue));
}


#pragma mark - Drawing

// Minimum at 7:30, maximum at 4:30, 270 degrees of clockwise travel through
// straight up.  NSBezierPath measures counter-clockwise from the positive x
// axis, hence the subtraction.
static CGFloat sAngleForNormalized(double normalized)
{
    return (CGFloat)(225.0 - (270.0 * normalized));
}


- (void) drawRect:(NSRect)dirtyRect
{
    CGRect  bounds = [self bounds];
    CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    CGFloat radius = (MIN(bounds.size.width, bounds.size.height) / 2) - 3;

    if (radius <= 2) return;

    double  normalized = [self _normalizedFromValue:_value];
    CGFloat angle      = sAngleForNormalized(normalized);
    double  originN    = _bipolar ? 0.5 : 0.0;

    NSBezierPath *track = [NSBezierPath bezierPath];
    [track appendBezierPathWithArcWithCenter:center radius:radius
                                  startAngle:sAngleForNormalized(0)
                                    endAngle:sAngleForNormalized(1)
                                   clockwise:YES];
    [track setLineWidth:3];
    [track setLineCapStyle:NSLineCapStyleRound];
    [[NSColor tertiaryLabelColor] set];
    [track stroke];

    if (fabs(normalized - originN) > 0.0005) {
        NSBezierPath *filled = [NSBezierPath bezierPath];
        [filled appendBezierPathWithArcWithCenter:center radius:radius
                                       startAngle:sAngleForNormalized(originN)
                                         endAngle:angle
                                        clockwise:(normalized > originN)];
        [filled setLineWidth:3];
        [filled setLineCapStyle:NSLineCapStyleRound];
        [[NSColor controlAccentColor] set];
        [filled stroke];
    }

    CGFloat radians = (CGFloat)(angle * M_PI / 180.0);
    CGFloat dx = cos(radians), dy = sin(radians);

    NSBezierPath *pointer = [NSBezierPath bezierPath];
    [pointer moveToPoint:CGPointMake(center.x + (dx * radius * 0.30),
                                     center.y + (dy * radius * 0.30))];
    [pointer lineToPoint:CGPointMake(center.x + (dx * (radius - 1)),
                                     center.y + (dy * (radius - 1)))];
    [pointer setLineWidth:2];
    [pointer setLineCapStyle:NSLineCapStyleRound];
    [[NSColor labelColor] set];
    [pointer stroke];

    if ([[self window] firstResponder] == self && [[self window] isKeyWindow]) {
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:CGRectInset(bounds, 1, 1)];
        [ring setLineWidth:2];
        [[NSColor keyboardFocusIndicatorColor] set];
        [ring stroke];
    }
}


#pragma mark - Interaction

- (BOOL) acceptsFirstResponder { return YES; }
- (BOOL) becomeFirstResponder  { [self setNeedsDisplay:YES]; return YES; }
- (BOOL) resignFirstResponder  { [self setNeedsDisplay:YES]; return YES; }


- (void) _commitNormalized:(double)normalized
{
    [self setDoubleValue:[self _valueFromNormalized:normalized]];
    [self sendAction:[self action] to:[self target]];
}


// No nested tracking loop: -mouseDown:/-mouseDragged:/-mouseUp: are what a
// synthetic event stream can drive.  See the note in the header.
//
- (void) mouseDown:(NSEvent *)event
{
    if ([event clickCount] == 2) {
        [self setDoubleValue:_defaultValue];
        [self sendAction:[self action] to:[self target]];
        return;
    }

    [[self window] makeFirstResponder:self];

    _dragStartValue = _value;
    _dragStartY     = [event locationInWindow].y;
}


- (void) mouseDragged:(NSEvent *)event
{
    CGFloat delta = [event locationInWindow].y - _dragStartY;
    double  scale = ([event modifierFlags] & NSEventModifierFlagShift) ? 0.25 : 1.0;

    double normalized = [self _normalizedFromValue:_dragStartValue] +
                        ((delta / sDragTravel) * scale);

    [self _commitNormalized:normalized];
}


- (void) scrollWheel:(NSEvent *)event
{
    CGFloat delta = [event scrollingDeltaY];
    if ([event hasPreciseScrollingDeltas]) delta *= 0.1;

    [self _commitNormalized:[self _normalizedFromValue:_value] + (delta * 0.01)];
}


- (void) keyDown:(NSEvent *)event
{
    NSString *characters = [event charactersIgnoringModifiers];

    if (![characters length]) {
        [super keyDown:event];
        return;
    }

    unichar character = [characters characterAtIndex:0];
    double  step      = ([event modifierFlags] & NSEventModifierFlagShift) ? 0.002 : 0.01;
    double  normalized = [self _normalizedFromValue:_value];

    if (character == NSUpArrowFunctionKey || character == NSRightArrowFunctionKey) {
        [self _commitNormalized:normalized + step];

    } else if (character == NSDownArrowFunctionKey || character == NSLeftArrowFunctionKey) {
        [self _commitNormalized:normalized - step];

    } else {
        [super keyDown:event];
    }
}


#pragma mark - Accessibility

- (NSAccessibilityRole) accessibilityRole { return NSAccessibilitySliderRole; }
- (id) accessibilityValue                 { return @(_value); }
- (BOOL) isAccessibilityElement           { return YES; }

@end


#pragma mark - Curve

@interface ParametricEQCurveView : NSView
@property (nonatomic, weak) AUAudioUnit *audioUnit;
@end


@implementation ParametricEQCurveView {
    // The frequency axis, the trig table read off it, and the curve read off
    // that.  All three depend on the plot geometry and the sample rate and on
    // nothing a knob can move, which is what makes them worth keeping between
    // redraws -- see -_prepareCurveTableForPlot:rate: below.
    std::vector<double> _curveHz;
    std::vector<double> _curveTrig;
    std::vector<float>  _curveDb;
    CGFloat             _curveWidth;
    double              _curveRate;
}

- (BOOL) isOpaque { return NO; }


- (double) _sampleRate
{
    AUAudioUnitBusArray *busses = [_audioUnit outputBusses];

    if ([busses count] > 0) {
        double rate = [[[busses objectAtIndexedSubscript:0] format] sampleRate];
        if (rate > 0) return rate;
    }

    return 44100;
}


static CGFloat sXForFrequency(CGRect plot, double hz)
{
    double normalized = log(hz / sCurveMinHz) / log(sCurveMaxHz / sCurveMinHz);
    return plot.origin.x + (CGFloat)(normalized * plot.size.width);
}


static CGFloat sYForDecibels(CGRect plot, double db)
{
    double normalized = sClamp(db, -sCurveMaxDb, sCurveMaxDb) / sCurveMaxDb;
    return CGRectGetMidY(plot) + (CGFloat)(normalized * (plot.size.height / 2));
}


- (void) _drawGridInPlot:(CGRect)plot
{
    static const double lines[]  = { 20, 30, 50, 100, 200, 300, 500, 1000,
                                     2000, 3000, 5000, 10000, 20000 };
    static const double labels[] = { 100, 1000, 10000 };
    static const double decibels[] = { -20, -10, 0, 10, 20 };

    NSDictionary *attributes = @{
        NSFontAttributeName:            [NSFont systemFontOfSize:9],
        NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]
    };

    [[NSColor separatorColor] set];

    for (int i = 0; i < 13; i++) {
        CGFloat x = round(sXForFrequency(plot, lines[i])) + 0.5;

        NSBezierPath *path = [NSBezierPath bezierPath];
        [path moveToPoint:CGPointMake(x, CGRectGetMinY(plot))];
        [path lineToPoint:CGPointMake(x, CGRectGetMaxY(plot))];
        [path setLineWidth:1];
        [path stroke];
    }

    for (int i = 0; i < 5; i++) {
        CGFloat y = round(sYForDecibels(plot, decibels[i])) + 0.5;

        NSBezierPath *path = [NSBezierPath bezierPath];
        [path moveToPoint:CGPointMake(CGRectGetMinX(plot), y)];
        [path lineToPoint:CGPointMake(CGRectGetMaxX(plot), y)];
        [path setLineWidth:1];

        if (decibels[i] == 0) {
            [[NSColor secondaryLabelColor] set];
            [path stroke];
            [[NSColor separatorColor] set];
        } else {
            [path stroke];

            NSString *text = [NSString stringWithFormat:@"%+.0f", decibels[i]];
            [text drawAtPoint:CGPointMake(CGRectGetMinX(plot) + 3, y + 1) withAttributes:attributes];
        }
    }

    for (int i = 0; i < 3; i++) {
        NSString *text = labels[i] >= 1000 ?
            [NSString stringWithFormat:@"%gk", labels[i] / 1000] :
            [NSString stringWithFormat:@"%g", labels[i]];

        CGSize size = [text sizeWithAttributes:attributes];
        CGFloat x = sXForFrequency(plot, labels[i]) - (size.width / 2);

        [text drawAtPoint:CGPointMake(x, CGRectGetMinY(plot) + 2) withAttributes:attributes];
    }
}


// Brings the frequency axis and its trig table into line with this plot and
// this sample rate, and answers how many points they hold -- 0 when the plot is
// too small to draw a line across.
//
// The table is the expensive half of drawing a curve.  Asking magnitudeDb() for
// one point costs four trig calls per stage and a logarithm per stage, and both
// are per-point constants in disguise: cos(w) and cos(2w) depend on the
// frequency and the sample rate, neither of which a knob can move, and the six
// stage magnitudes are multiplied, so their six logarithms are one logarithm of
// the product.  Built here, a redraw is arithmetic -- about a fifth of the work,
// which is worth having on a drag.  See the note above curveTrig() in
// paraeq_core.h.
- (size_t) _prepareCurveTableForPlot:(CGRect)plot rate:(double)rate
{
    if (!(plot.size.width >= 1) || !(rate > 0)) return 0;

    // The points the drawing loop below walks: one per pixel column from the
    // left edge of the plot to the right.  Normalized against the full width
    // rather than against the last index, so a point lands exactly where
    // sXForFrequency would put its frequency.
    const size_t count = (size_t)floor((double)plot.size.width) + 1;

    if (count != _curveHz.size() ||
        plot.size.width != _curveWidth ||
        rate != _curveRate)
    {
        _curveHz.resize(count);
        _curveTrig.resize(count * (size_t)paraeq::kCurveTrigStride);
        _curveDb.resize(count);

        for (size_t i = 0; i < count; i++) {
            double normalized = (double)i / (double)plot.size.width;
            _curveHz[i] = sCurveMinHz * pow(sCurveMaxHz / sCurveMinHz, normalized);
        }

        paraeq::curveTrig(_curveHz.data(), count, rate, _curveTrig.data());

        _curveWidth = plot.size.width;
        _curveRate  = rate;
    }

    return count;
}


- (void) drawRect:(NSRect)dirtyRect
{
    CGRect bounds = [self bounds];

    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:4 yRadius:4];
    [[NSColor controlBackgroundColor] set];
    [background fill];

    CGRect plot = CGRectInset(bounds, 1, 1);

    [NSGraphicsContext saveGraphicsState];
    [background addClip];
    [self _drawGridInPlot:plot];

    if (_audioUnit) {
        paraeq::Params params = EmbraceParametricEQParamsFromTree([_audioUnit parameterTree]);
        params.bypass = [_audioUnit shouldBypassEffect] ? true : false;

        double rate = [self _sampleRate];

        paraeq::Config config;
        config.compute(params, rate);

        const size_t count = [self _prepareCurveTableForPlot:plot rate:rate];

        if (count >= 2) {
            // The whole cascade in one pass over the table, including the
            // output trim.  Reads the targets rather than the coefficients
            // actually in use, so the curve shows where the controls are and
            // not where a glide has got to.
            paraeq::curveDb(config, _curveTrig.data(), count, _curveDb.data());

            NSBezierPath *curve = [NSBezierPath bezierPath];
            NSBezierPath *fill  = [NSBezierPath bezierPath];

            CGFloat zeroY = sYForDecibels(plot, 0);

            for (size_t i = 0; i < count; i++) {
                CGPoint point = CGPointMake(plot.origin.x + (CGFloat)i,
                                            sYForDecibels(plot, _curveDb[i]));

                if (i == 0) {
                    [curve moveToPoint:point];
                    [fill moveToPoint:CGPointMake(point.x, zeroY)];
                    [fill lineToPoint:point];
                } else {
                    [curve lineToPoint:point];
                    [fill lineToPoint:point];
                }
            }

            [fill lineToPoint:CGPointMake(plot.origin.x + (CGFloat)(count - 1), zeroY)];
            [fill closePath];

            [[[NSColor controlAccentColor] colorWithAlphaComponent:0.16] set];
            [fill fill];

            [curve setLineWidth:1.5];
            [[NSColor controlAccentColor] set];
            [curve stroke];
        }
    }

    [NSGraphicsContext restoreGraphicsState];

    [[NSColor separatorColor] set];
    [background setLineWidth:1];
    [background stroke];
}

@end


#pragma mark - Layout table

enum {
    kKnobLogarithmic = 1 << 0,
    kKnobBipolar     = 1 << 1,
    kKnobLarge       = 1 << 2
};

typedef struct {
    int                column;
    int                columns;   //!< span, so a lone knob can centre itself
    AUParameterAddress address;
    const char        *label;
    unsigned           flags;
} ParametricEQKnobSpec;


// Twelve columns, read left to right as a console strip.  The four gain knobs
// are the large ones because they are the four an operator actually reaches for
// once the session has started.
//
static const ParametricEQKnobSpec sKnobs[] = {
    // Spans both of its section's columns so the slope switch underneath has
    // room for three legible segments.
    {  0, 2, EmbraceParametricEQParameterFilterFrequency, "Freq", kKnobLogarithmic },

    {  2, 1, EmbraceParametricEQParameterLFGain,          "Gain", kKnobBipolar | kKnobLarge },
    {  3, 1, EmbraceParametricEQParameterLFFrequency,     "Freq", kKnobLogarithmic },

    {  4, 1, EmbraceParametricEQParameterLMFGain,         "Gain", kKnobBipolar | kKnobLarge },
    {  5, 1, EmbraceParametricEQParameterLMFFrequency,    "Freq", kKnobLogarithmic },
    {  6, 1, EmbraceParametricEQParameterLMFQ,            "Q",    kKnobLogarithmic },

    {  7, 1, EmbraceParametricEQParameterHMFGain,         "Gain", kKnobBipolar | kKnobLarge },
    {  8, 1, EmbraceParametricEQParameterHMFFrequency,    "Freq", kKnobLogarithmic },
    {  9, 1, EmbraceParametricEQParameterHMFQ,            "Q",    kKnobLogarithmic },

    { 10, 1, EmbraceParametricEQParameterHFGain,          "Gain", kKnobBipolar | kKnobLarge },
    { 11, 1, EmbraceParametricEQParameterHFFrequency,     "Freq", kKnobLogarithmic },

    { 12, 1, EmbraceParametricEQParameterOutputGain,      "Trim", kKnobBipolar }
};

static const int sKnobCount = (int)(sizeof(sKnobs) / sizeof(sKnobs[0]));


typedef struct {
    const char        *title;
    int                firstColumn;
    int                columns;
    AUParameterAddress switchAddress;   // kNoSwitch for none
    int                switchSegments;
    // Segment titles, comma separated, or NULL to use the parameter's own
    // valueStrings.  The slope needs its own: "12 dB/oct" is what the parameter
    // is called everywhere else and it does not fit in a third of a section.
    const char        *switchLabels;
} ParametricEQSectionSpec;

static const AUParameterAddress kNoSwitch = EmbraceParametricEQParameterCount;

static const ParametricEQSectionSpec sSections[] = {
    { "FILTER",  0, 2, EmbraceParametricEQParameterFilterSlope, 3, "Off,12,24" },
    { "LF",      2, 2, EmbraceParametricEQParameterLFBell,      2, NULL        },
    { "LMF",     4, 3, kNoSwitch,                               0, NULL        },
    { "HMF",     7, 3, kNoSwitch,                               0, NULL        },
    { "HF",     10, 2, EmbraceParametricEQParameterHFBell,       2, NULL       },
    { "OUTPUT", 12, 1, kNoSwitch,                               0, NULL        }
};

static const int sSectionCount = (int)(sizeof(sSections) / sizeof(sSections[0]));
static const int sColumnCount  = 13;


#pragma mark - Main view

@implementation ParametricEQView {
    AUAudioUnit              *_audioUnit;
    AUParameterTree          *_parameterTree;
    AUParameterObserverToken  _observerToken;

    ParametricEQCurveView    *_curveView;

    NSMutableArray<ParametricEQKnob *>   *_knobs;
    NSMutableArray<NSTextField *>        *_valueFields;
    NSMutableArray<NSSegmentedControl *> *_switches;
}

@synthesize audioUnit = _audioUnit;


+ (CGSize) fittingSize
{
    CGFloat width = (sMargin * 2) + (sColumnCount * sColumnWidth) +
                    ((sSectionCount - 1) * sSectionGap);

    CGFloat height = sMargin + sCurveHeight + sCurveGap + sTitleHeight + 4 +
                     sLabelHeight + 3 + sKnobRowHeight + 2 + sValueHeight + 6 +
                     sSwitchHeight + sMargin;

    return CGSizeMake(width, height);
}


- (instancetype) initWithAudioUnit:(AUAudioUnit *)audioUnit
{
    CGSize size = [[self class] fittingSize];

    if ((self = [super initWithFrame:NSMakeRect(0, 0, size.width, size.height)])) {
        _audioUnit     = audioUnit;
        _parameterTree = [audioUnit parameterTree];

        _knobs       = [NSMutableArray arrayWithCapacity:sKnobCount];
        _valueFields = [NSMutableArray arrayWithCapacity:sKnobCount];
        _switches    = [NSMutableArray arrayWithCapacity:sSectionCount];

        [self _build];
        [self _buildMenu];
        [self reloadData];

        // Catches everything that changes a value from outside this view: a
        // preset load, Restore Defaults, and a host automating a parameter.
        // Values this view sets carry the token as originator, so they do not
        // come back round.
        __weak ParametricEQView *weakSelf = self;

        _observerToken = [_parameterTree tokenByAddingParameterObserver:
            ^(AUParameterAddress address, AUValue value)
        {
            // Called on whatever thread set the value, the render thread
            // included, so nothing here may touch AppKit directly.
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf reloadData];
            });
        }];
    }

    return self;
}


- (void) dealloc
{
    if (_observerToken) {
        [_parameterTree removeParameterObserver:_observerToken];
    }
}


- (BOOL) isFlipped { return YES; }


// Paints its own background rather than borrowing the window's.  The window
// does supply one, so this looks like a formality -- but every colour in here
// is a semantic one, and a semantic colour is only legible against a background
// from the same appearance.  Drawn detached from a window, which is how the
// tests draw it, white-in-dark-mode text on an unpainted view is invisible.
//
- (void) drawRect:(NSRect)dirtyRect
{
    [[NSColor windowBackgroundColor] set];
    NSRectFill(dirtyRect);
}


#pragma mark - Building

static CGFloat sXForColumn(int column)
{
    CGFloat x = sMargin;

    for (int i = 0; i < sSectionCount; i++) {
        if (column < sSections[i].firstColumn + sSections[i].columns) {
            return x + ((column - sSections[i].firstColumn) * sColumnWidth);
        }

        x += (sSections[i].columns * sColumnWidth) + sSectionGap;
    }

    return x;
}


static NSTextField *sMakeLabel(NSString *string, CGRect frame, CGFloat fontSize,
                               NSColor *color, NSFontWeight weight)
{
    NSTextField *label = [NSTextField labelWithString:string];

    [label setFrame:frame];
    [label setAlignment:NSTextAlignmentCenter];
    [label setFont:[NSFont systemFontOfSize:fontSize weight:weight]];
    [label setTextColor:color];
    [[label cell] setLineBreakMode:NSLineBreakByClipping];

    return label;
}


// Flatten lives here rather than on the toolbar.  The window this editor is
// hosted in -- EditSystemEffectWindow -- is shared with every effect that has
// no view of its own, and a Flatten item there would appear on declick and
// dehum, where it means nothing.  The graphic EQ has one because it has a
// window to itself.
//
- (void) _buildMenu
{
    NSMenu *menu = [[NSMenu alloc] init];

    NSMenuItem *item = [menu addItemWithTitle:NSLocalizedString(@"Flatten Gains", nil)
                                       action:@selector(flatten)
                                keyEquivalent:@""];
    [item setTarget:self];

    [self setMenu:menu];
}


- (void) _build
{
    CGSize  size = [[self class] fittingSize];
    CGFloat contentWidth = size.width - (sMargin * 2);

    CGFloat y = sMargin;

    _curveView = [[ParametricEQCurveView alloc] initWithFrame:
        NSMakeRect(sMargin, y, contentWidth, sCurveHeight)];
    [_curveView setAudioUnit:_audioUnit];
    [self addSubview:_curveView];

    y += sCurveHeight + sCurveGap;

    CGFloat titleY  = y;
    CGFloat labelY  = titleY + sTitleHeight + 4;
    CGFloat knobY   = labelY + sLabelHeight + 3;
    CGFloat valueY  = knobY  + sKnobRowHeight + 2;
    CGFloat switchY = valueY + sValueHeight + 6;

    for (int i = 0; i < sSectionCount; i++) {
        const ParametricEQSectionSpec *section = &sSections[i];

        CGFloat x     = sXForColumn(section->firstColumn);
        CGFloat width = section->columns * sColumnWidth;

        [self addSubview:sMakeLabel(@(section->title),
            NSMakeRect(x, titleY, width, sTitleHeight), 10,
            [NSColor secondaryLabelColor], NSFontWeightSemibold)];

        if (section->switchAddress == kNoSwitch) continue;

        AUParameter *parameter = [_parameterTree parameterWithAddress:section->switchAddress];

        // A segmented control rather than a popup, so a synthetic click cannot
        // open a modal menu loop.  See the note in the header.
        NSSegmentedControl *control = [[NSSegmentedControl alloc] initWithFrame:
            NSMakeRect(x + 2, switchY, width - 4, sSwitchHeight)];

        [control setSegmentCount:section->switchSegments];
        [control setSegmentStyle:NSSegmentStyleRounded];
        [control setControlSize:NSControlSizeSmall];
        [control setFont:[NSFont systemFontOfSize:9]];
        [control setTag:(NSInteger)section->switchAddress];
        [control setTarget:self];
        [control setAction:@selector(_handleSwitch:)];
        [control setToolTip:[self _toolTipForParameter:parameter]];

        NSArray<NSString *> *titles = section->switchLabels ?
            [@(section->switchLabels) componentsSeparatedByString:@","] :
            [parameter valueStrings];

        for (int segment = 0; segment < section->switchSegments; segment++) {
            NSString *title = (segment < (int)[titles count]) ?
                [titles objectAtIndex:segment] : @"";

            [control setLabel:title forSegment:segment];
            [control setWidth:((width - 4) / section->switchSegments) forSegment:segment];
        }

        [self addSubview:control];
        [_switches addObject:control];
    }

    for (int i = 0; i < sKnobCount; i++) {
        const ParametricEQKnobSpec *spec = &sKnobs[i];

        AUParameter *parameter = [_parameterTree parameterWithAddress:spec->address];
        NSString    *toolTip   = [self _toolTipForParameter:parameter];

        CGFloat columnX  = sXForColumn(spec->column);
        CGFloat columnW  = spec->columns * sColumnWidth;
        CGFloat diameter = (spec->flags & kKnobLarge) ? sLargeKnob : sSmallKnob;

        NSTextField *label = sMakeLabel(@(spec->label),
            NSMakeRect(columnX, labelY, columnW, sLabelHeight), 10,
            [NSColor tertiaryLabelColor], NSFontWeightRegular);
        [label setToolTip:toolTip];
        [self addSubview:label];

        ParametricEQKnob *knob = [[ParametricEQKnob alloc] initWithFrame:NSMakeRect(
            columnX + ((columnW - diameter) / 2),
            knobY + ((sKnobRowHeight - diameter) / 2),
            diameter, diameter)];

        [knob setMinValue:[parameter minValue]];
        [knob setMaxValue:[parameter maxValue]];
        [knob setDefaultValue:[self _defaultValueForParameter:parameter]];
        [knob setLogarithmic:(spec->flags & kKnobLogarithmic) ? YES : NO];
        [knob setBipolar:(spec->flags & kKnobBipolar) ? YES : NO];
        [knob setTag:i];
        [knob setTarget:self];
        [knob setAction:@selector(_handleKnob:)];
        [knob setToolTip:toolTip];
        [knob setAccessibilityLabel:[parameter displayName]];

        [self addSubview:knob];
        [_knobs addObject:knob];

        NSTextField *valueField = sMakeLabel(@"",
            NSMakeRect(columnX - 4, valueY, columnW + 8, sValueHeight), 10,
            [NSColor labelColor], NSFontWeightRegular);
        [valueField setToolTip:toolTip];
        [self addSubview:valueField];
        [_valueFields addObject:valueField];
    }
}


// The unit describes its own parameters, the same way it would for a generic
// form -- so the help text is written once and both editors show it.
- (id<ParameterDescribing>) _describing
{
    return (id<ParameterDescribing>)_audioUnit;
}


- (AUValue) _defaultValueForParameter:(AUParameter *)parameter
{
    id<ParameterDescribing> describing = [self _describing];

    if ([describing respondsToSelector:@selector(embrace_defaultValueForParameterAddress:)]) {
        return [describing embrace_defaultValueForParameterAddress:[parameter address]];
    }

    return [parameter value];
}


- (NSString *) _toolTipForParameter:(AUParameter *)parameter
{
    id<ParameterDescribing> describing = [self _describing];

    if ([describing respondsToSelector:@selector(embrace_helpTextForParameterAddress:)]) {
        NSString *help = [describing embrace_helpTextForParameterAddress:[parameter address]];
        if ([help length]) return help;
    }

    return NSLocalizedString(@"Double-click to restore the default value.", nil);
}


#pragma mark - Formatting

- (NSString *) _stringForParameter:(AUParameter *)parameter
{
    AUValue value = [parameter value];

    switch ([parameter unit]) {
    case kAudioUnitParameterUnit_Hertz:
        if (value >= 1000) {
            double kilohertz = value / 1000.0;
            NSString *number = (fabs(kilohertz - round(kilohertz)) < 0.05) ?
                [NSString stringWithFormat:@"%.0f", kilohertz] :
                [NSString stringWithFormat:@"%.1f", kilohertz];

            return [NSString stringWithFormat:NSLocalizedString(@"%@ kHz", nil), number];
        }

        return [NSString stringWithFormat:NSLocalizedString(@"%.0f Hz", nil), value];

    case kAudioUnitParameterUnit_Decibels:
        // Signed, because on a gain knob "5" and "-5" are the whole question
        // and the reader should not have to look at the knob to tell which.
        if (fabs(value) < 0.05) return NSLocalizedString(@"0.0 dB", nil);
        return [NSString stringWithFormat:NSLocalizedString(@"%+.1f dB", nil), value];

    default:
        return [NSString stringWithFormat:@"%.2f", value];
    }
}


#pragma mark - Actions

- (void) _handleKnob:(ParametricEQKnob *)knob
{
    NSInteger index = [knob tag];
    if (index < 0 || index >= sKnobCount) return;

    AUParameter *parameter = [_parameterTree parameterWithAddress:sKnobs[index].address];

    [parameter setValue:(AUValue)[knob doubleValue] originator:_observerToken];

    [[_valueFields objectAtIndex:index] setStringValue:[self _stringForParameter:parameter]];
    [_curveView setNeedsDisplay:YES];
}


- (void) _handleSwitch:(NSSegmentedControl *)control
{
    AUParameter *parameter = [_parameterTree parameterWithAddress:(AUParameterAddress)[control tag]];

    [parameter setValue:(AUValue)[control selectedSegment] originator:_observerToken];

    [_curveView setNeedsDisplay:YES];
}


#pragma mark - Public Methods

- (void) reloadData
{
    for (int i = 0; i < sKnobCount; i++) {
        AUParameter *parameter = [_parameterTree parameterWithAddress:sKnobs[i].address];

        [[_knobs objectAtIndex:i] setDoubleValue:[parameter value]];
        [[_valueFields objectAtIndex:i] setStringValue:[self _stringForParameter:parameter]];
    }

    for (NSSegmentedControl *control in _switches) {
        AUParameter *parameter = [_parameterTree parameterWithAddress:(AUParameterAddress)[control tag]];
        NSInteger    segment   = (NSInteger)lround([parameter value]);

        if (segment >= 0 && segment < [control segmentCount]) {
            [control setSelectedSegment:segment];
        }
    }

    [_curveView setNeedsDisplay:YES];
}


- (void) flatten
{
    static const AUParameterAddress gains[] = {
        EmbraceParametricEQParameterLFGain,
        EmbraceParametricEQParameterLMFGain,
        EmbraceParametricEQParameterHMFGain,
        EmbraceParametricEQParameterHFGain,
        EmbraceParametricEQParameterOutputGain
    };

    for (int i = 0; i < 5; i++) {
        [[_parameterTree parameterWithAddress:gains[i]] setValue:0 originator:_observerToken];
    }

    [self reloadData];
}

@end
