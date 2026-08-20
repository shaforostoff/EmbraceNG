// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>


// See SecTranslocate.h in Security/libsecurity_translocate
// 
static Boolean  (*SecTranslocateIsTranslocatedURL)(CFURLRef path, bool *isTranslocated, CFErrorRef *error);
static CFURLRef (*SecTranslocateCreateOriginalPathForURL)(CFURLRef translocatedPath, CFErrorRef *error);

static void *sGetSecTranslocateSymbol(NSString *suffix)
{
    NSString *name = [NSString stringWithFormat:@"SecTranslocate%@", suffix];
    return dlsym(RTLD_NEXT, [name cStringUsingEncoding:NSUTF8StringEncoding]);
}


static NSURL *sGetRelaunchURL(NSURL *inURL)
{
    if (!SecTranslocateIsTranslocatedURL) {
        SecTranslocateIsTranslocatedURL = sGetSecTranslocateSymbol(@"IsTranslocatedURL");
    }
    
    if (!SecTranslocateCreateOriginalPathForURL) {
        SecTranslocateCreateOriginalPathForURL = sGetSecTranslocateSymbol(@"CreateOriginalPathForURL");
    }

    NSURL *originalURL = nil;
    CFURLRef cfURL = (__bridge CFURLRef)inURL;

    if (SecTranslocateIsTranslocatedURL && SecTranslocateCreateOriginalPathForURL) {
        bool isTranslocated = false;
        CFErrorRef error;
        SecTranslocateIsTranslocatedURL(cfURL, &isTranslocated, &error);
        
        if (isTranslocated) {
            originalURL = CFBridgingRelease(SecTranslocateCreateOriginalPathForURL(cfURL, &error));
        }
    }
    
    return originalURL ? originalURL : inURL;
}


@interface CrashPadAppDelegate : NSObject <NSApplicationDelegate>

@end


@implementation CrashPadAppDelegate {
    NSArray *_embracesAtLaunch;
    NSTimer *_timer;
}


- (void) _tick:(NSTimer *)timer
{
    for (NSRunningApplication *app in _embracesAtLaunch) {
        if (![app isTerminated]) {
            return;
        }
    }

    exit(0);
}


- (BOOL) _runAlertWithIcon:(NSImage *)icon
{
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];

    [alert setMessageText:    NSLocalizedString(@"EmbraceNG encountered a critical error.", nil)];
    [alert setInformativeText:NSLocalizedString(@"Your current song will continue to play, but you must reopen the app to play other songs or access other features.", nil)];
    [alert setIcon:icon];

    NSButton *reopenButton = [alert addButtonWithTitle:NSLocalizedString(@"Reopen",  nil)];
    NSButton *quitButton   = [alert addButtonWithTitle:NSLocalizedString(@"Quit", nil)];
        
    [reopenButton setKeyEquivalent:@""];
    [quitButton   setKeyEquivalent:@""];
        
    return [alert runModal] == NSAlertFirstButtonReturn;
}


- (void) applicationDidFinishLaunching:(NSNotification *)notification
{
    NSString *embraceBundleIdentifier = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"EmbraceBundleIdentifier"];
    
    _embracesAtLaunch = [NSRunningApplication runningApplicationsWithBundleIdentifier:embraceBundleIdentifier];

    _timer = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(_tick:) userInfo:nil repeats:YES];
    
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSDefaultRunLoopMode];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSImage *embraceIcon = [[_embracesAtLaunch lastObject] icon];
        
        BOOL restart = [self _runAlertWithIcon:embraceIcon];
        NSURL *bundleURL = nil;
        
        for (NSRunningApplication *app in _embracesAtLaunch) {
            bundleURL = sGetRelaunchURL([app bundleURL]);
            kill([app processIdentifier], 9);
        }

        if (restart && bundleURL) {
            NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
            [configuration setCreatesNewApplicationInstance:YES];
            [configuration setAllowsRunningApplicationSubstitution:NO];

            [[NSWorkspace sharedWorkspace] openApplicationAtURL: bundleURL
                                                  configuration: configuration
                                              completionHandler: ^(NSRunningApplication *app, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSApp terminate:self];
                });
            }];
        }

    });
}

@end


int main(int argc, const char * argv[])
{
@autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    CrashPadAppDelegate *appDelegate = [[CrashPadAppDelegate alloc] init];
    
    [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [application setDelegate:appDelegate];
    [application run];
    
}
    return 0;
}

