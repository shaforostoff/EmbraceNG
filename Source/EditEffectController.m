// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "EditEffectController.h"
#import "Effect.h"
#import "EffectAdditions.h"


// Presets the user has loaded or saved, most recent first.  Kept per effect
// type -- an .aupreset only means anything to the unit that wrote it -- as
// NSUserDefaults[sRecentPresetsKey] = { effect type full name: [ path, ... ] }.
//
static NSString * const sRecentPresetsKey     = @"recent-presets";
static const NSUInteger sMaximumRecentPresets = 7;

// Marks the items -_updateRecentPresetsInMenu: owns, so a rebuild can pull its
// previous ones back out without disturbing what the xib puts there.
//
static const NSInteger sRecentPresetTag = 8001;


static NSArray<NSString *> *sGetRecentPresetPaths(NSString *typeName)
{
    if (!typeName) return @[ ];

    NSDictionary *pathsByType = [[NSUserDefaults standardUserDefaults] objectForKey:sRecentPresetsKey];
    if (![pathsByType isKindOfClass:[NSDictionary class]]) return @[ ];

    NSArray *paths = [pathsByType objectForKey:typeName];
    if (![paths isKindOfClass:[NSArray class]]) return @[ ];

    NSMutableArray *result = [NSMutableArray array];

    for (NSString *path in paths) {
        if ([path isKindOfClass:[NSString class]]) [result addObject:path];
    }

    return result;
}


static void sAddRecentPresetPath(NSString *typeName, NSURL *fileURL)
{
    NSString *path = [[fileURL URLByStandardizingPath] path];
    if (!typeName || !path) return;

    NSMutableArray *paths = [sGetRecentPresetPaths(typeName) mutableCopy];

    // Re-using a preset moves it to the front rather than listing it twice
    [paths removeObject:path];
    [paths insertObject:path atIndex:0];

    while ([paths count] > sMaximumRecentPresets) {
        [paths removeLastObject];
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSDictionary *oldPathsByType = [defaults objectForKey:sRecentPresetsKey];

    NSMutableDictionary *pathsByType = [oldPathsByType isKindOfClass:[NSDictionary class]] ?
        [oldPathsByType mutableCopy] :
        [NSMutableDictionary dictionary];

    [pathsByType setObject:paths forKey:typeName];

    [defaults setObject:pathsByType forKey:sRecentPresetsKey];
}


static NSInteger sIndexOfItemWithAction(NSMenu *menu, SEL action)
{
    NSInteger count = [menu numberOfItems];

    for (NSInteger i = 0; i < count; i++) {
        if ([[menu itemAtIndex:i] action] == action) return i;
    }

    return -1;
}


@interface EditEffectController () <NSMenuItemValidation, NSMenuDelegate>

@property (nonatomic, weak) IBOutlet NSMenu *actionsMenu;

- (IBAction) loadRecentPreset:(id)sender;

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

    // The recent presets are shared by every window onto this effect type, so
    // the menu is rebuilt each time it opens rather than held.  Only a real
    // tracking session asks the delegate: -[NSMenu update] does not.
    //
    [_actionsMenu setDelegate:self];

    [[self effect] addObserver:self forKeyPath:@"bypass" options:0 context:NULL];
}


- (BOOL) validateMenuItem:(NSMenuItem *)menuItem
{
    if ([menuItem action] == @selector(toggleBypass:)) {
        [menuItem setState:[[self effect] bypass] ? NSControlStateValueOn : NSControlStateValueOff];
    }

    return YES;
}


- (void) menuNeedsUpdate:(NSMenu *)menu
{
    [self _updateRecentPresetsInMenu:menu];
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


- (NSArray<NSURL *> *) _recentPresetFileURLs
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray *result = [NSMutableArray array];

    // A preset can be missing without being forgotten -- remounting the volume
    // it lives on brings it back -- so this filters the menu, not the list.
    //
    for (NSString *path in sGetRecentPresetPaths([[_effect type] fullName])) {
        if ([fileManager fileExistsAtPath:path]) {
            [result addObject:[NSURL fileURLWithPath:path]];
        }
    }

    return result;
}


- (void) _updateRecentPresetsInMenu:(NSMenu *)menu
{
    for (NSInteger i = [menu numberOfItems] - 1; i >= 0; i--) {
        if ([[menu itemAtIndex:i] tag] == sRecentPresetTag) {
            [menu removeItemAtIndex:i];
        }
    }

    NSArray<NSURL *> *fileURLs = [self _recentPresetFileURLs];
    if (![fileURLs count]) return;

    // Below Save Preset…, and above the separator the xib already has there
    NSInteger index = sIndexOfItemWithAction(menu, @selector(savePreset:));
    if (index < 0) index = sIndexOfItemWithAction(menu, @selector(loadPreset:));
    if (index < 0) return;

    index++;

    NSMenuItem *separator = [NSMenuItem separatorItem];
    [separator setTag:sRecentPresetTag];
    [menu insertItem:separator atIndex:index++];

    for (NSURL *fileURL in fileURLs) {
        NSString *title = [[fileURL lastPathComponent] stringByDeletingPathExtension];

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(loadRecentPreset:) keyEquivalent:@""];

        [item setTarget:self];
        [item setRepresentedObject:fileURL];
        [item setToolTip:[[fileURL path] stringByAbbreviatingWithTildeInPath]];
        [item setTag:sRecentPresetTag];

        [menu insertItem:item atIndex:index++];
    }
}


- (void) _loadPresetAtFileURL:(NSURL *)fileURL
{
    if (![[self effect] loadAudioPresetAtFileURL:fileURL]) return;

    sAddRecentPresetPath([[_effect type] fullName], fileURL);

    [self reloadData];
}


#pragma mark - IBActions

- (IBAction) loadPreset:(id)sender
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];

    [openPanel setTitle:NSLocalizedString(@"Load Preset", nil)];
    
    NSURL *url = [self _urlForPresetDirectory];
    [openPanel setDirectoryURL:url];

    __weak id weakSelf = self;

    [openPanel beginWithCompletionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            [weakSelf _loadPresetAtFileURL:[openPanel URL]];
        }
    }];
}


- (IBAction) loadRecentPreset:(id)sender
{
    NSURL *fileURL = [sender representedObject];
    if (!fileURL) return;

    [self _loadPresetAtFileURL:fileURL];
}


- (IBAction) savePreset:(id)sender
{
    NSSavePanel *savePanel = [NSSavePanel savePanel];

    [savePanel setTitle:NSLocalizedString(@"Save Preset", nil)];

    NSURL *url = [self _urlForPresetDirectory];
    [savePanel setDirectoryURL:url];
    [savePanel setAllowedFileTypes:@[ @"aupreset" ]];
    [savePanel setNameFieldStringValue:NSLocalizedString(@"Preset", nil)];

    NSString *typeName = [[_effect type] fullName];

    __weak id weakEffect = _effect;

    [savePanel beginWithCompletionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            NSURL *fileURL = [savePanel URL];

            if ([weakEffect saveAudioPresetAtFileURL:fileURL]) {
                sAddRecentPresetPath(typeName, fileURL);
            }
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
