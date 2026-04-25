// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "Utils.h"
#import "Track.h"
#import "HugUtils.h"
#import <AudioToolbox/AudioToolbox.h>


static NSArray *sGetTraditionalStringArray()
{
    return @[
        @"",

        @"G#m", @"Ebm", @"Bbm", @"Fm",
        @"Cm",  @"Gm",  @"Dm",  @"Am",
        @"Em",  @"Bm",  @"F#m", @"C#m",

        @"B",   @"F#",  @"Db",  @"Ab",
        @"Eb",  @"Bb",  @"F",   @"C",
        @"G",   @"D",   @"A",   @"E"
    ];
}


static NSArray *sGetEnharmonicStringArray()
{
    return @[
        @"",

        @"Abm", @"D#m", @"A#m", @"E#m",
        @"B#m", @"Gm",  @"Dm",  @"Am",
        @"Fbm", @"Cbm", @"Gbm", @"Dbm",

        @"Cb",  @"Gb",  @"C#",  @"G#",
        @"D#",  @"A#",  @"E#",  @"B#",
        @"G",   @"D",   @"A",   @"Fb"
    ];
}


static NSArray *sGetOpenKeyNotationArray()
{
    return @[
        @"",

        @"6m",  @"7m",  @"8m",  @"9m",
        @"10m", @"11m", @"12m", @"1m",
        @"2m",  @"3m",  @"4m",  @"5m",

        @"6d",  @"7d",  @"8d",  @"9d",
        @"10d", @"11d", @"12d", @"1d",
        @"2d",  @"3d",  @"4d",  @"5d"
    ];
}

#define TEST_TONALITY_PARSERS 0

#if TEST_TONALITY_PARSERS

__attribute__((constructor)) static void TestTonalityParsers()
{
    void (^test)(Tonality, id, id, id, id) = ^(Tonality tonality, id s1, id s2, id inOKS, id inCamelot) {
        if (tonality != GetTonalityForString(s1)       ) NSLog(@"%@", s1);
        if (tonality != GetTonalityForString(inOKS)    ) NSLog(@"%@", inOKS);
        if (tonality != GetTonalityForString(inCamelot)) NSLog(@"%@", inCamelot);

        if (s2 && (tonality != GetTonalityForString(s2))) {
            NSLog(@"%@", s2);
        }
        
        NSString *traditional = GetTraditionalStringForTonality(tonality);
        NSString *oks = GetOpenKeyNotationStringForTonality(tonality);
        
        if (![traditional isEqualToString:s1]) {
            NSLog(@"%@ != %@", traditional, s1);
        }

        if (![oks isEqualToString:inOKS]) {
            NSLog(@"%@ != %@", oks, inOKS);
        }
    };

    test( Tonality_Major__1___8B__C,  @"C", @"B#",  @"1d",  @"8B" );
    test( Tonality_Major__2___9B__G,  @"G",  nil,   @"2d",  @"9B" );
    test( Tonality_Major__3__10B__D,  @"D",  nil,   @"3d",  @"10B" );
    test( Tonality_Major__4__11B__A,  @"A",  nil,   @"4d",  @"11B" );
    test( Tonality_Major__5__12B__E,  @"E",  @"Fb", @"5d",  @"12B" );
    test( Tonality_Major__6___1B__B,  @"B",  @"Cb", @"6d",  @"1B" );
    test( Tonality_Major__7___2B__Fs, @"F#", @"Gb", @"7d",  @"2B" );
    test( Tonality_Major__8___3B__Db, @"Db", @"C#", @"8d",  @"3B" );
    test( Tonality_Major__9___4B__Ab, @"Ab", @"G#", @"9d",  @"4B" );
    test( Tonality_Major_10___5B__Eb, @"Eb", @"D#", @"10d", @"5B" );
    test( Tonality_Major_11___6B__Bb, @"Bb", @"A#", @"11d", @"6B" );
    test( Tonality_Major_12___7B__F,  @"F",  @"E#", @"12d", @"7B" );


    test( Tonality_Minor__1___8A__A,  @"Am",  nil,    @"1m",  @"8A");
    test( Tonality_Minor__2___9A__E,  @"Em",  @"Fbm", @"2m",  @"9A");
    test( Tonality_Minor__3__10A__B,  @"Bm",  @"Cbm", @"3m",  @"10A");
    test( Tonality_Minor__4__11A__Fs, @"F#m", @"Gbm", @"4m",  @"11A");
    test( Tonality_Minor__5__12A__Cs, @"C#m", @"Dbm", @"5m",  @"12A");
    test( Tonality_Minor__6___1A__Ab, @"G#m", @"Abm", @"6m",  @"1A");
    test( Tonality_Minor__7___2A__Eb, @"Ebm", @"D#m", @"7m",  @"2A");
    test( Tonality_Minor__8___3A__Bb, @"Bbm", @"A#m", @"8m",  @"3A");
    test( Tonality_Minor__9___4A__F,  @"Fm",  @"E#m", @"9m",  @"4A");
    test( Tonality_Minor_10___5A__C,  @"Cm",  @"B#m", @"10m", @"5A");
    test( Tonality_Minor_11___6A__G,  @"Gm",  nil,    @"11m", @"6A");
    test( Tonality_Minor_12___7A__D,  @"Dm",  nil,    @"12m", @"7A");
    

}

