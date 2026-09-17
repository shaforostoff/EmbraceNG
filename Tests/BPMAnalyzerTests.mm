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
#import "TrackKeys.h"
#import "WorkerService.h"

// Private to WorkerService.m, and instantiable without XPC: the protocol is
// what crosses the process boundary, not the class, so the checks below drive
// the real worker in this process.
@interface Worker : NSObject <WorkerProtocol>
@end

#include <sys/resource.h>

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

    BPMAnalyzer *analyzer = BPMAnalyzerCreate(1, rate, mono.size());
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
    analyzer = BPMAnalyzerCreate(1, rate, mono.size());
    sFeed(analyzer, { mono }, 997);
    BPMAnalyzerFinish(analyzer);
    ckNear("same answer at an awkward slice size", BPMAnalyzerGetBeatsPerMinute(analyzer), bpm, 0.001);
    BPMAnalyzerFree(analyzer);

    // Both channels the same: the downmix must not change the answer.
    analyzer = BPMAnalyzerCreate(2, rate, mono.size());
    sFeed(analyzer, { mono, mono }, 4096);
    BPMAnalyzerFinish(analyzer);
    ckNear("same answer duplicated to stereo", BPMAnalyzerGetBeatsPerMinute(analyzer), bpm, 0.001);
    BPMAnalyzerFree(analyzer);

    // One channel silent.  Summing one channel twice, or reading past the end
    // of the first buffer, both show up here and nowhere else.
    std::vector<float> silence(mono.size(), 0.0f);

    analyzer = BPMAnalyzerCreate(2, rate, mono.size());
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

    BPMAnalyzer *analyzer = BPMAnalyzerCreate(1, rate, silence.size());
    sFeed(analyzer, { silence }, 4096);
    BPMAnalyzerFinish(analyzer);
    ckTrue("silence reports no tempo", BPMAnalyzerGetBeatsPerMinute(analyzer) == 0);
    ckEqual("silence reports Unknown", BPMAnalyzerGetRhythm(analyzer), BPMAnalyzerRhythmUnknown);
    BPMAnalyzerFree(analyzer);

    // Half a second, which is less than one analysis window.
    std::vector<float> tiny = sMakeClickTrack(120.0, 0.5, rate, 0.8);

    analyzer = BPMAnalyzerCreate(1, rate, tiny.size());
    sFeed(analyzer, { tiny }, 4096);
    BPMAnalyzerFinish(analyzer);
    ckEqual("half a second reports Unknown", BPMAnalyzerGetRhythm(analyzer), BPMAnalyzerRhythmUnknown);
    BPMAnalyzerFree(analyzer);

    // Nothing at all.  The worker reaches this for a file it could open and
    // then read no frames from.
    analyzer = BPMAnalyzerCreate(2, rate, 0);
    BPMAnalyzerFinish(analyzer);
    ckEqual("no audio at all reports Unknown", BPMAnalyzerGetRhythm(analyzer), BPMAnalyzerRhythmUnknown);
    ckTrue("no audio at all reports no tempo", BPMAnalyzerGetBeatsPerMinute(analyzer) == 0);
    BPMAnalyzerFree(analyzer);

    // Every entry point has to survive a create that failed.
    ckTrue("a null analyzer is inert", BPMAnalyzerCreate(0, rate, 0) == NULL);
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

    BPMAnalyzer *analyzer = BPMAnalyzerCreate(format.mChannelsPerFrame, format.mSampleRate, framesRemaining);

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


