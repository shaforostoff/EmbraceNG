// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "EditEffectController.h"
#import "Effect.h"
#import "EffectAdditions.h"


@interface EditEffectController () <NSMenuItemValidation>
@end


@implementation EditEffectController {
    NSInteger _index;
}


- (id) initWithEffect:(Effect *)effect index:(NSInteger)index
{
    if ((self = [super init])) {
        _effect = effect;
        _index = index;
    }
    
    return self;
}


- (void) dealloc
{
    @try {
        [[self effect] removeObserver:self forKeyPath:@"bypass"];
    } @finally { }
}


- (void) windowDidLoad
{
    NSString *autosaveName = [NSString stringWithFormat:@"%@-%ld", [[_effect type] fullName], (long)_index];
    [[self window] setFrameAutosaveName:autosaveName];
    [[self window] setFrameUsingName:autosaveName];

    [self _updateTitle];

    [[self effect] addObserver:self forKeyPath:@"bypass" options:0 context:NULL];
}


- (BOOL) validateMenuItem:(NSMenuItem *)menuItem
{
    if ([menuItem action] == @selector(toggleBypass:)) {
        [menuItem setState:[[self effect] bypass] ? NSControlStateValueOn : NSControlStateValueOff];
    }

    return YES;
}


- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (object == [self effect]) {
        if ([keyPath isEqualToString:@"bypass"]) {
            [self _updateTitle];
        }
    }
}


- (void) _updateTitle
{
    NSString *name = [[_effect type] friendlyName];
    if (!name) name = NSLocalizedString(@"Effect", nil);

    if ([[self effect] bypass]) {
        NSString *bypassString = NSLocalizedString(@"(Bypassed)", nil);
        name = [NSString stringWithFormat:@"%@ %@", name, bypassString];
    }

    [[self window] setTitle:name];
}


- (NSURL *) _urlForPresetDirectory
{
    NSString *allPresets = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    allPresets = [allPresets stringByAppendingPathComponent:@"Audio"];
    allPresets = [allPresets stringByAppendingPathComponent:@"Presets"];

    NSString *manufacturer = [[_effect type] manufacturer];
    NSString *name = [[_effect type] name];

    NSString *unitPresets = nil;
    
    if (name && manufacturer) {
        unitPresets = [allPresets stringByAppendingPathComponent:manufacturer];
        unitPresets = [unitPresets stringByAppendingPathComponent:name];
    }

    BOOL allExists = NO,      unitExists = NO;
    BOOL allIsDirectory = NO, unitIsDirectory = NO;
    
    allExists  = [[NSFileManager defaultManager] fileExistsAtPath:allPresets  isDirectory:&allIsDirectory];
    unitExists = [[NSFileManager defaultManager] fileExistsAtPath:unitPresets isDirectory:&unitIsDirectory];

    NSURL *result = nil;

    if (unitExists && unitIsDirectory) {
        result = [NSURL fileURLWithPath:unitPresets];
    } else if (allExists && allIsDirectory) {
        result = [NSURL fileURLWithPath:allPresets];
    }

    return result;
}


#pragma mark - IBActions

- (IBAction) loadPreset:(id)sender
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];

    [openPanel setTitle:NSLocalizedString(@"Load Preset", nil)];
    
    NSURL *url = [self _urlForPresetDirectory];
    [openPanel setDirectoryURL:url];

    __weak id weakSelf = self;
    __weak id weakEffect = _effect;

    [openPanel beginWithCompletionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            [weakEffect loadAudioPresetAtFileURL:[openPanel URL]];
            [weakSelf reloadData];
        }
    }];
}


- (IBAction) savePreset:(id)sender
{
    NSSavePanel *savePanel = [NSSavePanel savePanel];

    [savePanel setTitle:NSLocalizedString(@"Save Preset", nil)];

    NSURL *url = [self _urlForPresetDirectory];
    [savePanel setDirectoryURL:url];
    [savePanel setAllowedFileTypes:@[ @"aupreset" ]];
    [savePanel setNameFieldStringValue:NSLocalizedString(@"Preset", nil)];

    __weak id weakEffect = _effect;

    [savePanel beginWithCompletionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            [weakEffect saveAudioPresetAtFileURL:[savePanel URL]];
        }
    }];
}


- (IBAction) restoreDefaultValues:(id)sender
{
    [[self effect] restoreDefaultValues];
    [self reloadData];
}


- (IBAction) toggleBypass:(id)sender
{
    BOOL bypass = [[self effect] bypass];
    [[self effect] setBypass:!bypass];
}


- (void) reloadData
{
    // Subclasses to override
}


@end
