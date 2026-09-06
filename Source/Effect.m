// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "Effect.h"
#import "EffectType.h"
#import "Player.h"
#import "EditEffectController.h"
#import "AudioUnitStateValidation.h"
#import "Log.h"

static NSString *sNameKey = @"name";
static NSString *sInfoKey = @"info";
static NSString *sUUIDKey = @"UUID";

NSString * const EffectDidDeallocNotification = @"EffectDidDealloc";


@implementation Effect {
    EffectType   *_type;
    NSDictionary *_defaultFullState;
    EffectSettingsController *_settingsController;
}

@dynamic hasCustomView;


// Everything that reaches -setFullState: comes from a file: a saved set list,
// a user-chosen .aupreset, or our own bundle.  Apple's units crash on a
// malformed blob rather than rejecting it, so screen it here.
//
- (BOOL) _applyFullState:(NSDictionary *)fullState toAudioUnit:(AUAudioUnit *)audioUnit
{
    if (!fullState || !audioUnit) return NO;

    if (!EmbraceAudioUnitFullStateIsWellFormed(fullState, [audioUnit componentDescription])) {
        EmbraceLog(@"Effect", @"Refusing malformed state for %@, keeping current values", [_type name]);
        return NO;
    }

    // Apple's N-band EQ editor crashes if the band count moves underneath it,
    // so a preset never gets to change it.
    NSDictionary *stateToApply = EmbraceAudioUnitFullStateByPreservingBandCount(fullState, audioUnit);

    if (stateToApply != fullState) {
        EmbraceLog(@"Effect", @"Preserving band count for %@ across state change", [_type name]);
    }

    [audioUnit setFullState:stateToApply];

    return YES;
}


+ (instancetype) effectWithStateDictionary:(NSDictionary *)dictionary
{
    return [[self alloc] initWithStateDictionary:dictionary];
}


+ (instancetype) effectWithEffectType:(EffectType *)effectType
{
    return [[self alloc] _initWithEffectType:effectType UUID:nil];
}


- (id) _initWithEffectType:(EffectType *)effectType UUID:(NSUUID *)UUID
{
    if ((self = [super init])) {
        _type = effectType;
        _UUID = UUID ? UUID : [NSUUID UUID];
        
        NSError *error = nil;
        _audioUnit = [[AUAudioUnit alloc] initWithComponentDescription:[effectType AudioComponentDescription] error:&error];
        _audioUnitError = error;

        if (_audioUnit) {
            MappedEffectTypeConfigurator configurator = [effectType configurator];
            if (configurator) configurator(_audioUnit);
        }

        NSString *defaultPresetPath = [[NSBundle mainBundle] pathForResource:[[self type] name] ofType:@"aupreset"];
        if (defaultPresetPath) {
            NSDictionary *defaultPreset = [NSDictionary dictionaryWithContentsOfFile:defaultPresetPath];
            [self _applyFullState:defaultPreset toAudioUnit:_audioUnit];
        }

        _defaultFullState = [_audioUnit fullState];
    }
    
    return self;
}


- (id) initWithEffectType:(EffectType *)effectType
{
    return [self _initWithEffectType:effectType UUID:nil];
}


- (id) initWithStateDictionary:(NSDictionary *)dictionary
{
    NSString *name       = [dictionary objectForKey:sNameKey];
    NSData   *info       = [dictionary objectForKey:sInfoKey];
    NSString *UUIDString = [dictionary objectForKey:sUUIDKey];

    if (
                       ![name isKindOfClass:[NSString class]] ||
        (info       && ![info isKindOfClass:[NSData class]]) ||
        (UUIDString && ![UUIDString isKindOfClass:[NSString class]])
    ) {
        self = nil;
        return nil;
    }
    
    EffectType *typeToUse = nil;

    for (EffectType *type in [EffectType allEffectTypes]) {
        if ([[type name] isEqualToString:name]) {
            typeToUse = type;
        }
    }
    
    if (!typeToUse) {
        self = nil;
        return nil;
    }
    
    NSUUID *UUID = UUIDString ? [[NSUUID alloc] initWithUUIDString:UUIDString] : nil;
    
    self = [self _initWithEffectType:typeToUse UUID:UUID];
 
    if (info) {
        NSError *error = nil;
        
        NSDictionary *fullState = [NSPropertyListSerialization propertyListWithData:info options:NSPropertyListImmutable format:NULL error:&error];

        if (!fullState || error) {
            self = nil;
            return nil;
        }

        // A set list whose stored state is malformed still names a real
        // effect, so keep the effect in the chain at its default settings
        // rather than dropping it and silently changing the signal path.
        [self _applyFullState:fullState toAudioUnit:_audioUnit];
    }

    return self;
}


- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] postNotificationName:EffectDidDeallocNotification object:nil];
}


#pragma mark - Private Methods

- (void) _setFullState:(NSDictionary *)fullState
{
    if (![self _applyFullState:fullState toAudioUnit:_audioUnit]) return;

    // As of 10.14, -setFullState: appears to not update the AUParameter's -value, which
    // is likely a caching bug in Apple's code. To get around this, create a fake AUAudioUnit
    // of the same componentDescription, call -setFullState: on it, and then send -setValue:
    // to our real AUParameter objects
    //
    NSError *error = nil;
    AUAudioUnit *fakeUnit = [[AUAudioUnit alloc] initWithComponentDescription:[_audioUnit componentDescription] error:&error];

    if (!error) {
        [self _applyFullState:fullState toAudioUnit:fakeUnit];
        
        for (AUParameter *fakeParameter in [[fakeUnit parameterTree] allParameters]) {
            AUParameter *realParameter = [[_audioUnit parameterTree] parameterWithAddress:[fakeParameter address]];
            [realParameter setValue:[fakeParameter value] originator:NULL];
        }
    }
}


#pragma mark - Public Methods

- (void) loadAudioPresetAtFileURL:(NSURL *)fileURL
{
    NSDictionary *dictionary = [NSDictionary dictionaryWithContentsOfURL:fileURL];
    if (!dictionary) return;

    [self _setFullState:dictionary];
}


- (BOOL) saveAudioPresetAtFileURL:(NSURL *)fileURL
{
    return [[_audioUnit fullState] writeToURL:fileURL atomically:YES];
}


- (void) restoreDefaultValues
{
    [self _setFullState:_defaultFullState];
}


- (NSDictionary *) stateDictionary
{
    NSDictionary *fullState = [_audioUnit fullState];
    if (!fullState) fullState = [NSDictionary dictionary];
    
    NSError  *error = nil;
    NSString *name  = [_type name];
    NSData   *info  = [NSPropertyListSerialization dataWithPropertyList:fullState format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    
    if (error || !info || !name) return nil;
    
    return @{
        sNameKey: name,
        sInfoKey: info,
        sUUIDKey: [_UUID UUIDString]
    };
}


#pragma mark - Accessors

- (BOOL) hasCustomView
{
    return [_audioUnit providesUserInterface];
}


- (void) setBypass:(BOOL)bypass
{
    [_audioUnit setShouldBypassEffect:bypass];
}


- (BOOL) bypass
{
    return [_audioUnit shouldBypassEffect];
}

@end

