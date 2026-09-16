// (c) 2026 EmbraceNG contributors
// MIT License (or) 1-clause BSD License
//
// Checks on the cortina switch: the two ways a track's rhythm is read, the
// lookup that finds a preset named "cortina" among an effect type's recent
// ones, and the state machine that loads it and puts the DJ's own settings
// back afterwards.
//
// The last of those runs against real AUAudioUnits and real preset files, and
// measures a parameter each time rather than trusting that a load happened, so
// a -setFullState: that quietly does nothing fails the suite.
//
// CortinaEffects is handed a stand-in for Track.  It asks a track exactly one
// question -- -danceRhythm -- and building a real Track drags in the app
// delegate, the worker connection and the on-disk state directory to answer it.
// The rule that answers it is GetDanceRhythm(), which is tested directly above.

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>

#import "CortinaEffects.h"
#import "DanceRhythm.h"
#import "Effect.h"
#import "EffectType.h"
#import "RecentPresets.h"

// The app's, not linked here.
void EmbraceLog(NSString *category, NSString *format, ...) { }
void _EmbraceLogMethod(const char *f) { }


static int sFail = 0;
static int sChecks = 0;

static void ckTrue(const char *what, BOOL ok)
{
    sChecks++;
    if (!ok) sFail++;
    printf("   %-4s %s\n", ok ? "ok" : "FAIL", what);
}

static void ckRhythm(NSString *what, DanceRhythm got, DanceRhythm want)
{
    sChecks++;
    BOOL ok = (got == want);
    if (!ok) sFail++;
    printf("   %-4s %-40s %-10s (want %s)\n", ok ? "ok" : "FAIL", [what UTF8String],
           [GetNameForDanceRhythm(got) UTF8String], [GetNameForDanceRhythm(want) UTF8String]);
}

static void ckNear(const char *what, double got, double want, double tol)
{
    sChecks++;
    BOOL ok = fabs(got - want) <= tol;
    if (!ok) sFail++;
    printf("   %-4s %-52s %9.2f (want %.2f)\n", ok ? "ok" : "FAIL", what, got, want);
}


#pragma mark - Reading a genre tag

static void testGenreTags(void)
{
    printf("\n-- a genre tag, however it is written --\n");

    // Left column as a collection really holds them; right column what the
    // floor would do.  The compound tags are the ones worth having a table
    // for: "Tango Vals" is a vals, and reading it as a tango would be right
    // about the family and wrong about the dance.
    NSArray *cases = @[
        @[ @"Tango",              @(DanceRhythmTango)    ],
        @[ @"TANGO",              @(DanceRhythmTango)    ],
        @[ @"tango",              @(DanceRhythmTango)    ],
        @[ @"Tangos",             @(DanceRhythmTango)    ],
        @[ @"Tango Argentino",    @(DanceRhythmTango)    ],
        @[ @"Tango negro",        @(DanceRhythmTango)    ],
        @[ @"Neotango",           @(DanceRhythmTango)    ],
        @[ @"Electrotango",       @(DanceRhythmTango)    ],

        @[ @"Vals",               @(DanceRhythmVals)     ],
        @[ @"Vals criollo",       @(DanceRhythmVals)     ],
        @[ @"Tango Vals",         @(DanceRhythmVals)     ],
        @[ @"Tango-Vals",         @(DanceRhythmVals)     ],

        @[ @"Milonga",            @(DanceRhythmMilonga)  ],
        @[ @"Milongas",           @(DanceRhythmMilonga)  ],
        @[ @"Tango Milonga",      @(DanceRhythmMilonga)  ],
        @[ @"Tango/Milonga",      @(DanceRhythmMilonga)  ],
        @[ @"Milonga tangueada",  @(DanceRhythmMilonga)  ],

        @[ @"Candombe",           @(DanceRhythmCandombe) ],
        @[ @"Candombé",           @(DanceRhythmCandombe) ],
        @[ @"Milonga candombe",   @(DanceRhythmCandombe) ],

        // Cortinas.  None of these should read as anything to dance a tanda to.
        @[ @"Rock",               @(DanceRhythmUnknown)  ],
        @[ @"Swing",              @(DanceRhythmUnknown)  ],
        @[ @"Pop",                @(DanceRhythmUnknown)  ],
        @[ @"Latin",              @(DanceRhythmUnknown)  ],
        @[ @"Instrumental",       @(DanceRhythmUnknown)  ],
        @[ @"Reggae",             @(DanceRhythmUnknown)  ],
        @[ @"Jazz Vocal",         @(DanceRhythmUnknown)  ],

        // Deliberately not a vals.  A Strauss waltz is a cortina at a milonga,
        // and reading "Waltz" as a vals would take the cortina settings off
        // exactly the track they were meant for.
        @[ @"Waltz",              @(DanceRhythmUnknown)  ],

        @[ @"",                   @(DanceRhythmUnknown)  ]
    ];

    for (NSArray *pair in cases) {
        ckRhythm([pair objectAtIndex:0],
                 GetDanceRhythmForGenreString([pair objectAtIndex:0]),
                 [[pair objectAtIndex:1] integerValue]);
    }

    ckTrue("no tag at all", GetDanceRhythmForGenreString(nil) == DanceRhythmUnknown);
    ckTrue("something that is not a string", GetDanceRhythmForGenreString((id)@42) == DanceRhythmUnknown);
}


