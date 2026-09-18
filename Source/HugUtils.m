// (c) 2018-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "HugUtils.h"
#include <mach/mach_time.h>

static double sTimeBaseFrequency = 0;

static void sInitTimeBase()
{
    struct mach_timebase_info info;
    mach_timebase_info(&info);

    UInt32 numerator   = info.numer;
    UInt32 denominator = info.denom;

    sTimeBaseFrequency = ((double)denominator / (double)numerator) * 1000000000.0;
}


UInt64 HugGetCurrentHostTime(void)
{
    return mach_absolute_time();
}


NSTimeInterval HugGetSecondsWithHostTime(UInt64 hostTime)
{
    if (!sTimeBaseFrequency) sInitTimeBase();
    return hostTime / sTimeBaseFrequency;
}


UInt64 HugGetHostTimeWithSeconds(NSTimeInterval seconds)
{
    if (!sTimeBaseFrequency) sInitTimeBase();
    return seconds * sTimeBaseFrequency;
}


NSTimeInterval HugGetDeltaInSecondsForHostTimes(UInt64 time1, UInt64 time2)
{
    if (!sTimeBaseFrequency) sInitTimeBase();

    if (time1 > time2) {
        return (time1 - time2) /  sTimeBaseFrequency;
    } else {
        return (time2 - time1) / -sTimeBaseFrequency;
    }
}


AudioBufferList *HugAudioBufferListCreate(UInt32 channelCount, UInt32 frameCount, BOOL allocateData)
{
    if (!channelCount) return NULL;

    // An AudioBufferList is a count followed by a variable-length array of
    // AudioBuffer declared as [1], so the size of one holding n of them is the
    // struct plus the n-1 that are not in it already.
    //
    // This used to ask for channelCount whole AudioBufferLists, which is larger
    // than what is needed for every n -- so it was never wrong, just wrong for
    // the reason it looked right, and it would have stopped being big enough if
    // the struct's leading field had ever grown relative to AudioBuffer.
    size_t size = sizeof(AudioBufferList) + ((channelCount - 1) * sizeof(AudioBuffer));

    AudioBufferList *bufferList = calloc(1, size);
    if (!bufferList) return NULL;

    bufferList->mNumberBuffers = channelCount;

    for (NSInteger i = 0; i < channelCount; i++) {
        bufferList->mBuffers[i].mNumberChannels = 1;
        
        if (allocateData) {
            bufferList->mBuffers[i].mDataByteSize = frameCount * sizeof(float);
            bufferList->mBuffers[i].mData = calloc(frameCount, sizeof(float));
        }
    }
    
    return bufferList;
}


void HugAudioBufferListFree(AudioBufferList *bufferList, BOOL freeData)
{
    if (!bufferList) return;

    for (NSInteger i = 0; i < bufferList->mNumberBuffers; i++) {
        if (freeData) free(bufferList->mBuffers[i].mData);
        bufferList->mBuffers[i].mData = NULL;
    }
    
    free(bufferList);
}


static void (^sHugLogger)(NSString *, NSString *) = NULL;


void HugSetLogger(void (^logger)(NSString *category, NSString *message))
{
    sHugLogger = logger;
}


void HugLog(NSString *category, NSString *format, ...)
{
    if (!sHugLogger) return;

    va_list v;

    va_start(v, format);

    NSString *contents = [[NSString alloc] initWithFormat:format arguments:v];
    if (sHugLogger) sHugLogger(category, contents);
    
    va_end(v);
}


void _HugLogMethod(const char *f)
{
    if (!sHugLogger) return;

    NSString *string = [NSString stringWithUTF8String:f];

    if ([string hasPrefix:@"-["] || [string hasPrefix:@"+["]) {
        NSCharacterSet *cs = [NSCharacterSet characterSetWithCharactersInString:@"+-[]"];
        
        string = [string stringByTrimmingCharactersInSet:cs];
        NSArray *components = [string componentsSeparatedByString:@" "];
        
        sHugLogger([components firstObject], [components lastObject]);
        
    } else {
        sHugLogger(@"Function", string);
    }
}

static OSStatus sGroupError = noErr;



extern NSString *HugGetStringForFourCharCode(OSStatus fcc)
{
    char str[20] = {0};

    *(UInt32 *)(str + 1) = CFSwapInt32HostToBig(*(UInt32 *)&fcc);

    if (isprint(str[1]) && isprint(str[2]) && isprint(str[3]) && isprint(str[4])) {
        str[0] = str[5] = '\'';
        str[6] = '\0';
    } else {
        return [NSString stringWithFormat:@"%ld", (long)fcc];
    }
    
    return [NSString stringWithCString:str encoding:NSUTF8StringEncoding];
}


BOOL HugCheckError(OSStatus error, NSString *category, NSString *operation)
{
    if (error == noErr) {
        return YES;
    }

    if (sGroupError != noErr) {
        sGroupError = error;
    }

    if (sHugLogger) {
        sHugLogger(category, [NSString stringWithFormat:@"Error: %@ (%@)",
            operation,
            HugGetStringForFourCharCode(error)
        ]);
    }

    return NO;
}


BOOL HugCheckErrorGroup(void (^callback)())
{
    OSStatus previousGroupError = sGroupError;
    callback();

    BOOL result = (sGroupError == noErr);
    
    sGroupError = previousGroupError;
    
    return result;
}


