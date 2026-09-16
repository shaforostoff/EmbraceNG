// (c) 2026 EmbraceNG contributors
// MIT License (or) 1-clause BSD License
//
// Checks on Source/BPMAnalyzer, the shell around the vendored bpmcore.
//
// bpmcore has its own suite upstream and is not re-tested here; what is tested
// is everything between a file on disk and an answer, which is the part this
// project owns and the part that can be wrong in ways a tempo will not show.
//
// The decisive ones are the two that go through a real file.  A synthetic
// AudioBufferList can be fed to the analyzer all day and still not prove the
// layout is right, because both channels of a stereo test signal are usually
// the same: the downmix would look correct while summing one channel twice.
// So these write a WAV whose two channels carry different signals, decode it
// with the same HugAudioFile the worker uses, and run the worker's own loop --
// which is what pins the non-interleaved layout, the short final buffer, and
// the frame count that ExtAudioFile writes back.

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#import "BPMAnalyzer.h"
#import "HugAudioFile.h"
#import "HugUtils.h"

#include <cmath>
#include <vector>

static int sFail = 0;
static int sChecks = 0;

static void ckTrue(const char *what, bool ok)
{
    sChecks++;
    if (!ok) sFail++;
    printf("   %-4s %s\n", ok ? "ok" : "FAIL", what);
}

static void ckNear(const char *what, double got, double want, double tol)
{
    sChecks++;
    bool ok = fabs(got - want) <= tol;
    if (!ok) sFail++;
    printf("   %-4s %-52s %9.3f (want %.3f +-%.3f)\n",
           ok ? "ok" : "FAIL", what, got, want, tol);
}

static void ckEqual(const char *what, NSString *got, NSString *want)
{
    sChecks++;
    bool ok = [got isEqualToString:want];
    if (!ok) sFail++;
    printf("   %-4s %-52s %-12s (want %s)\n", ok ? "ok" : "FAIL", what,
           [got UTF8String], [want UTF8String]);
}


#pragma mark - Signals

// A decaying tone burst on every beat.  Not music, but it has the one thing the
// onset envelope is looking for, and its tempo is known exactly.
static std::vector<float> sMakeClickTrack(double bpm, double seconds, double rate, double gain)
{
    std::vector<float> mono((size_t)(seconds * rate), 0.0f);

    double period = 60.0 / bpm;

    for (double t = 0; t < seconds; t += period) {
        size_t at = (size_t)(t * rate);

        for (size_t i = 0; i < (size_t)(rate / 20) && at + i < mono.size(); i++) {
            double env = exp(-40.0 * i / rate);
            mono[at + i] += (float)(gain * env * sin(2 * M_PI * 440.0 * i / rate));
        }
    }

    return mono;
}


#pragma mark - Feeding the analyzer directly

// Wraps mono or stereo float vectors as the non-interleaved buffer list
// HugAudioFile hands over, and feeds it in slices of `slice` frames.
static void sFeed(BPMAnalyzer *analyzer, const std::vector<std::vector<float>> &channels, size_t slice)
{
    size_t frames = channels[0].size();
    UInt32 count  = (UInt32)channels.size();

    AudioBufferList *list = HugAudioBufferListCreate(count, 0, NO);

    for (size_t at = 0; at < frames; at += slice) {
        size_t n = std::min(slice, frames - at);

        for (UInt32 c = 0; c < count; c++) {
            list->mBuffers[c].mNumberChannels = 1;
            list->mBuffers[c].mData = (void *)(channels[c].data() + at);
            list->mBuffers[c].mDataByteSize = (UInt32)(n * sizeof(float));
        }

        BPMAnalyzerScanAudioBuffer(analyzer, list, n);
    }

    HugAudioBufferListFree(list, NO);
}


static void testDirectFeed(void)
{
    printf("\n-- fed directly, as the worker's buffer list --\n");

    double rate = 44100;
    std::vector<float> mono = sMakeClickTrack(120.0, 90.0, rate, 0.8);

    BPMAnalyzer *analyzer = BPMAnalyzerCreate(1, rate);
    sFeed(analyzer, { mono }, 4096);
    BPMAnalyzerFinish(analyzer);

    double bpm = BPMAnalyzerGetBeatsPerMinute(analyzer);
    ckNear("120 BPM click track, mono", bpm, 120.0, 1.0);

    // The other half of a contract DanceRhythm.m holds the reading end of: it
    // maps these six names exactly, and anything outside the set would be read
    // as Unknown and quietly stop the effects switching.  A click track is not
    // any particular rhythm, so what is asserted is the vocabulary, not which
    // word came out of it.
    NSArray *names = @[ @"Tango", @"Vals", @"Milonga", @"Reggae", @"Other", BPMAnalyzerRhythmUnknown ];
    ckTrue("the rhythm name is one DanceRhythm knows",
           [names containsObject:BPMAnalyzerGetRhythm(analyzer)]);
    ckNear("duration is the audio's", BPMAnalyzerGetDuration(analyzer), 90.0, 0.5);
    BPMAnalyzerFree(analyzer);

    // Slicing is the worker's decode loop, and the answer must not depend on
    // where the reads happened to fall.
    analyzer = BPMAnalyzerCreate(1, rate);
    sFeed(analyzer, { mono }, 997);
    BPMAnalyzerFinish(analyzer);
    ckNear("same answer at an awkward slice size", BPMAnalyzerGetBeatsPerMinute(analyzer), bpm, 0.001);
    BPMAnalyzerFree(analyzer);

    // Both channels the same: the downmix must not change the answer.
    analyzer = BPMAnalyzerCreate(2, rate);
    sFeed(analyzer, { mono, mono }, 4096);
    BPMAnalyzerFinish(analyzer);
    ckNear("same answer duplicated to stereo", BPMAnalyzerGetBeatsPerMinute(analyzer), bpm, 0.001);
    BPMAnalyzerFree(analyzer);

    // One channel silent.  Summing one channel twice, or reading past the end
    // of the first buffer, both show up here and nowhere else.
    std::vector<float> silence(mono.size(), 0.0f);

    analyzer = BPMAnalyzerCreate(2, rate);
    sFeed(analyzer, { mono, silence }, 4096);
    BPMAnalyzerFinish(analyzer);
    ckNear("half-silent stereo still finds the beat", BPMAnalyzerGetBeatsPerMinute(analyzer), bpm, 1.0);
    BPMAnalyzerFree(analyzer);
}


