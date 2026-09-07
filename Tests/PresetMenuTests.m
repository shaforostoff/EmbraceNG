// (c) 2026 EmbraceNG contributors
// MIT License (or) 1-clause BSD License
//
// Checks the recent-presets list in each effect editor's "..." menu: that the
// menu the xib defines is found at all, that entries land between Save Preset…
// and the separator below it, that the list is most-recent-first, capped, free
// of duplicates, kept apart per effect type, and that a preset the effect
// refuses is not remembered.
//
// The menu is rebuilt from NSUserDefaults every time it opens, which is what
// lets two windows onto the same effect type agree.  These checks drive
// -[NSMenu update] -- the same call AppKit makes before displaying a menu --
// rather than clicking, because clicking an NSPopUpButton opens a modal menu
// loop a test has no way out of.

#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/message.h>
#import <unistd.h>

#import "EditEffectController.h"
#import "Effect.h"
#import "EffectType.h"
#import "EffectAdditions.h"

static int sFail = 0;

static NSString * const sRecentPresetsKey = @"recent-presets";


// Effect.m logs refused state; nothing here needs the real log file.
void EmbraceLog(NSString *category, NSString *format, ...) { }
void _EmbraceLogMethod(const char *f) { }


static void ckTrue(const char *what, BOOL ok)
{
    if (!ok) sFail++;
    printf("   %-4s %s\n", ok ? "ok" : "FAIL", what);
}

static void ckEqualArrays(const char *what, NSArray *got, NSArray *want)
{
    BOOL ok = [got isEqualToArray:want];
    if (!ok) sFail++;

    printf("   %-4s %s\n", ok ? "ok" : "FAIL", what);

    if (!ok) {
        printf("        got  %s\n", [[got componentsJoinedByString:@" | "] UTF8String]);
        printf("        want %s\n", [[want componentsJoinedByString:@" | "] UTF8String]);
    }
}


#pragma mark - Test controllers

// EditGraphicEQEffectWindow.nib holds one of these.  The real view draws the
// bands and is not what is under test here, so this stands in for it -- linking
// the real one would drag in the whole of Utils.
//
@interface GraphicEQView : NSView
@end

@implementation GraphicEQView
@end


// The nib sets its outlets with -setValue:forKey:, which throws for a key the
// owner does not have, so loading one at all is the check that the connection
// this feature added resolves.  These stand in for the real subclasses so the
// checks stay clear of CoreAudioKit and the window resizing dance.
//
@interface TestEffectController : EditEffectController
@property (nonatomic) NSInteger reloadCount;
@end

@implementation TestEffectController

- (void) reloadData
{
    [self setReloadCount:[self reloadCount] + 1];
}

@end


@interface TestSystemEffectController : TestEffectController
@property (nonatomic, weak) IBOutlet NSToolbar *toolbar;
@end

@implementation TestSystemEffectController

- (NSString *) windowNibName { return @"EditSystemEffectWindow"; }

@end


@interface TestGraphicEQEffectController : TestEffectController
@property (nonatomic, weak) IBOutlet NSVisualEffectView *backgroundView;
@property (nonatomic, weak) IBOutlet NSView *graphicEQView;
@end

@implementation TestGraphicEQEffectController

- (NSString *) windowNibName { return @"EditGraphicEQEffectWindow"; }

@end


#pragma mark - Helpers

static EffectType *sTypeNamed(NSString *name)
{
    for (EffectType *type in [EffectType allEffectTypes]) {
        if ([[type name] isEqualToString:name]) return type;
    }

    return nil;
}


static NSMenu *sActionsMenu(EditEffectController *controller)
{
    return [controller valueForKey:@"actionsMenu"];
}


// Separators read as "-" so the shape of the menu is visible in a diff
static NSArray<NSString *> *sMenuTitles(NSMenu *menu)
{
    NSMutableArray *result = [NSMutableArray array];

    for (NSMenuItem *item in [menu itemArray]) {
        [result addObject:[item isSeparatorItem] ? @"-" : [item title]];
    }

    return result;
}


static NSArray<NSString *> *sStoredPaths(NSString *typeName)
{
    NSDictionary *pathsByType = [[NSUserDefaults standardUserDefaults] objectForKey:sRecentPresetsKey];
    NSArray *paths = [pathsByType objectForKey:typeName];

    return paths ? paths : @[ ];
}