#endif


static NSString *sFindOrCreateDirectory(
    NSSearchPathDirectory searchPathDirectory,
    NSSearchPathDomainMask domainMask,
    NSString *appendComponent,
    NSError **outError
) {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(searchPathDirectory, domainMask, YES);
    if (![paths count]) return nil;

    NSString *resolvedPath = [paths firstObject];
    if (appendComponent) {
        resolvedPath = [resolvedPath stringByAppendingPathComponent:appendComponent];
    }

    NSError *error;
    BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:resolvedPath withIntermediateDirectories:YES attributes:nil error:&error];

    if (!success) {
        if (outError) *outError = error;
        return nil;
    }

    if (outError) *outError = nil;

    return resolvedPath;
}


NSArray *GetAvailableAudioFileUTIs()
{
    CFArrayRef *cfArray = NULL;
    UInt32 size;

    OSStatus err = AudioFileGetGlobalInfoSize(kAudioFileGlobalInfo_AllUTIs, 0, NULL, &size);

    if (err == noErr) {
        err = AudioFileGetGlobalInfo(kAudioFileGlobalInfo_AllUTIs, 0, NULL, &size, &cfArray);
    }
    
    NSArray *result = nil;

    if (err == noErr) {
        result = cfArray ? CFBridgingRelease(cfArray) : nil;
    }

    return result;
}


BOOL IsAudioFileAtURL(NSURL *fileURL)
{
    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];

    NSString *type;
    NSError *error;

    if ([fileURL getResourceValue:&type forKey:NSURLTypeIdentifierKey error:&error]) {
        for (NSString *availableType in GetAvailableAudioFileUTIs()) {
            if ([workspace type:type conformsToType:availableType]) {
                return YES;
            }
        }

        if ([workspace type:type conformsToType:(__bridge NSString *)kUTTypeFolder]) {
            return YES;
        }

        if ([workspace type:type conformsToType:(__bridge NSString *)kUTTypeM3UPlaylist]) {
            return YES;
        }
    }

    return NO;
}


BOOL LoadPanelState(NSSavePanel *panel, NSString *name)
{
    NSString *path = [[NSUserDefaults standardUserDefaults] objectForKey:name];
    
    if (path) {
        NSURL *url = [NSURL fileURLWithPath:path];
        
        if (url) {
            [panel setDirectoryURL:url];
            return YES;
        }
    }
    
    return NO;
}


