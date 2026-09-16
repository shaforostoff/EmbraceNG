// (c) 2026 Nick Shaforostov
// MIT License (or) 1-clause BSD License

// Tempo and rhythm for one track, measured from the audio.
//
// A shell around `Vendor/bpmcore`, which is the analysis proper and is shared
// verbatim with foo_rubato -- see Vendor/PROVENANCE.md.  Everything here is
// plumbing: a downmix out of CoreAudio's non-interleaved buffers, and the
// rhythm class as a string the rest of the app can store and read back.
//
// Shaped like LoudnessMeasurer on purpose.  Both want the same thing -- every
// frame of the track, once, in order -- so the worker's existing decode loop
// feeds them side by side and the track is never read twice:
//
//     BPMAnalyzer *analyzer = BPMAnalyzerCreate(channels, sampleRate);
//     while (...) BPMAnalyzerScanAudioBuffer(analyzer, bufferList, frameCount);
//     BPMAnalyzerFinish(analyzer);
//     ... BPMAnalyzerGetBeatsPerMinute(analyzer) ...
//     BPMAnalyzerFree(analyzer);
//
// The audio is buffered rather than streamed through, because the onset
// envelope has to be normalised by the track's overall level before it is
// compressed and that is not knowable until the last frame has been seen.  At
// the 22.05kHz the analysis runs at that is about 5MB for a three minute side,
// whatever rate the file is in.

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#import  <Foundation/Foundation.h>
#include <AudioToolbox/AudioToolbox.h>

typedef struct BPMAnalyzer BPMAnalyzer;

extern BPMAnalyzer *BPMAnalyzerCreate(unsigned int channels, double sampleRate);
extern void BPMAnalyzerFree(BPMAnalyzer *analyzer);

// Non-interleaved float32, one buffer per channel -- what HugAudioFile reads.
extern void BPMAnalyzerScanAudioBuffer(BPMAnalyzer *analyzer, AudioBufferList *bufferList, size_t frames);

// There is no "stop, I have enough" here on purpose, though bpmcore does cap
// what it will hold.  The worker's loop cannot stop early whatever this said:
// the loudness overview beside it is a waveform of the whole track and needs
// every frame.  Audio past the cap is handed over and dropped.

// Runs the analysis over everything scanned.  Call once, and only then read.
extern void BPMAnalyzerFinish(BPMAnalyzer *analyzer);

// The tempo at the metrical level a dancer taps -- the beat for a tango, the
// bar for a vals or a milonga.  0 when the track was too short or too quiet to
// measure, which is also when -GetRhythm reads Unknown.
extern double BPMAnalyzerGetBeatsPerMinute(BPMAnalyzer *analyzer);

// "Tango", "Vals", "Milonga", "Reggae", "Other", or BPMAnalyzerRhythmUnknown.
// Never nil.  Stored as a name rather than a number because it is written to a
// track's state file and read back by a later build, where a renumbered enum
// would silently mean something else.
extern NSString *BPMAnalyzerGetRhythm(BPMAnalyzer *analyzer);

// The classifier's probability for that rhythm, 0..1.
extern double BPMAnalyzerGetConfidence(BPMAnalyzer *analyzer);

// Seconds of audio the analysis actually saw, which is the whole track unless
// the length cap stopped it.
extern double BPMAnalyzerGetDuration(BPMAnalyzer *analyzer);

// Nothing was measured.  Distinct from "Other", which is a measurement that
// came back none of the four -- a cortina.  This one means we do not know, and
// nothing should be concluded from it.
extern NSString * const BPMAnalyzerRhythmUnknown;

#ifdef __cplusplus
}
#endif