// The harness has a defaults domain of its own, named after the executable
// rather than the app, so this can clear the whole of it -- the window frames
// -windowDidLoad autosaves included.
//
static void sForgetEverything(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    [defaults removeObjectForKey:sRecentPresetsKey];
    [defaults removePersistentDomainForName:[[NSProcessInfo processInfo] processName]];
}


// The "..." button in the window's toolbar
static NSPopUpButton *sActionsPopUpButton(EditEffectController *controller)
{
    for (NSToolbarItem *item in [[[controller window] toolbar] items]) {
        if ([[item view] isKindOfClass:[NSPopUpButton class]]) {
            return (NSPopUpButton *)[item view];
        }
    }

    return nil;
}


// Opening the menu is the only thing that makes AppKit consult its delegate:
// -[NSMenu update], -performKeyEquivalent: and -numberOfItems all leave it
// alone, so a test that called those would pass on a stale menu.  Tracking is
// modal, so an Escape is queued first -- the session pulls from the same event
// queue and cancels at once.  The alarm in main is the way out if it ever does
// not.
//
static void sOpenActionsMenu(EditEffectController *controller)
{
    NSEvent *escape = [NSEvent keyEventWithType: NSEventTypeKeyDown
                                       location: NSZeroPoint
                                  modifierFlags: 0
                                      timestamp: 0
                                   windowNumber: 0
                                        context: nil
                                     characters: @"\033"
                    charactersIgnoringModifiers: @"\033"
                                      isARepeat: NO
                                        keyCode: 53];

    [NSApp postEvent:escape atStart:YES];
    [sActionsPopUpButton(controller) performClick:nil];
}


static void sLoadPreset(EditEffectController *controller, NSURL *fileURL)
{
    // -_loadPresetAtFileURL: is what both Load Preset… and a recent item reach
    SEL selector = NSSelectorFromString(@"_loadPresetAtFileURL:");
    ((void (*)(id, SEL, NSURL *))objc_msgSend)(controller, selector, fileURL);
}


// A preset for `effect`, written the way Save Preset… writes one
static NSURL *sMintPreset(Effect *effect, NSString *directory, NSString *name)
{
    NSString *path = [directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"aupreset"]];
    NSURL *fileURL = [NSURL fileURLWithPath:path];

    if (![effect saveAudioPresetAtFileURL:fileURL]) return nil;

    return fileURL;
}