void SavePanelState(NSSavePanel *panel, NSString *name)
{
    NSString *path = [[panel directoryURL] path];
    [[NSUserDefaults standardUserDefaults] setObject:path forKey:name];
}



extern Tonality GetTonalityForString(NSString *string)
{
    if (![string length]) {
        return Tonality_Unknown;
    }
    
    const size_t MaxBufferSize = 1024;

    char buffer[MaxBufferSize];
    char *bufferPtr = buffer;
    
    if (![string getCString:buffer maxLength:MaxBufferSize encoding:NSUTF8StringEncoding]) {
        return Tonality_Unknown;
    }
    
    NSInteger decimal = 0;
    char alpha = 0;

    char c;
    while ((c = *bufferPtr)) {
        if (isnumber(c)) {
            decimal = strtod(bufferPtr, &bufferPtr);

        } else if (isalpha(c)) {
            if (alpha && (c == 'b')) {
                // This is a flat, but we will map it via arrays below
            } else {
                alpha = c;
            }

            bufferPtr++;

        } else if (c == 0) {
            break;

        } else {
            bufferPtr++;
        }
    }
    
    Tonality result = Tonality_Unknown;

    if (decimal >= 1 && decimal <= 12) {
        // Camelot, Minor
        if (alpha == 'A' || alpha == 'a') {
            Tonality map[13] = {
                Tonality_Unknown,
                Tonality_Minor__6___1A__Ab,
                Tonality_Minor__7___2A__Eb,
                Tonality_Minor__8___3A__Bb,
                Tonality_Minor__9___4A__F,
                Tonality_Minor_10___5A__C,
                Tonality_Minor_11___6A__G,
                Tonality_Minor_12___7A__D,
                Tonality_Minor__1___8A__A,
                Tonality_Minor__2___9A__E,
                Tonality_Minor__3__10A__B,
                Tonality_Minor__4__11A__Fs,
                Tonality_Minor__5__12A__Cs
            };

            result = map[decimal];

        // Camelot, Major
        } else if (alpha == 'B' || alpha == 'b') {
            Tonality map[13] = {
                Tonality_Unknown,
                Tonality_Major__6___1B__B,
                Tonality_Major__7___2B__Fs,
                Tonality_Major__8___3B__Db,
                Tonality_Major__9___4B__Ab,
                Tonality_Major_10___5B__Eb,
                Tonality_Major_11___6B__Bb,
                Tonality_Major_12___7B__F,
                Tonality_Major__1___8B__C,
                Tonality_Major__2___9B__G,
                Tonality_Major__3__10B__D,
                Tonality_Major__4__11B__A,
                Tonality_Major__5__12B__E
            };

            result = map[decimal];

        // Open Key Notation, Minor
        } else if (alpha == 'M' || alpha == 'm') {
            Tonality map[13] = {
                Tonality_Unknown,
                Tonality_Minor__1___8A__A,
                Tonality_Minor__2___9A__E,
                Tonality_Minor__3__10A__B,
                Tonality_Minor__4__11A__Fs,
                Tonality_Minor__5__12A__Cs,
                Tonality_Minor__6___1A__Ab,
                Tonality_Minor__7___2A__Eb,
                Tonality_Minor__8___3A__Bb,
                Tonality_Minor__9___4A__F,
                Tonality_Minor_10___5A__C,
                Tonality_Minor_11___6A__G,
                Tonality_Minor_12___7A__D
            };

            result = map[decimal];

        // Open Key Notation, Major
        } else if (alpha == 'D' || alpha == 'd') {
            Tonality map[13] = {
                Tonality_Unknown,
                Tonality_Major__1___8B__C,
                Tonality_Major__2___9B__G,
                Tonality_Major__3__10B__D,
                Tonality_Major__4__11B__A,
                Tonality_Major__5__12B__E,
                Tonality_Major__6___1B__B,
                Tonality_Major__7___2B__Fs,
                Tonality_Major__8___3B__Db,
                Tonality_Major__9___4B__Ab,
                Tonality_Major_10___5B__Eb,
                Tonality_Major_11___6B__Bb,
                Tonality_Major_12___7B__F
            };

            result = map[decimal];
        }
    }

    if (result == Tonality_Unknown) {
        NSArray  *array = sGetTraditionalStringArray();
        NSUInteger index = [array indexOfObject:string];

        if (index == NSNotFound) {
            index = [sGetEnharmonicStringArray() indexOfObject:string];
        }

        if (index != NSNotFound && index != 0) {
            result = (Tonality)index;
        }
    }

    return result;
}


