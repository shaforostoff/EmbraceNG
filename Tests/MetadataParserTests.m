// (c) 2026 EmbraceNG contributors
// MIT License (or) 1-clause BSD License
//
// Checks on the two tag parsers that walk raw bytes out of a file: the AIFF
// chunk walk that finds an embedded ID3 tag, and the ID3v2 frame walk that cuts
// padding off a tag AVFoundation would otherwise drop.  Both read files that
// come from anywhere, so each gets one tag that should read and a few damaged
// ones that must neither crash nor hang.
//
// Every file is built here byte by byte in $TMPDIR and removed afterwards.  A
// parse runs on a thread of its own with a time limit, because the failure that
// mattered was a loop that never returned.

#import <Foundation/Foundation.h>

#import "MetadataParser.h"
#import "TrackKeys.h"


static int sFail = 0;
static int sChecks = 0;

static void ckTrue(const char *what, BOOL ok)
{
    sChecks++;
    if (!ok) sFail++;
    printf("   %-4s %s\n", ok ? "ok" : "FAIL", what);
}


// The same two MPEG frames MetadataParser appends to a bare tag, so that
// AVFoundation takes the file for an MP3.
static const UInt8 sFakeMP3Data[] = {
    0xFF, 0xF3, 0x14, 0xC4, 0x00, 0x00, 0x00, 0x03,
    0x48, 0x01, 0x40, 0x00, 0x00, 0x4C, 0x41, 0x4D,
    0x45, 0x33, 0x2E, 0x39, 0x36, 0x2E, 0x31, 0x55,
    0xFF, 0xF3, 0x14, 0xC4, 0x0B, 0x00, 0x00, 0x03,
    0x48, 0x01, 0x80, 0x00, 0x00, 0x55, 0x55, 0x55,
    0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55
};


static void sAppendBig32(NSMutableData *data, UInt32 value)
{
    UInt32 big = CFSwapInt32HostToBig(value);
    [data appendBytes:&big length:4];
}


static void sAppendSynchsafe(NSMutableData *data, UInt32 value)
{
    UInt8 b[4] = { (value >> 21) & 0x7F, (value >> 14) & 0x7F, (value >> 7) & 0x7F, value & 0x7F };
    [data appendBytes:b length:4];
}


// One text frame, ISO-8859-1.  `declaredSize` is what the header claims, which
// is the real size unless a test wants it to lie.
static void sAppendTextFrame(NSMutableData *tag, UInt8 version, const char *frameID, const char *text, UInt32 declaredSize)
{
    [tag appendBytes:frameID length:4];

    if (version == 4) sAppendSynchsafe(tag, declaredSize);
    else              sAppendBig32(tag, declaredSize);

    UInt8 flagsAndEncoding[3] = { 0, 0, 0 };
    [tag appendBytes:flagsAndEncoding length:3];
    [tag appendBytes:text length:strlen(text)];
}


static UInt32 sTextFrameSize(const char *text)
{
    return (UInt32)(1 + strlen(text));
}


// Header plus frames plus `padding` zero bytes.  `declaredSize`, when not 0,
// overrides the size the header claims.
static NSData *sMakeTag(UInt8 version, NSData *frames, NSUInteger padding, UInt32 declaredSize)
{
    NSMutableData *tag = [NSMutableData data];

    UInt8 header[6] = { 'I', 'D', '3', version, 0, 0 };
    [tag appendBytes:header length:6];

    UInt32 size = declaredSize ? declaredSize : (UInt32)([frames length] + padding);
    sAppendSynchsafe(tag, size);

    [tag appendData:frames];
    [tag increaseLengthBy:padding];

    return tag;
}


static NSData *sBPMAndComposerFrames(UInt8 version)
{
    NSMutableData *frames = [NSMutableData data];

    sAppendTextFrame(frames, version, "TIT2", "Poema",            sTextFrameSize("Poema"));
    sAppendTextFrame(frames, version, "TBPM", "120",              sTextFrameSize("120"));
    sAppendTextFrame(frames, version, "TCOM", "Mario Melfi",      sTextFrameSize("Mario Melfi"));

    return frames;
}


static NSData *sMakeMP3(NSData *tag)
{
    NSMutableData *file = [tag mutableCopy];

    for (NSInteger i = 0; i < 16; i++) {
        [file appendBytes:sFakeMP3Data length:sizeof(sFakeMP3Data)];
    }

    return file;
}


// FORM/AIFF holding the chunks given, as (id, size, payload) triples already
// flattened into `chunks`.  Not playable, and does not need to be: the AIFF
// route runs the chunk walk whether or not AudioToolbox could open the audio.
static NSData *sMakeAIFF(NSData *chunks)
{
    NSMutableData *file = [NSMutableData data];

    [file appendBytes:"FORM" length:4];
    sAppendBig32(file, (UInt32)(4 + [chunks length]));
    [file appendBytes:"AIFF" length:4];
    [file appendData:chunks];

    return file;
}


static void sAppendChunk(NSMutableData *chunks, const char *chunkID, UInt32 declaredSize, NSData *payload)
{
    [chunks appendBytes:chunkID length:4];
    sAppendBig32(chunks, declaredSize);
    if (payload) [chunks appendData:payload];
}


static NSString *sDirectory(void)
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"metadata-parser-tests"];
}


// Writes `data` under `name` and parses it.  Nil when the parse did not come back
// within the limit, which is the hang this suite exists to catch.
static NSDictionary *sParse(NSString *name, NSData *data)
{
    NSString *path = [sDirectory() stringByAppendingPathComponent:name];
    [data writeToFile:path atomically:YES];

    NSURL *url = [NSURL fileURLWithPath:path];

    __block NSDictionary *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    [NSThread detachNewThreadWithBlock:^{ @autoreleasepool {
        MetadataParser *parser = [[MetadataParser alloc] initWithURL:url fallbackTitle:@"fallback"];
        result = [parser metadata];
        dispatch_semaphore_signal(done);
    } }];

    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
        return nil;
    }

    return result;
}