#pragma mark - Reading a measurement

static void testDetectedNames(void)
{
    printf("\n-- what bpmcore reported --\n");

    // These five strings are bpmcore's rhythm_name(), and the sixth is
    // BPMAnalyzerRhythmUnknown.  BPMAnalyzerTests checks from the other end
    // that nothing outside this set ever comes back.
    ckRhythm(@"Tango",   GetDanceRhythmForDetectedName(@"Tango"),   DanceRhythmTango);
    ckRhythm(@"Vals",    GetDanceRhythmForDetectedName(@"Vals"),    DanceRhythmVals);
    ckRhythm(@"Milonga", GetDanceRhythmForDetectedName(@"Milonga"), DanceRhythmMilonga);
    ckRhythm(@"Reggae",  GetDanceRhythmForDetectedName(@"Reggae"),  DanceRhythmReggae);
    ckRhythm(@"Other",   GetDanceRhythmForDetectedName(@"Other"),   DanceRhythmOther);
    ckRhythm(@"Unknown", GetDanceRhythmForDetectedName(@"Unknown"), DanceRhythmUnknown);

    ckTrue("nothing measured", GetDanceRhythmForDetectedName(nil) == DanceRhythmUnknown);

    // Exact, unlike a tag: both ends of this are ours.  A measurement of
    // "Tango Vals" would mean bpmcore had changed underneath us, and guessing
    // at it is worse than saying so.
    ckTrue("a name bpmcore does not produce", GetDanceRhythmForDetectedName(@"Tango Vals") == DanceRhythmUnknown);

    printf("\n-- which of them the floor dances --\n");

    ckTrue("tango is danced",    GetDanceRhythmIsDanced(DanceRhythmTango));
    ckTrue("vals is danced",     GetDanceRhythmIsDanced(DanceRhythmVals));
    ckTrue("milonga is danced",  GetDanceRhythmIsDanced(DanceRhythmMilonga));
    ckTrue("candombe is danced", GetDanceRhythmIsDanced(DanceRhythmCandombe));
    ckTrue("reggae is not",      !GetDanceRhythmIsDanced(DanceRhythmReggae));
    ckTrue("other is not",       !GetDanceRhythmIsDanced(DanceRhythmOther));
    ckTrue("unknown is not",     !GetDanceRhythmIsDanced(DanceRhythmUnknown));
}


#pragma mark - The rule