/*
    Return a "simplified" string for the "Duplicate Status: Similar Title" feature.
    
    1.  Decomposes string with compatibility mapping
    2.  Folds string into lowercase/no-double-width/no-diacritic version
    3A. Changes ae, oe, and ij ligatures into two-character versions
    3B. Ignores ['".,-+]
    3C. Compresses multiple whitespace characters into a single character
    3D. Removes text in ()'s, {}'s, and []'s
    4. Strips whitespace
*/
extern NSString *GetSimplifiedString(NSString *string)
{
    string = [string decomposedStringWithCompatibilityMapping];
    string = [string stringByFoldingWithOptions:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch|NSWidthInsensitiveSearch locale:nil];
   
    NSUInteger inLength = [string length];

    unichar *inCharacters = malloc(sizeof(unichar) * inLength); 
    [string getCharacters:inCharacters range:NSMakeRange(0, inLength)];

    unichar *outCharacters = calloc(inLength * 2, sizeof(unichar));
    unichar *o = outCharacters;
    
    BOOL inWhitespace = NO;
    NSUInteger nestCount = 0;

    for (NSUInteger i = 0; i < inLength; i++) {
        unichar c = inCharacters[i];
        
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            if (!inWhitespace) {
                inWhitespace = YES;
                *o++ = ' ';
            }

        } else if (c == '.' || c == ',' || c == '\'' || c == '"' || c == '-' || c == '+') {
            continue;
           
        } else if (c == '(') {
            while (i < inLength) {
                if (inCharacters[i] == '(') nestCount++;
                if (inCharacters[i] == ')') nestCount--;
                if (!nestCount) break;
                i++;
            }

        } else if (c == '[') {
            while (i < inLength) {
                if (inCharacters[i] == '[') nestCount++;
                if (inCharacters[i] == ']') nestCount--;
                if (!nestCount) break;
                i++;
            }

        } else if (c == '{') {
            while (i < inLength) {
                if (inCharacters[i] == '{') nestCount++;
                if (inCharacters[i] == '}') nestCount--;
                if (!nestCount) break;
                i++;
            }

        } else if (c == 0xe6) { // ae
            *o++ = 'a'; *o++ = 'e';

        } else if (c == 0x133) { // ij
            *o++ = 'i'; *o++ = 'j';

        } else if (c == 0x153) { // oe
            *o++ = 'o'; *o++ = 'e';
    
        } else {
            inWhitespace = NO;
            *o++ = c;
        }
    }

    NSString *result = [[NSString alloc] initWithCharacters:outCharacters length:o - outCharacters];
    
    free(inCharacters);
    free(outCharacters);
    
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}


extern NSString *GetTraditionalStringForTonality(Tonality tonality)
{
    NSArray *array = sGetTraditionalStringArray();
    
    if (tonality > 0 && tonality < [array count]) {
        return [array objectAtIndex:tonality];
    }
    
    return nil;
}


extern NSString *GetOpenKeyNotationStringForTonality(Tonality tonality)
{
    NSArray *array = sGetOpenKeyNotationArray();
    
    if (tonality > 0 && tonality < [array count]) {
        return [array objectAtIndex:tonality];
    }
    
    return nil;
}


