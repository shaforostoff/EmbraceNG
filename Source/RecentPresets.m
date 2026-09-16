// (c) 2026 Nick Shaforostov
// MIT License (or) 1-clause BSD License

#import "RecentPresets.h"

// NSUserDefaults[sRecentPresetsKey] = { effect type full name: [ path, ... ] }
static NSString * const sRecentPresetsKey     = @"recent-presets";
static const NSUInteger sMaximumRecentPresets = 7;


NSUInteger GetMaximumRecentPresetCount(void)
{
    return sMaximumRecentPresets;
}


NSArray<NSString *> *GetRecentPresetPaths(NSString *typeName)
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


void AddRecentPresetPath(NSString *typeName, NSURL *fileURL)
{
    NSString *path = [[fileURL URLByStandardizingPath] path];
    if (!typeName || !path) return;

    NSMutableArray *paths = [GetRecentPresetPaths(typeName) mutableCopy];

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


NSURL *GetRecentPresetFileURLWithName(NSString *typeName, NSString *name)
{
    if (![name length]) return nil;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;

    for (NSString *path in GetRecentPresetPaths(typeName)) {
        NSString *presetName = [[path lastPathComponent] stringByDeletingPathExtension];

        if ([presetName compare:name options:options] != NSOrderedSame) continue;
        if (![fileManager fileExistsAtPath:path]) continue;

        return [NSURL fileURLWithPath:path];
    }

    return nil;
}