static void testNothingToMeasure(void)
{
    printf("\n-- nothing to measure --\n");

    double rate = 44100;

    std::vector<float> silence((size_t)(rate * 60), 0.0f);

    BPMAnalyzer *analyzer = BPMAnalyzerCreate(1, rate);
    sFeed(analyzer, { silence }, 4096);
    BPMAnalyzerFinish(analyzer);
    ckTrue("silence reports no tempo", BPMAnalyzerGetBeatsPerMinute(analyzer) == 0);
    ckEqual("silence reports Unknown", BPMAnalyzerGetRhythm(analyzer), BPMAnalyzerRhythmUnknown);
    BPMAnalyzerFree(analyzer);

    // Half a second, which is less than one analysis window.
    std::vector<float> tiny = sMakeClickTrack(120.0, 0.5, rate, 0.8);

    analyzer = BPMAnalyzerCreate(1, rate);
    sFeed(analyzer, { tiny }, 4096);
    BPMAnalyzerFinish(analyzer);
    ckEqual("half a second reports Unknown", BPMAnalyzerGetRhythm(analyzer), BPMAnalyzerRhythmUnknown);
    BPMAnalyzerFree(analyzer);

    // Nothing at all.  The worker reaches this for a file it could open and
    // then read no frames from.
    analyzer = BPMAnalyzerCreate(2, rate);
    BPMAnalyzerFinish(analyzer);
    ckEqual("no audio at all reports Unknown", BPMAnalyzerGetRhythm(analyzer), BPMAnalyzerRhythmUnknown);
    ckTrue("no audio at all reports no tempo", BPMAnalyzerGetBeatsPerMinute(analyzer) == 0);
    BPMAnalyzerFree(analyzer);

    // Every entry point has to survive a create that failed.
    ckTrue("a null analyzer is inert", BPMAnalyzerCreate(0, rate) == NULL);
    BPMAnalyzerScanAudioBuffer(NULL, NULL, 0);
    BPMAnalyzerFinish(NULL);
    ckTrue("null reports no tempo", BPMAnalyzerGetBeatsPerMinute(NULL) == 0);
    ckEqual("null reports Unknown", BPMAnalyzerGetRhythm(NULL), BPMAnalyzerRhythmUnknown);
    BPMAnalyzerFree(NULL);
}


#pragma mark - Through a real file

static NSURL *sWriteWAV(NSString *name, const std::vector<std::vector<float>> &channels, double rate)
{
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];

    UInt32 count = (UInt32)channels.size();
    size_t frames = channels[0].size();

    AudioStreamBasicDescription asbd = { };
    asbd.mSampleRate       = rate;
    asbd.mFormatID         = kAudioFormatLinearPCM;
    asbd.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mChannelsPerFrame = count;
    asbd.mBitsPerChannel   = 16;
    asbd.mFramesPerPacket  = 1;
    asbd.mBytesPerFrame    = 2 * count;
    asbd.mBytesPerPacket   = 2 * count;

    ExtAudioFileRef file = NULL;
    OSStatus err = ExtAudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileWAVEType, &asbd,
                                             NULL, kAudioFileFlags_EraseFile, &file);
    if (err != noErr) { printf("   FAIL could not create %s (%d)\n", [name UTF8String], (int)err); sFail++; return nil; }

    std::vector<SInt16> interleaved(frames * count);
    for (size_t i = 0; i < frames; i++) {
        for (UInt32 c = 0; c < count; c++) {
            float v = channels[c][i];
            if (v >  1) v =  1;
            if (v < -1) v = -1;
            interleaved[i * count + c] = (SInt16)lround(v * 32767.0);
        }
    }

    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = count;
    list.mBuffers[0].mData = interleaved.data();
    list.mBuffers[0].mDataByteSize = (UInt32)(interleaved.size() * sizeof(SInt16));

    err = ExtAudioFileWrite(file, (UInt32)frames, &list);
    ExtAudioFileDispose(file);

    if (err != noErr) { printf("   FAIL could not write %s (%d)\n", [name UTF8String], (int)err); sFail++; return nil; }

    return url;
}