CGImageRef CreateImage(CGSize size, BOOL opaque, CGFloat scale, void (^callback)(CGContextRef))
{
    size_t width  = size.width * scale;
    size_t height = size.height * scale;

    CGImageRef      cgImage    = NULL;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    if (colorSpace && width > 0 && height > 0) {
        CGBitmapInfo bitmapInfo = 0 | (opaque ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaPremultipliedFirst);
        CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace, bitmapInfo);
    
        if (context) {
            CGContextTranslateCTM(context, 0, height);
            CGContextScaleCTM(context, scale, -scale);

            NSGraphicsContext *savedContext = [NSGraphicsContext currentContext];
            [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:context flipped:YES]];

            callback(context);
            
            [NSGraphicsContext setCurrentContext:savedContext];

            cgImage = CGBitmapContextCreateImage(context);
            CFRelease(context);
        }
    }

    CGColorSpaceRelease(colorSpace);

    return cgImage;
}


extern AppDelegate *GetAppDelegate(void)
{
    return (AppDelegate *)[NSApp delegate];
}


NSString *GetAppBuildString(void)
{
    return [[[NSBundle mainBundle] infoDictionary] objectForKey:(__bridge id)kCFBundleVersionKey];
}


NSUInteger GetCombinedBuildNumber(NSString *string)
{
    NSArray *components = [string componentsSeparatedByString:@"."];
 
    NSString *majorString = [components count] > 0 ? [components firstObject] : nil;
    NSString *minorString = [components count] > 1 ? [components lastObject]  : nil;

    return ([majorString integerValue] << 16) + [minorString integerValue];
}


NSString *GetStringForTime(NSTimeInterval time)
{
    BOOL minus = NO;

    if (time == -0) {
        time = 0;
    }

    if (time < 0) {
        time = -time;
        minus = YES;
    }

    double seconds = floor(fmod(time, 60.0));
    double minutes = floor(time / 60.0);

    return [NSString stringWithFormat:@"%s%g:%02g", minus ? "-" : "", minutes, seconds];
}


NSString *GetApplicationSupportDirectory()
{
    NSString *name = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleExecutable"];
    return sFindOrCreateDirectory(NSApplicationSupportDirectory, NSUserDomainMask, name, NULL);
}


NSString *GetBundleIdentifierWithSuffix(NSString *suffix)
{
    NSString *mainBundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    return [NSString stringWithFormat:@"%@.%@", mainBundleIdentifier, suffix];
}


BOOL IsAppearanceDarkAqua(NSView *view)
{
    NSAppearance *effectiveAppearance = view ?
        [view  effectiveAppearance] :
        [NSApp effectiveAppearance];

    NSArray *names = @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ];
   
    NSAppearanceName bestMatch = [effectiveAppearance bestMatchFromAppearancesWithNames:names];

    return [bestMatch isEqualToString:NSAppearanceNameDarkAqua];
}


extern NSColor *GetColorWithMultipliedAlpha(NSColor *inColor, CGFloat inAlpha)
{
    CGFloat newAlpha = [inColor alphaComponent] * inAlpha;
    return [inColor colorWithAlphaComponent:newAlpha];
}


void PerformWithAppearance(NSAppearance *appearance, void (^block)(void))
{
    NSAppearance *oldAppearance = [NSAppearance currentAppearance];
    [NSAppearance setCurrentAppearance:appearance];
    block();
    [NSAppearance setCurrentAppearance:oldAppearance];
}


CGRect GetInsetBounds(NSView *view)
{
    CGFloat scale = [[view window] backingScaleFactor];
    CGRect  bounds = [view bounds];
    CGRect  insetBounds = bounds;

    // Dark Aqua adds a translucent bezel, pull in by one pixel to match
    if (@available(macOS 10.14, *)) {
        if (IsAppearanceDarkAqua(view) && (scale > 1)) {
            insetBounds = CGRectInset(bounds, 1, 0);
        }
    }
    
    return insetBounds;
}