#pragma mark - Checks

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Opening a menu runs a modal tracking loop.  It is dismissed with a
        // queued Escape, and this is what happens if that ever stops working.
        alarm(90);

        // A bare executable gets its own CFPreferences domain, so this must not
        // be reading or writing the real app's defaults.
        printf("### defaults domain\n");

        NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];

        ckTrue("the harness is not on the app's defaults domain",
               ![bundleIdentifier isEqualToString:@"com.shaforostoff.opensource.EmbraceNG"] &&
               ![bundleIdentifier isEqualToString:@"com.ricciadams.opensource.Embrace"]);

        sForgetEverything();

        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"preset-menu-tests"];

        [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];

        EffectType *dynamicsType = sTypeNamed(@"AUDynamicsProcessor");
        EffectType *lowpassType  = sTypeNamed(@"AULowpass");

        ckTrue("AUDynamicsProcessor is available", dynamicsType != nil);
        ckTrue("AULowpass is available", lowpassType != nil);

        if (!dynamicsType || !lowpassType) {
            printf("\nFAILED  (cannot run without both effects)\n");
            return 1;
        }

        Effect *dynamics = [Effect effectWithEffectType:dynamicsType];
        Effect *lowpass  = [Effect effectWithEffectType:lowpassType];

        NSString *dynamicsKey = [dynamicsType fullName];
        NSString *lowpassKey  = [lowpassType  fullName];

        ckTrue("the two effects key on different names", ![dynamicsKey isEqualToString:lowpassKey]);

        // ------------------------------------------------------------------

        printf("\n### the menu the xib defines\n");

        TestSystemEffectController *controller =
            [[TestSystemEffectController alloc] initWithEffect:dynamics index:0];

        [controller window];

        NSMenu *menu = sActionsMenu(controller);

        ckTrue("EditSystemEffectWindow connects actionsMenu", menu != nil);
        ckTrue("and this controller is its delegate", (id)[menu delegate] == controller);

        NSArray *bare = @[ @"Item 1", @"Load Preset…", @"Save Preset…", @"-",
                           @"Restore Default Values", @"-", @"Bypass Effect" ];

        ckEqualArrays("an empty history adds nothing, not even a separator",
                      sMenuTitles(menu), bare);

        // ------------------------------------------------------------------

        printf("\n### one preset\n");

        NSURL *first = sMintPreset(dynamics, directory, @"Kick Control");
        ckTrue("a preset can be written", first != nil);

        NSInteger reloadsBefore = [controller reloadCount];

        sLoadPreset(controller, first);

        ckTrue("loading it is remembered",
               [sStoredPaths(dynamicsKey) isEqualToArray:@[ [first path] ]]);

        sOpenActionsMenu(controller);

        ckEqualArrays("it appears below Save Preset…, above the xib's separator",
                      sMenuTitles(menu),
                      (@[ @"Item 1", @"Load Preset…", @"Save Preset…", @"-",
                          @"Kick Control", @"-", @"Restore Default Values",
                          @"-", @"Bypass Effect" ]));

        ckTrue("loading it redrew the editor", [controller reloadCount] == reloadsBefore + 1);

        NSMenuItem *item = [menu itemAtIndex:4];

        ckTrue("the item loads a recent preset when chosen",
               [item action] == NSSelectorFromString(@"loadRecentPreset:") &&
               [item target] == controller);

        ckTrue("and carries the file it stands for",
               [[item representedObject] isEqual:first]);

        ckTrue("its tooltip is the path", [[item toolTip] length] > 0);

        ckTrue("the extension is not in the title",
               [[item title] rangeOfString:@"aupreset"].location == NSNotFound);

        // ------------------------------------------------------------------

        printf("\n### more presets than fit\n");

        NSMutableArray *minted = [NSMutableArray arrayWithObject:first];

        for (int i = 2; i <= 9; i++) {
            NSURL *url = sMintPreset(dynamics, directory, ([NSString stringWithFormat:@"Preset %d", i]));
            if (!url) continue;

            [minted addObject:url];
            sLoadPreset(controller, url);
        }

        ckTrue("nine presets were written", [minted count] == 9);

        sOpenActionsMenu(controller);

        ckEqualArrays("the last seven show, newest first",
                      [sMenuTitles(menu) subarrayWithRange:NSMakeRange(4, 7)],
                      (@[ @"Preset 9", @"Preset 8", @"Preset 7", @"Preset 6",
                          @"Preset 5", @"Preset 4", @"Preset 3" ]));

        ckTrue("and only seven are stored", [sStoredPaths(dynamicsKey) count] == 7);

        ckTrue("the menu is otherwise untouched",
               [sMenuTitles(menu) count] == [bare count] + 8);

        // ------------------------------------------------------------------

        printf("\n### using one again\n");

        sLoadPreset(controller, [minted objectAtIndex:4]);   // Preset 5
        sOpenActionsMenu(controller);

        ckEqualArrays("it moves to the front rather than repeating",
                      [sMenuTitles(menu) subarrayWithRange:NSMakeRange(4, 7)],
                      (@[ @"Preset 5", @"Preset 9", @"Preset 8", @"Preset 7",
                          @"Preset 6", @"Preset 4", @"Preset 3" ]));

        ckTrue("the list stays seven long", [sStoredPaths(dynamicsKey) count] == 7);

        // ------------------------------------------------------------------

        printf("\n### reopening the menu\n");

        NSArray *afterOneUpdate = sMenuTitles(menu);

        sOpenActionsMenu(controller);
        sOpenActionsMenu(controller);

        ckEqualArrays("rebuilding does not stack up copies", sMenuTitles(menu), afterOneUpdate);

        // ------------------------------------------------------------------

        printf("\n### a preset that has gone missing\n");

        NSURL *removed = [minted objectAtIndex:8];           // Preset 9
        [[NSFileManager defaultManager] removeItemAtPath:[removed path] error:NULL];

        sOpenActionsMenu(controller);

        ckEqualArrays("it drops out of the menu",
                      [sMenuTitles(menu) subarrayWithRange:NSMakeRange(4, 6)],
                      (@[ @"Preset 5", @"Preset 8", @"Preset 7", @"Preset 6",
                          @"Preset 4", @"Preset 3" ]));

        ckTrue("but is not forgotten -- remounting a volume brings it back",
               [sStoredPaths(dynamicsKey) containsObject:[removed path]]);

        // ------------------------------------------------------------------

        printf("\n### state the effect refuses\n");

        NSMutableDictionary *malformed = [[NSDictionary dictionaryWithContentsOfURL:[minted objectAtIndex:1]] mutableCopy];
        [malformed setObject:[NSMutableData dataWithLength:4] forKey:@"data"];

        NSString *malformedPath = [directory stringByAppendingPathComponent:@"Truncated.aupreset"];
        [malformed writeToFile:malformedPath atomically:YES];

        NSInteger reloadsBeforeRefusal = [controller reloadCount];
        NSArray  *storedBeforeRefusal  = sStoredPaths(dynamicsKey);

        ckTrue("the effect refuses a truncated blob",
               ![dynamics loadAudioPresetAtFileURL:[NSURL fileURLWithPath:malformedPath]]);

        sLoadPreset(controller, [NSURL fileURLWithPath:malformedPath]);
        sOpenActionsMenu(controller);

        ckEqualArrays("and it is not remembered", sStoredPaths(dynamicsKey), storedBeforeRefusal);
        ckTrue("nor is the editor redrawn", [controller reloadCount] == reloadsBeforeRefusal);

        ckTrue("a file that is not a preset at all is refused too",
               ![dynamics loadAudioPresetAtFileURL:[NSURL fileURLWithPath:@"/etc/hosts"]]);

        // ------------------------------------------------------------------

        printf("\n### a second effect type\n");

        TestGraphicEQEffectController *other =
            [[TestGraphicEQEffectController alloc] initWithEffect:lowpass index:1];

        [other window];

        NSMenu *otherMenu = sActionsMenu(other);

        ckTrue("EditGraphicEQEffectWindow connects actionsMenu too", otherMenu != nil);
        ckTrue("and this controller is its delegate", (id)[otherMenu delegate] == other);

        sOpenActionsMenu(other);

        ckEqualArrays("it does not inherit the other effect's presets",
                      sMenuTitles(otherMenu),
                      (@[ @"Item 1", @"Load Preset…", @"Save Preset…", @"-", @"Bypass Effect" ]));

        NSURL *lowpassPreset = sMintPreset(lowpass, directory, @"Rolloff");
        sLoadPreset(other, lowpassPreset);

        sOpenActionsMenu(other);

        ckEqualArrays("its own preset lands above its separator",
                      sMenuTitles(otherMenu),
                      (@[ @"Item 1", @"Load Preset…", @"Save Preset…", @"-",
                          @"Rolloff", @"-", @"Bypass Effect" ]));

        ckTrue("and the two lists stay apart",
               [sStoredPaths(lowpassKey) count] == 1 && [sStoredPaths(dynamicsKey) count] == 7);

        // ------------------------------------------------------------------

        printf("\n### a second window onto the same effect type\n");

        TestSystemEffectController *sameType =
            [[TestSystemEffectController alloc] initWithEffect:dynamics index:2];

        [sameType window];

        NSMenu *sameTypeMenu = sActionsMenu(sameType);
        sOpenActionsMenu(sameType);

        ckEqualArrays("it shows what the first window has been loading",
                      [sMenuTitles(sameTypeMenu) subarrayWithRange:NSMakeRange(4, 6)],
                      (@[ @"Preset 5", @"Preset 8", @"Preset 7", @"Preset 6",
                          @"Preset 4", @"Preset 3" ]));

        // ------------------------------------------------------------------

        sForgetEverything();
        [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];

        ckTrue("the harness leaves no defaults behind",
               [[NSUserDefaults standardUserDefaults] objectForKey:sRecentPresetsKey] == nil);

        printf("\n%s  (%d failures)\n", sFail ? "FAILED" : "all checks passed", sFail);
    }

    return sFail ? 1 : 0;
}
