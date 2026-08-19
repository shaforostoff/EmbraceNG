// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "EffectsController.h"

#import "EditEffectController.h"
#import "AppDelegate.h"
#import "EffectType.h"
#import "Effect.h"
#import "EffectAdditions.h"
#import "Player.h"
#import "Preferences.h"


typedef NS_ENUM(NSInteger, EffectCategory) {
    EffectCategoryRestoration = 1,
    EffectCategoryEqualizers,
    EffectCategoryFilters,
    EffectCategoryDynamics,
    EffectCategoryOther
};


static EffectCategory sGetCategory(NSString *name)
{
    EffectCategory result = EffectCategoryOther;

    NSDictionary *map = @{
        @"EmbraceDeclick":        @( EffectCategoryRestoration ),
        @"EmbraceDehum":          @( EffectCategoryRestoration ),

        @"EmbraceGraphicEQ10":    @( EffectCategoryEqualizers ),
        @"EmbraceGraphicEQ31":    @( EffectCategoryEqualizers ),
        @"EmbraceParametricEQ":   @( EffectCategoryEqualizers ),

        @"AUBandpass":            @( EffectCategoryFilters ),
        @"AUParametricEQ":        @( EffectCategoryFilters ),
        @"AULowpass":             @( EffectCategoryFilters ),
        @"AULowShelfFilter":      @( EffectCategoryFilters ),
        @"AUHipass":              @( EffectCategoryFilters ),
        @"AUHighShelfFilter":     @( EffectCategoryFilters ),
        @"AUFilter":              @( EffectCategoryFilters ),

        @"AUDynamicsProcessor":   @( EffectCategoryDynamics ),
        @"AUMultibandCompressor": @( EffectCategoryDynamics ),
        @"AUPeakLimiter":         @( EffectCategoryDynamics )
    };

    NSNumber *categoryNumber = [map objectForKey:name];
    if (categoryNumber) {
        result = [categoryNumber integerValue];
    }

    return result;
}


@interface EffectsController () <NSMenuDelegate>


- (IBAction) addEffect:(id)sender;
- (IBAction) editEffect:(id)sender;
- (IBAction) delete:(id)sender;

- (IBAction) updateStereoBalance:(id)sender;

@property (nonatomic, strong) IBOutlet NSArrayController *effectsArrayController;

@property (nonatomic, strong) IBOutlet NSMenu *tableMenu;

@property (nonatomic, weak) IBOutlet NSPopUpButton *addButton;

@property (nonatomic, weak) IBOutlet NSTableView *tableView;


@end


@implementation EffectsController {
    NSArray *_advancedMenuItems;
}

@dynamic player;


- (NSString *) windowNibName
{
    return @"EffectsWindow";
}


- (void) dealloc
{
    [[self effectsArrayController] removeObserver:self forKeyPath:@"selectionIndexes" context:NULL];
}


- (void) windowDidLoad
{
    [super windowDidLoad];
   
    [[self tableView] setDoubleAction:@selector(editEffect:)];

    [[self window] setExcludedFromWindowsMenu:YES];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handlePreferencesDidChange:) name:PreferencesDidChangeNotification object:nil];
    
    [self _buildAddButtonMenu];
    [self _updateMenuItemVisibility];
}


#pragma mark - Private Methods