// The worker's loop, transcribed.  If WorkerService.m's changes, this should be
// brought back into step with it -- that is the point of it being a copy.
static BPMAnalyzer *sAnalyzeFileAtURL(NSURL *url)
{
    HugAudioFile *audioFile = [[HugAudioFile alloc] initWithFileURL:url];
    if (![audioFile open]) return NULL;

    NSInteger fileLengthFrames = [audioFile fileLengthFrames];
    AudioStreamBasicDescription format = [audioFile format];
    NSInteger framesRemaining = fileLengthFrames;

    BPMAnalyzer *analyzer = BPMAnalyzerCreate(format.mChannelsPerFrame, format.mSampleRate);

    AudioBufferList *fillBufferList = HugAudioBufferListCreate(format.mChannelsPerFrame, 4096 * 16, YES);

    BOOL ok = YES;
    while (ok) {
        UInt32 frameCount = (UInt32)framesRemaining;
        ok = [audioFile readFrames:&frameCount intoBufferList:fillBufferList];

        if (frameCount) {
            BPMAnalyzerScanAudioBuffer(analyzer, fillBufferList, frameCount);
        } else {
            break;
        }

        framesRemaining -= frameCount;
        if (framesRemaining == 0) break;
    }

    HugAudioBufferListFree(fillBufferList, YES);
    BPMAnalyzerFinish(analyzer);

    return analyzer;
}


static void testThroughAFile(void)
{
    printf("\n-- decoded from a real file, through HugAudioFile --\n");

    double rate = 44100;
    std::vector<float> mono = sMakeClickTrack(120.0, 90.0, rate, 0.8);
    std::vector<float> silence(mono.size(), 0.0f);

    NSURL *stereo = sWriteWAV(@"embrace-bpm-stereo.wav", { mono, silence }, rate);
    if (!stereo) return;

    BPMAnalyzer *analyzer = sAnalyzeFileAtURL(stereo);
    ckTrue("the file decoded", analyzer != NULL);

    if (analyzer) {
        // Left carries the clicks, right is silent.  A downmix reading the
        // wrong buffer, or the same one twice, still measures 120 -- but the
        // level halves, and with `gain` at 0.8 the wrong answer here is a
        // measurement from silence, which reports nothing at all.
        ckNear("120 BPM recovered from the file", BPMAnalyzerGetBeatsPerMinute(analyzer), 120.0, 1.0);
        ckNear("the whole file was seen", BPMAnalyzerGetDuration(analyzer), 90.0, 0.5);
        BPMAnalyzerFree(analyzer);
    }

    // 48kHz does not divide the rate the model was fitted at, so this is the
    // resampler path -- a different route to the same answer, and the one every
    // modern file takes.
    double rate48 = 48000;
    std::vector<float> mono48 = sMakeClickTrack(96.0, 90.0, rate48, 0.8);

    NSURL *at48 = sWriteWAV(@"embrace-bpm-48k.wav", { mono48 }, rate48);
    if (at48) {
        analyzer = sAnalyzeFileAtURL(at48);
        ckTrue("the 48kHz file decoded", analyzer != NULL);
        if (analyzer) {
            ckNear("96 BPM recovered at 48kHz", BPMAnalyzerGetBeatsPerMinute(analyzer), 96.0, 1.0);
            BPMAnalyzerFree(analyzer);
        }
        [[NSFileManager defaultManager] removeItemAtURL:at48 error:nil];
    }

    [[NSFileManager defaultManager] removeItemAtURL:stereo error:nil];
}


static void testCost(void)
{
    printf("\n-- what it costs --\n");

    double rate = 44100;
    std::vector<float> mono = sMakeClickTrack(120.0, 180.0, rate, 0.8);

    NSDate *started = [NSDate date];

    BPMAnalyzer *analyzer = BPMAnalyzerCreate(2, rate);
    sFeed(analyzer, { mono, mono }, 4096 * 16);
    BPMAnalyzerFinish(analyzer);
    BPMAnalyzerFree(analyzer);

    NSTimeInterval elapsed = -[started timeIntervalSinceNow];

    printf("   ---- three minutes of stereo analysed in %.3fs (%.0fx realtime)\n",
           elapsed, 180.0 / elapsed);

    // Not a benchmark, a guard.  This rides on a decode the app already does
    // while the DJ waits for a track to become playable, so it has to stay far
    // enough under that to disappear into it.
    ckTrue("a three minute track costs well under a second", elapsed < 1.0);
}


int main(void)
{
    @autoreleasepool {
        printf("BPMAnalyzer\n");

        testDirectFeed();
        testNothingToMeasure();
        testThroughAFile();
        testCost();

        printf("\n%d checks, %d failed\n", sChecks, sFail);
    }

    return sFail ? 1 : 0;
}