#pragma mark - Tests

static void testID3InMP3(void)
{
    printf("\n-- an ID3 tag at the head of an MP3 --\n");

    for (NSNumber *versionNumber in @[ @3, @4 ]) {
        UInt8 version = [versionNumber unsignedCharValue];

        // Padding is what AVFoundation can trip on; the frame walk cuts it off
        // and tries again.  Either way the tags have to come out.
        for (NSNumber *paddingNumber in @[ @0, @2048 ]) {
            NSUInteger padding = [paddingNumber unsignedIntegerValue];

            NSData *tag = sMakeTag(version, sBPMAndComposerFrames(version), padding, 0);
            NSDictionary *metadata = sParse([NSString stringWithFormat:@"v%d-pad%lu.mp3", version, (unsigned long)padding], sMakeMP3(tag));

            NSString *label = [NSString stringWithFormat:@"ID3v2.%d, %lu bytes of padding", version, (unsigned long)padding];

            ckTrue([[label stringByAppendingString:@": the title"] UTF8String],
                   [[metadata objectForKey:TrackKeyTitle] isEqual:@"Poema"]);
            ckTrue([[label stringByAppendingString:@": the BPM"] UTF8String],
                   [[metadata objectForKey:TrackKeyBPM] integerValue] == 120);
            ckTrue([[label stringByAppendingString:@": the composer, from TCOM"] UTF8String],
                   [[metadata objectForKey:TrackKeyComposer] isEqual:@"Mario Melfi"]);
        }
    }
}


static void testDamagedID3(void)
{
    printf("\n-- a damaged ID3 tag reads what it can and returns --\n");

    // A frame claiming to run past the end of the tag stops the walk
    {
        NSMutableData *frames = [NSMutableData data];
        sAppendTextFrame(frames, 4, "TIT2", "Poema", sTextFrameSize("Poema"));
        sAppendTextFrame(frames, 4, "TBPM", "120",   0x0FFFFFFF);

        NSDictionary *metadata = sParse(@"frame-overruns.mp3", sMakeMP3(sMakeTag(4, frames, 512, 0)));
        ckTrue("a frame larger than its tag", metadata != nil);
    }

    // A header claiming a tag larger than the whole file
    {
        NSData *tag = sMakeTag(4, sBPMAndComposerFrames(4), 0, 0x0FFFFFFF);
        NSDictionary *metadata = sParse(@"tag-overruns.mp3", sMakeMP3(tag));
        ckTrue("a tag larger than its file", metadata != nil);
    }

    // Nothing but a header
    {
        NSData *tag = sMakeTag(4, [NSData data], 0, 0);
        NSDictionary *metadata = sParse(@"header-only.mp3", tag);
        ckTrue("a header and nothing after it", [[metadata objectForKey:TrackKeyTitle] isEqual:@"fallback"]);
    }
}


static void testAIFF(void)
{
    printf("\n-- an ID3 chunk inside an AIFF --\n");

    NSData *tag = sMakeTag(3, sBPMAndComposerFrames(3), 0, 0);

    {
        NSMutableData *chunks = [NSMutableData data];
        sAppendChunk(chunks, "ID3 ", (UInt32)[tag length], tag);

        NSDictionary *metadata = sParse(@"tagged.aiff", sMakeAIFF(chunks));
        ckTrue("the BPM is read from the chunk", [[metadata objectForKey:TrackKeyBPM] integerValue] == 120);
    }

    // Odd-sized chunks are padded to even; the walk tries both readings
    {
        NSMutableData *chunks = [NSMutableData data];
        sAppendChunk(chunks, "COMT", 3, [NSData dataWithBytes:"abc\0" length:4]);
        sAppendChunk(chunks, "ID3 ", (UInt32)[tag length], tag);

        NSDictionary *metadata = sParse(@"after-odd-chunk.aiff", sMakeAIFF(chunks));
        ckTrue("found after an odd-sized chunk", [[metadata objectForKey:TrackKeyBPM] integerValue] == 120);
    }

    printf("\n-- a damaged AIFF returns --\n");

    // -8 walks back onto the same header.  This used to loop forever, on the
    // worker's one metadata queue.
    for (NSNumber *sizeNumber in @[ @0xFFFFFFF8, @0xFFFFFFF0, @0x80000000, @0x7FFFFFFF ]) {
        UInt32 size = [sizeNumber unsignedIntValue];

        NSMutableData *chunks = [NSMutableData data];
        sAppendChunk(chunks, "COMM", size, [NSData dataWithBytes:"\0\0\0\0\0\0\0\0" length:8]);
        sAppendChunk(chunks, "ID3 ", (UInt32)[tag length], tag);

        NSString *name = [NSString stringWithFormat:@"chunk-%08x.aiff", size];
        NSDictionary *metadata = sParse(name, sMakeAIFF(chunks));

        ckTrue([[NSString stringWithFormat:@"a chunk size of 0x%08X", size] UTF8String], metadata != nil);
    }
}


int main(void)
{
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:sDirectory() error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:sDirectory() withIntermediateDirectories:YES attributes:nil error:nil];

        printf("Tag parsers\n");

        testID3InMP3();
        testDamagedID3();
        testAIFF();

        [[NSFileManager defaultManager] removeItemAtPath:sDirectory() error:nil];

        printf("\n%d checks, %d failed\n", sChecks, sFail);

        // A parse that hung is still running on its thread; exit rather than
        // return so that it does not keep the process alive.
        exit(sFail ? 1 : 0);
    }
}