static void testTheRule(void)
{
    printf("\n-- tag first, measurement second --\n");

    ckRhythm(@"a tag beats a measurement",
             GetDanceRhythm(@"Tango", @"Other"), DanceRhythmTango);

    // The one that is easy to get wrong.  A tag reading "Rock" names none of
    // the four, and that is an answer -- a cortina -- not a shrug.  Falling
    // through to the measurement here would put the DJ's tango settings back on
    // a cortina that bpmcore happened to call a tango.
    ckRhythm(@"a tag that names none of them still answers",
             GetDanceRhythm(@"Rock", @"Tango"), DanceRhythmOther);

    ckRhythm(@"no tag, so the measurement",
             GetDanceRhythm(nil, @"Milonga"), DanceRhythmMilonga);
    ckRhythm(@"an empty tag is no tag",
             GetDanceRhythm(@"", @"Reggae"), DanceRhythmReggae);
    ckRhythm(@"neither",
             GetDanceRhythm(nil, nil), DanceRhythmUnknown);
    ckRhythm(@"a tag, and nothing measured",
             GetDanceRhythm(@"Vals", nil), DanceRhythmVals);

    // bpmcore has no candombe class and does not need one: candombes classify
    // as milonga, which is what puts their BPM on the level they are tapped at
    // and, here, what keeps their effects on the tanda settings.
    ckTrue("an untagged candombe measures as milonga, and is danced",
           GetDanceRhythmIsDanced(GetDanceRhythm(nil, @"Milonga")));
}


#pragma mark - Finding the cortina preset

static EffectType *sTypeNamed(NSString *name)
{
    for (EffectType *type in [EffectType allEffectTypes]) {
        if ([[type name] isEqualToString:name]) return type;
    }

    return nil;
}


// Each phase gets its own directory and its own recent-presets list.  They
// would otherwise share the path .../cortina.aupreset, and the second phase
// writing that file would put a preset saved from one unit where the first
// phase had registered it for another -- which is not a thing the app can do,
// since the list is keyed per effect type, and is exactly the sort of crosstalk
// a suite invents for itself and then reports as a defect.
//
static NSString *sPhase = @"0";

static NSString *sPresetDirectory(void)
{
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"embrace-cortina-tests-" stringByAppendingString:sPhase]];

    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    return dir;
}


static void sBeginPhase(NSString *name)
{
    sPhase = name;

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"recent-presets"];
    [[NSFileManager defaultManager] removeItemAtPath:sPresetDirectory() error:nil];
}


// A file that is a real preset for `effect` as it stands right now.
static NSURL *sSavePreset(Effect *effect, NSString *name)
{
    NSString *path = [sPresetDirectory() stringByAppendingPathComponent:name];
    NSURL *url = [NSURL fileURLWithPath:path];

    if (![effect saveAudioPresetAtFileURL:url]) return nil;

    return url;
}


static void testFindingThePreset(Effect *effect)
{
    printf("\n-- finding a preset called cortina --\n");

    sBeginPhase(@"finding");

    NSString *typeName = [[effect type] fullName];

    NSURL *other = sSavePreset(effect, @"Shellac 1940.aupreset");
    NSURL *url   = sSavePreset(effect, @"cortina.aupreset");

    AddRecentPresetPath(typeName, other);
    AddRecentPresetPath(typeName, url);

    ckTrue("found by its own name", [GetRecentPresetFileURLWithName(typeName, @"cortina") isEqual:url]);
    ckTrue("found case-insensitively", [GetRecentPresetFileURLWithName(typeName, @"Cortina") isEqual:url]);
    ckTrue("found however it was typed", [GetRecentPresetFileURLWithName(typeName, @"CORTINA") isEqual:url]);
    ckTrue("the other preset is not it", ![GetRecentPresetFileURLWithName(typeName, @"Shellac 1940") isEqual:url]);
    ckTrue("a name nothing carries", GetRecentPresetFileURLWithName(typeName, @"tanda") == nil);
    ckTrue("an empty name matches nothing", GetRecentPresetFileURLWithName(typeName, @"") == nil);

    // The whole name, not part of it.  "cortina 2" is a different preset and
    // the DJ named it that on purpose.
    NSURL *nearly = sSavePreset(effect, @"cortina 2.aupreset");
    AddRecentPresetPath(typeName, nearly);
    ckTrue("a name that merely contains it does not match",
           [GetRecentPresetFileURLWithName(typeName, @"cortina") isEqual:url]);

    // Case, but also spelling: "Cortiña.aupreset" is the same preset to anyone
    // looking at the menu.
    ckTrue("found across accents", [GetRecentPresetFileURLWithName(typeName, @"cortiña") isEqual:url]);

    // A preset on an unmounted volume is still in the list -- the menu hides it
    // rather than forgetting it -- but it cannot be loaded, so it must not be
    // handed back as though it could.
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    ckTrue("a preset whose file has gone is not offered", GetRecentPresetFileURLWithName(typeName, @"cortina") == nil);
    ckTrue("and is still in the list", [GetRecentPresetPaths(typeName) containsObject:[url path]]);

    ckTrue("another effect type sees none of this",
           GetRecentPresetFileURLWithName(@"Some Other Unit", @"cortina") == nil);
    ckTrue("neither does no type at all",
           GetRecentPresetFileURLWithName(nil, @"cortina") == nil);
}