static void testLengthHint(void)
{
    printf("\n-- told how long the track is --\n");

    // -Create takes the length so that the buffer can be reserved once instead
    // of grown into.  It must size the buffer and nothing else, so what is
    // checked here is that every wrong answer -- and the honest "I do not
    // know" -- measures exactly what the right one does.
    //
    // Both paths, because they buffer at different rates: 44.1kHz is 22.05kHz
    // times a power of two and is kept as it is, while 48kHz is resampled down,
    // and the reserve is in samples at whichever rate that turned out to be.
    double rates[2] = { 44100, 48000 };

    for (int i = 0; i < 2; i++) {
        double rate = rates[i];
        std::vector<float> mono = sMakeClickTrack(120.0, 90.0, rate, 0.8);

        // Frames the worker would actually pass, out of the file header.
        size_t exact = mono.size();

        size_t hints[4] = {
            exact,      // what the worker passes
            0,          // a file whose length is not known
            1,          // far too small -- one frame for a 90 second track
            SIZE_MAX    // absurd, and a clamp away from a 70TB reserve
        };

        const char *names[4] = { "the exact length", "no length at all",
                                 "a length far too small", "an absurd length" };

        double want = 0, wantDuration = 0;

        for (int h = 0; h < 4; h++) {
            BPMAnalyzer *analyzer = BPMAnalyzerCreate(1, rate, hints[h]);
            sFeed(analyzer, { mono }, 4096);
            BPMAnalyzerFinish(analyzer);

            double bpm = BPMAnalyzerGetBeatsPerMinute(analyzer);
            double duration = BPMAnalyzerGetDuration(analyzer);

            char what[128];

            if (h == 0) {
                want = bpm;
                wantDuration = duration;

                snprintf(what, sizeof(what), "%gkHz: %s measures it", rate / 1000, names[h]);
                ckNear(what, bpm, 120.0, 1.0);
            } else {
                snprintf(what, sizeof(what), "%gkHz: %s, same tempo", rate / 1000, names[h]);
                ckNear(what, bpm, want, 0.0);

                snprintf(what, sizeof(what), "%gkHz: %s, same audio collected", rate / 1000, names[h]);
                ckNear(what, duration, wantDuration, 0.0);
            }

            BPMAnalyzerFree(analyzer);
        }
    }
}


static long sPeakResidentBytes(void)
{
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return 0;
    return (long)usage.ru_maxrss;   // bytes on Darwin, unlike Linux
}


static void testBufferSizingCost(void)
{
    printf("\n-- what being told costs, and what not being told costs --\n");

    // The reason the argument exists.  A vector that outgrows its reserve
    // doubles, and the copy holds the old buffer and the new one at once; the
    // default reserve is four minutes, so a side longer than that pays for the
    // copy and then sits in a buffer half again too big.
    //
    // ru_maxrss only ever goes up, which decides the order: measure the cheap
    // case first, and the expensive one can then only show as a rise.  Six
    // minutes is the shortest track that shows anything at all -- under four,
    // the unused part of the reserve is pages nothing ever touched, and costs
    // no resident memory to leave alone.
    double rate = 44100;
    std::vector<float> mono = sMakeClickTrack(120.0, 360.0, rate, 0.8);

    long before = sPeakResidentBytes();

    BPMAnalyzer *analyzer = BPMAnalyzerCreate(1, rate, mono.size());
    sFeed(analyzer, { mono }, 4096 * 16);
    BPMAnalyzerFinish(analyzer);
    BPMAnalyzerFree(analyzer);

    long told = sPeakResidentBytes();

    analyzer = BPMAnalyzerCreate(1, rate, 0);
    sFeed(analyzer, { mono }, 4096 * 16);
    BPMAnalyzerFinish(analyzer);
    BPMAnalyzerFree(analyzer);

    long untold = sPeakResidentBytes();

    // The absolutes are this harness and not the app: it holds the test signal
    // and the copy -Feed makes of it long after the analyzer is done with them.
    // The difference is the analyzer's, and it is the figure that means
    // something.
    printf("   ---- six minute side: not being told costs %.0fMB more"
           " (harness peak %.0fMB told, %.0fMB not, %.0fMB before either)\n",
           (untold - told) / 1048576.0,
           told / 1048576.0, untold / 1048576.0, before / 1048576.0);

    // Loose on purpose.  The exact figure is the allocator's business and the
    // machine's; what this pins is the direction, which is the whole claim --
    // and it only reads as a rise because the cheap case ran first.
    ckTrue("not being told costs more than being told", untold > told + (20 << 20));
}


