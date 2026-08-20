// (c) 2017-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "ScriptsManager.h"
#import "FileSystemMonitor.h"
#import "Preferences.h"
#import "ScriptFile.h"
#import "Track.h"


NSString * const ScriptsManagerDidReloadNotification = @"ScriptsManagerDidReload";


@implementation ScriptsManager {
    NSArray *_allScriptFiles;
    NSAppleScript *_handlerScript;
    FileSystemMonitor *_monitor;
}

static NSArray *sGetScriptFileTypes()
{
    return @[
        @"com.apple.applescript.script",
        @"com.apple.applescript.text",
        @"com.apple.applescript.script-bundle"
    ];
}


+ (id) sharedInstance
{
    static ScriptsManager *sSharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sSharedInstance = [[ScriptsManager alloc] init];
    });

    return sSharedInstance;
}


- (instancetype) init
{
    if ((self = [super init])) {
        [self _setup];
        [self _reloadScripts];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handlePreferencesDidChange:) name:PreferencesDidChangeNotification object:nil];

        // This is public API, use "com.iccir.Embrace" even if our bundle ID is "com.shaforostoff.opensource.EmbraceNG"
        [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(_handlePlayerUpdate:) name:@"com.iccir.Embrace.playerUpdate" object:nil];
    }
    
    return self;
}


#pragma mark - Private Methods

- (void) _setup
{
    NSFileManager *manager = [NSFileManager defaultManager];

    NSURL *handlersDirectoryURL  = [self _scriptsDirectoryURL];
    
    if (![manager fileExistsAtPath:[handlersDirectoryURL path]]) {
        NSError *error = nil;
        [manager createDirectoryAtURL:handlersDirectoryURL withIntermediateDirectories:YES attributes:nil error:&error];
    }
    
    _monitor = [[FileSystemMonitor alloc] initWithURL:handlersDirectoryURL callback:^(NSArray *events) {
        [self _reloadScripts];
        [[NSNotificationCenter defaultCenter] postNotificationName:ScriptsManagerDidReloadNotification object:nil];
    }];
    
    [_monitor start];
}


- (NSURL *) _scriptsDirectoryURL
{
    NSString *appSupport = GetApplicationSupportDirectory();
    
    return [NSURL fileURLWithPath:[appSupport stringByAppendingPathComponent:@"Scripts"]];
}


- (void) _reloadScripts
{
    EmbraceLogMethod();

    NSURL *scriptsDirectoryURL = [self _scriptsDirectoryURL];

    NSError *dirError = nil;
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[scriptsDirectoryURL path] error:&dirError];
   
    if (dirError) {
        EmbraceLog(@"ScriptsManager", @"Could not list handlers: %@", dirError);
    } else {
        EmbraceLog(@"ScriptsManager", @"Handler list: %@", contents);
    }
   
    NSMutableArray *scriptFiles = [NSMutableArray array];

    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];

    for (NSString *item in contents) {
        if ([item hasPrefix:@"."]) continue;

        NSURL    *scriptURL = [scriptsDirectoryURL URLByAppendingPathComponent:item];
        NSString *type      = nil;
        NSError  *error     = nil;

        if ([scriptURL getResourceValue:&type forKey:NSURLTypeIdentifierKey error:&error]) {
            EmbraceLog(@"ScriptsManager", @"Handler '%@' has type: '%@'", scriptURL, type);

            for (NSString *scriptType in sGetScriptFileTypes()) {
                if ([workspace type:type conformsToType:scriptType]) {
                    ScriptFile *scriptFile = [[ScriptFile alloc] initWithURL:scriptURL];
                    [scriptFiles addObject:scriptFile];
                    break;
                }
            }

        } else {
            EmbraceLog(@"ScriptsManager", @"Could not get resource type of '%@': '%@'", scriptURL, error);
        }
    }
    
    _allScriptFiles = scriptFiles;

    [self _updateHandlerScriptFile];
}