#pragma mark - The switch

@interface FakeTrack : NSObject
@property (nonatomic) DanceRhythm rhythm;
@end

@implementation FakeTrack
- (DanceRhythm) danceRhythm { return _rhythm; }
@end


static id sTrack(DanceRhythm rhythm)
{
    FakeTrack *track = [[FakeTrack alloc] init];
    [track setRhythm:rhythm];
    return track;
}


static AUParameter *sFirstParameter(Effect *effect)
{
    return [[[[effect audioUnit] parameterTree] allParameters] firstObject];
}


static void testTheSwitch(Effect *shellac, Effect *untouched)
{
    printf("\n-- loading the cortina preset, and putting it back --\n");

    sBeginPhase(@"switching");

    NSString *typeName = [[shellac type] fullName];

    AUParameter *parameter = sFirstParameter(shellac);
    AUParameter *otherParameter = sFirstParameter(untouched);

    if (!parameter || !otherParameter) {
        printf("   FAIL no parameters to measure\n");
        sFail++;
        return;
    }

    // Two settings far enough apart that no rounding could confuse them.
    float cortinaValue = [parameter minValue] + ([parameter maxValue] - [parameter minValue]) * 0.25f;
    float djValue      = [parameter minValue] + ([parameter maxValue] - [parameter minValue]) * 0.75f;

    [parameter setValue:cortinaValue originator:NULL];
    NSURL *url = sSavePreset(shellac, @"cortina.aupreset");
    AddRecentPresetPath(typeName, url);

    // What the DJ has the chain set to for the tanda.
    [parameter setValue:djValue originator:NULL];

    float otherValue = [otherParameter minValue] +
        ([otherParameter maxValue] - [otherParameter minValue]) * 0.5f;
    [otherParameter setValue:otherValue originator:NULL];

    NSArray *effects = @[ shellac, untouched ];
    CortinaEffects *cortina = [[CortinaEffects alloc] init];

    ckTrue("nothing is switched to begin with", ![cortina isEngaged]);

    // A cortina.
    [cortina updateWithTrack:sTrack(DanceRhythmOther) effects:effects];
    ckNear("the cortina preset is loaded", [parameter value], cortinaValue, 0.01);
    ckTrue("and it says so", [cortina isEngaged]);
    ckNear("an effect with no cortina preset is left alone", [otherParameter value], otherValue, 0.01);

    // What would be written to disk right now is what the DJ chose, not what is
    // audible.  Without this, quitting during a cortina persists the cortina
    // preset as the chain and the tanda settings are gone.
    NSDictionary *persisted = [cortina persistentAudioPresetForEffect:shellac];
    Effect *probe = [Effect effectWithEffectType:[shellac type]];
    [probe loadAudioPreset:persisted];
    ckNear("what would be saved is the DJ's setting", [sFirstParameter(probe) value], djValue, 0.01);

    // A second cortina in a row.  Saving again here would overwrite the held
    // settings with the cortina preset, and the tanda would never come back.
    [cortina updateWithTrack:sTrack(DanceRhythmReggae) effects:effects];
    ckNear("a second cortina changes nothing", [parameter value], cortinaValue, 0.01);

    persisted = [cortina persistentAudioPresetForEffect:shellac];
    probe = [Effect effectWithEffectType:[shellac type]];
    [probe loadAudioPreset:persisted];
    ckNear("and the DJ's setting is still what would be saved",
           [sFirstParameter(probe) value], djValue, 0.01);

    // The tanda comes round again.
    [cortina updateWithTrack:sTrack(DanceRhythmTango) effects:effects];
    ckNear("the DJ's settings come back", [parameter value], djValue, 0.01);
    ckTrue("and nothing is switched any more", ![cortina isEngaged]);

    // And again, on a track that was never switched.
    [cortina updateWithTrack:sTrack(DanceRhythmVals) effects:effects];
    ckNear("restoring twice is harmless", [parameter value], djValue, 0.01);

    printf("\n-- a track we cannot identify --\n");

    // No tag and nothing measured.  Leaving the DJ's own settings on a cortina
    // costs one track; putting a cortina preset on an unrecognised tango takes
    // the restoration off a track that needs it, in front of a floor.
    [cortina updateWithTrack:sTrack(DanceRhythmUnknown) effects:effects];
    ckNear("nothing is switched", [parameter value], djValue, 0.01);
    ckTrue("and nothing is held", ![cortina isEngaged]);

    // An unknown track arriving in the middle of a run of cortinas puts things
    // back rather than leaving them switched.
    [cortina updateWithTrack:sTrack(DanceRhythmOther) effects:effects];
    ckTrue("switched again for a cortina", [cortina isEngaged]);
    [cortina updateWithTrack:sTrack(DanceRhythmUnknown) effects:effects];
    ckNear("an unknown track restores", [parameter value], djValue, 0.01);
    ckTrue("and releases what it held", ![cortina isEngaged]);

    printf("\n-- the chain changing underneath it --\n");

    [cortina updateWithTrack:sTrack(DanceRhythmOther) effects:effects];
    ckTrue("switched", [cortina isEngaged]);

    // The effect is deleted from the chain while the cortina plays.  There is
    // nothing left to restore, and holding its settings for the rest of the
    // session would claim a switch that no longer exists.
    [cortina updateWithTrack:sTrack(DanceRhythmOther) effects:@[ untouched ]];
    ckTrue("a deleted effect is forgotten", ![cortina isEngaged]);

    // And an effect that is not switched persists its own settings.
    persisted = [cortina persistentAudioPresetForEffect:untouched];
    probe = [Effect effectWithEffectType:[untouched type]];
    [probe loadAudioPreset:persisted];
    ckNear("an unswitched effect persists what it holds",
           [sFirstParameter(probe) value], otherValue, 0.01);
}