// The worker replies on the main queue, so a command-line main() has to give it
// one to reply on.  Returns whether the condition came true before the timeout.
static BOOL sSpinUntil(NSTimeInterval timeout, BOOL (^condition)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

    while (!condition() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                 beforeDate: [NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    return condition();
}


// Runs one scan and hands back what came out of it, or nil if the worker chose
// not to answer at all -- which is not a failure but one of the things being
// checked, so the caller is told which happened rather than being made to wait
// on a reply that was never coming.
static NSDictionary *sScan(Worker *worker, NSURL *url, NSUUID *UUID, BOOL measuresTempo, NSTimeInterval wait)
{
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:NULL];

    __block NSDictionary *result = nil;
    __block BOOL replied = NO;

    [worker performTrackCommand: WorkerTrackCommandReadLoudness
                           UUID: UUID
                   bookmarkData: bookmark
               originalFilename: [url lastPathComponent]
                  measuresTempo: measuresTempo
                          reply: ^(NSDictionary *dictionary) {
        result  = dictionary;
        replied = YES;
    }];

    sSpinUntil(wait, ^{ return replied; });

    return result;
}


static void testTheWorkerGate(void)
{
    printf("\n-- what the worker does when it is told not to measure --\n");

    // The decode has to be real for this: what is being checked is which keys
    // come back out of a scan, and they come back out of the same function the
    // app calls.
    std::vector<float> mono = sMakeClickTrack(120.0, 20.0, 44100, 0.8);
    NSURL *url = sWriteWAV(@"bpm-worker-gate.wav", { mono, mono }, 44100);
    if (!url) return;

    Worker *worker = [[Worker alloc] init];

    // Told to measure: both keys, and the overview beside them.
    NSUUID *measured = [NSUUID UUID];
    NSDictionary *result = sScan(worker, url, measured, YES, 20.0);

    ckTrue("a scan that measures replies", result != nil);
    ckTrue("...with the overview it was always for", [result objectForKey:TrackKeyOverviewData] != nil);
    ckTrue("...with a tempo", [[result objectForKey:TrackKeyDetectedBPM] doubleValue] > 0);
    ckTrue("...and with a rhythm", [result objectForKey:TrackKeyDetectedRhythm] != nil);

    // Told not to: the overview still, and neither tempo key.  Not "Unknown" --
    // the app cannot tell an Unknown that was never looked for from one that
    // was, so writing it would mark the track answered forever.
    NSUUID *unmeasured = [NSUUID UUID];
    result = sScan(worker, url, unmeasured, NO, 20.0);

    ckTrue("a scan that does not measure still replies", result != nil);
    ckTrue("...still with the overview", [result objectForKey:TrackKeyOverviewData] != nil);
    ckTrue("...and still with the loudness", [result objectForKey:TrackKeyTrackLoudness] != nil);
    ckTrue("...but with no tempo", [result objectForKey:TrackKeyDetectedBPM] == nil);
    ckTrue("...and no rhythm, not even Unknown", [result objectForKey:TrackKeyDetectedRhythm] == nil);

    printf("\n-- and what it does when it is asked twice --\n");

    // Asking again for no more than was done: refused, silently, as before.
    // The wait is short because what is being checked is that nothing arrives.
    ckTrue("the same scan again is not run",
           sScan(worker, url, unmeasured, NO, 2.0) == nil);

    // But asking for more than was done: run again.  This is the whole of
    // switching the BPM column back on -- without it, a track scanned while it
    // was off could never be measured for the rest of the session.
    result = sScan(worker, url, unmeasured, YES, 20.0);

    ckTrue("asking for the tempo after a scan without it runs again", result != nil);
    ckTrue("...and this time there is a tempo", [[result objectForKey:TrackKeyDetectedBPM] doubleValue] > 0);

    // And now it is done, both ways round.
    ckTrue("having measured, asking to measure again is refused",
           sScan(worker, url, unmeasured, YES, 2.0) == nil);
    ckTrue("having measured, asking not to is refused too",
           sScan(worker, url, unmeasured, NO, 2.0) == nil);

    // Cancelled outranks all of it.
    NSUUID *cancelled = [NSUUID UUID];
    [worker cancelUUID:cancelled];

    ckTrue("a cancelled track is not scanned",
           sScan(worker, url, cancelled, YES, 2.0) == nil);

    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
}


static void testCost(void)
{
    printf("\n-- what it costs --\n");

    double rate = 44100;
    std::vector<float> mono = sMakeClickTrack(120.0, 180.0, rate, 0.8);

    NSDate *started = [NSDate date];

    BPMAnalyzer *analyzer = BPMAnalyzerCreate(2, rate, mono.size());
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

        // First, because it reads a peak that only ever climbs.
        testBufferSizingCost();

        testDirectFeed();
        testNothingToMeasure();
        testLengthHint();
        testThroughAFile();
        testTheWorkerGate();
        testCost();

        printf("\n%d checks, %d failed\n", sChecks, sFail);
    }

    return sFail ? 1 : 0;
}