- (void) _updateHandlerScriptFile
{
    EmbraceLogMethod();

    NSString *scriptHandlerName = [[Preferences sharedInstance] scriptHandlerName];
    EmbraceLog(@"ScriptsManager", @"scriptHandlerName is '%@'", scriptHandlerName);
    
    if (![scriptHandlerName length]) {
        scriptHandlerName = nil;
    }

    _handlerScript     = nil;
    _handlerScriptFile = nil;

    for (ScriptFile *file in _allScriptFiles) {
        if (scriptHandlerName && [[file fileName] isEqualToString:scriptHandlerName]) {
            EmbraceLog(@"ScriptsManager", @"Found matching handler: '%@'", [file fileName]);
            _handlerScriptFile = file;
            break;
        }
    }
    
    if (_handlerScriptFile) {
        NSDictionary *errorInfo = nil;

        _handlerScript = [[NSAppleScript alloc] initWithContentsOfURL:[_handlerScriptFile URL] error:&errorInfo];
        if (errorInfo) {
            [self _logErrorInfo:errorInfo when:@"loading" scriptFile:_handlerScriptFile];
        }
    }
}


- (NSAppleScript *) _handlerScript
{
    if (![_handlerScript isCompiled]) {
        NSDictionary *errorInfo = nil;
        [_handlerScript compileAndReturnError:&errorInfo];

        if (errorInfo) {
            [self _logErrorInfo:errorInfo when:@"compiling" scriptFile:_handlerScriptFile];
        }
    }
    
    return _handlerScript;
}


- (void) _logErrorInfo:(NSDictionary *)errorInfo when:(NSString *)whenString scriptFile:(ScriptFile *)scriptFile
{
    NSString *errorNumber  = [errorInfo objectForKey:NSAppleScriptErrorNumber];
    NSNumber *errorMessage = [errorInfo objectForKey:NSAppleScriptErrorMessage];
    
    NSString *finalString = [NSString stringWithFormat:@"Error %@ when %@ '%@': %@", errorNumber, whenString, [scriptFile fileName], errorMessage];

    NSLog(@"%@", finalString);
    EmbraceLog(@"ScriptsManager", @"%@", finalString);
}


- (void) _handlePreferencesDidChange:(NSNotification *)note
{
    NSString *scriptHandlerName = [[Preferences sharedInstance] scriptHandlerName];

    if (![scriptHandlerName length]) {
        scriptHandlerName = nil;
    }

    if (scriptHandlerName) {
        if (![[_handlerScriptFile fileName] isEqual:scriptHandlerName]) {
            [self _updateHandlerScriptFile];
        }

    } else {
        if (_handlerScriptFile) {
            [self _updateHandlerScriptFile];
        }
    }
}


- (void) _handlePlayerUpdate:(NSNotification *)note
{
    [self callCurrentTrackChanged];
}


#pragma mark - Public Methods

- (void) callMetadataAvailableWithTrack:(Track *)track
{
    NSAppleScript *handlerScript = [self _handlerScript];
    if (!handlerScript) return;
    
    NSAppleEventDescriptor *param  = [[track objectSpecifier] descriptor];
    if (!param) return;
    
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor nullDescriptor];
    if (!target) return;

    NSAppleEventDescriptor *appleEvent = [[NSAppleEventDescriptor alloc] initWithEventClass:'embr' eventID:'he00' targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    if (!appleEvent) return;

    [appleEvent setParamDescriptor:param forKeyword:'hetr'];

    NSDictionary *errorInfo = nil;
    
    [handlerScript executeAppleEvent:appleEvent error:&errorInfo];
    
    if (errorInfo) {
        [self _logErrorInfo:errorInfo when:@"running" scriptFile:_handlerScriptFile];
    }
}


- (void) callCurrentTrackChanged
{
    NSAppleScript *handlerScript = [self _handlerScript];
    if (!handlerScript) return;
    
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor nullDescriptor];
    if (!target) return;

    NSAppleEventDescriptor *appleEvent = [[NSAppleEventDescriptor alloc] initWithEventClass:'embr' eventID:'he01' targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    if (!appleEvent) return;

    NSDictionary *errorInfo = nil;
    
    [handlerScript executeAppleEvent:appleEvent error:&errorInfo];
    
    if (errorInfo) {
        [self _logErrorInfo:errorInfo when:@"running" scriptFile:_handlerScriptFile];
    }
}


- (void) revealScriptsFolder
{
    [[NSWorkspace sharedWorkspace] openURL:[self _scriptsDirectoryURL]];
}


@end