#pragma mark -

int main(void)
{
    @autoreleasepool {
        // The harness's own defaults domain, not the app's, so a run cannot
        // disturb a real installation's recent presets.
        NSString *domain = [[NSProcessInfo processInfo] processName];
        [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:domain];

        printf("Cortina switching\n");

        testGenreTags();
        testDetectedNames();
        testTheRule();

        EffectType *lowpassType  = sTypeNamed(@"AULowpass");
        EffectType *dynamicsType = sTypeNamed(@"AUDynamicsProcessor");

        Effect *lowpass  = lowpassType  ? [Effect effectWithEffectType:lowpassType]  : nil;
        Effect *dynamics = dynamicsType ? [Effect effectWithEffectType:dynamicsType] : nil;

        if (lowpass && dynamics) {
            testFindingThePreset(dynamics);
            testTheSwitch(lowpass, dynamics);
        } else {
            printf("\n   FAIL could not create the effects these need\n");
            sFail++;
        }

        for (NSString *phase in @[ @"finding", @"switching" ]) {
            sPhase = phase;
            [[NSFileManager defaultManager] removeItemAtPath:sPresetDirectory() error:nil];
        }

        [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:domain];

        ckTrue("the harness left no defaults behind",
               [[NSUserDefaults standardUserDefaults] objectForKey:@"recent-presets"] == nil);

        printf("\n%d checks, %d failed\n", sChecks, sFail);
    }

    return sFail ? 1 : 0;
}