- (void) _buildAddButtonMenu
{
    NSMenu *menu = [[self addButton] menu];
    NSMenu *filterMenu = [[NSMenu alloc] init];

    NSArray *allEffectTypes = [EffectType allEffectTypes];
    
    allEffectTypes = [allEffectTypes sortedArrayUsingComparator:^(id objectA, id objectB) {
        EffectType *typeA = (EffectType *)objectA;
        EffectType *typeB = (EffectType *)objectB;
        
        EffectCategory categoryA = sGetCategory([typeA name]);
        EffectCategory categoryB = sGetCategory([typeB name]);
        
        if (categoryA > categoryB) {
            return NSOrderedDescending;
        } else if (categoryB > categoryA) {
            return NSOrderedAscending;
        } else {
            NSString *nameA = [typeA friendlyName];
            NSString *nameB = [typeB friendlyName];
            
            return [nameA compare:nameB];
        }
    }];
    
    EffectCategory lastCategory = 0;
    
    BOOL didAddItem = NO;

    NSMutableDictionary *manufacturerToItemArrayMap = [NSMutableDictionary dictionary];

    for (EffectType *type in allEffectTypes) {
        NSString *name = [type name];
        EffectCategory category = sGetCategory(name);
        NSString *friendlyName = [type friendlyName];

        if (category != lastCategory) {
            if (didAddItem) {
                [menu addItem:[NSMenuItem separatorItem]];
            }

            lastCategory = category;
        }
    
        NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:friendlyName action:NULL keyEquivalent:@""];
        [menuItem setRepresentedObject:type];

        if (category == EffectCategoryOther) {
            NSString *manufacturer = [type manufacturer];
        
            [menuItem setTarget:[[self addButton] target]];
            [menuItem setAction:[[self addButton] action]];

            NSMutableArray *itemArray = [manufacturerToItemArrayMap objectForKey:manufacturer];
            
            if (!itemArray) {
                itemArray = [NSMutableArray array];
                [manufacturerToItemArrayMap setObject:itemArray forKey:manufacturer];
            }
            
            [itemArray addObject:menuItem];          

        } else if (category == EffectCategoryFilters) {
            [filterMenu addItem:menuItem];
            
            [menuItem setTarget:[[self addButton] target]];
            [menuItem setAction:[[self addButton] action]];

        } else {
            [menu addItem:menuItem];
        }

        didAddItem = YES;
    }

    // Add "Filters" menu
    {
        NSMenuItem *filterMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Filters", nil) action:nil keyEquivalent:@""];
        [filterMenuItem setSubmenu:filterMenu];
        [filterMenu setAutoenablesItems:NO];

        [menu addItem:filterMenuItem];
    }

    NSMutableArray *advancedMenuItems = [NSMutableArray array];
    NSMutableArray *remainingItems    = [NSMutableArray array];

    // Add separator
    {
        NSMenuItem *separatorItem = [NSMenuItem separatorItem];
        [advancedMenuItems addObject:separatorItem];
        [menu addItem:separatorItem];
    }

    // Add manufacturer menus
    for (NSString *manufacturer in [[manufacturerToItemArrayMap allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray *itemArray = [manufacturerToItemArrayMap objectForKey:manufacturer];
        
        if ([itemArray count] > 2) {
            NSMenu     *brandMenu     = [[NSMenu alloc] init];
            NSMenuItem *brandMenuItem = [[NSMenuItem alloc] initWithTitle:manufacturer action:nil keyEquivalent:@""];
            [brandMenuItem setSubmenu:brandMenu];

            for (NSMenuItem *item in itemArray) {
                [brandMenu addItem:item];
            }

            [brandMenu setAutoenablesItems:NO];

            [menu addItem:brandMenuItem];
            [advancedMenuItems addObject:brandMenuItem];

        } else {
            [remainingItems addObjectsFromArray:itemArray];
        }
    }

    // Add Other menu
    {
        [remainingItems sortUsingComparator:^(id objectA, id objectB) {
            NSMenuItem *itemA = (NSMenuItem *)objectA;
            NSMenuItem *itemB = (NSMenuItem *)objectB;
            
            return [[itemA title] compare:[itemB title]];
        }];

        NSMenu     *otherMenu     = [[NSMenu alloc] init];
        NSMenuItem *otherMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Others", nil) action:nil keyEquivalent:@""];
        [otherMenuItem setSubmenu:otherMenu];

        for (NSMenuItem *item in remainingItems) {
            [otherMenu addItem:item];
        }

        [otherMenu setAutoenablesItems:NO];

        [menu addItem:otherMenuItem];
        [advancedMenuItems addObject:otherMenuItem];
    }
    
    _advancedMenuItems = advancedMenuItems;

    for (NSMenuItem *item in advancedMenuItems) {
        [item setHidden:YES];
    }
}


- (void) _updateMenuItemVisibility
{
    BOOL hidden = ![[Preferences sharedInstance] allowsAllEffects];

    for (NSMenuItem *item in _advancedMenuItems) {
        [item setHidden:hidden];
    }
}


- (void) _handlePreferencesDidChange:(NSNotification *)note
{
    [self _updateMenuItemVisibility];
}


#pragma mark - IBActions

- (IBAction) addEffect:(id)sender
{
    id representedObject = nil;

    if ([sender isKindOfClass:[NSPopUpButton class]]) {
        representedObject = [[sender selectedItem] representedObject];
    } else {
        representedObject = [sender representedObject];
    }

    EffectType *type = representedObject;
    
    Effect *effect = [Effect effectWithEffectType:type];
    if (effect) [[self effectsArrayController] addObject:effect];
}


- (IBAction) editEffect:(id)sender
{
    Effect *selectedEffect = [[[self effectsArrayController] selectedObjects] lastObject];

    if ([selectedEffect audioUnitError]) {
        NSAlert *alert = [[NSAlert alloc] init];
        
        [alert setMessageText:NSLocalizedString(@"Could not load Effect", nil)];
        [alert setInformativeText:NSLocalizedString(@"Contact the effect's manufacturer for a sandbox-compliant version.", nil)];
        
        [alert runModal];
        
    } else if (selectedEffect) {
        [[GetAppDelegate() editControllerForEffect:selectedEffect] showWindow:self];
    }
}


- (void) delete:(id)sender
{
    NSArrayController *arrayController = [self effectsArrayController];

    NSArray *selectedObjects = [arrayController selectedObjects];
    
    for (Effect *effect in selectedObjects) {
        [GetAppDelegate() closeEditControllerForEffect:effect];
    }
    
    [arrayController removeObjects:selectedObjects];
}


- (IBAction) updateStereoBalance:(id)sender
{
    double doubleValue = [sender doubleValue];

    if (doubleValue >= 0.48 && doubleValue <= 0.52) {
        [sender setDoubleValue:0.5];
    }
}


#pragma mark - Accessors

- (Player *) player
{
    return [Player sharedInstance];
}


@end
