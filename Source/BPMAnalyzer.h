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
//     BPMAnalyzer *analyzer = BPMAnalyzerCreate(channels, sampleRate, totalFrames);
//     while (...) BPMAnalyzerScanAudioBuffer(analyzer, bufferList, frameCount);
//     BPMAnalyzerFinish(analyzer);
//     ... BPMAnalyzerGetBeatsPerMinute(analyzer) ...
//     BPMAnalyzerFree(analyzer);
//
// The audio is buffered rather than streamed through, because the onset
// envelope has to be normalised by the track's overall level before it is
// compressed and that is not knowable until the last frame has been seen.  That
// is one mono float per sample -- about 30MB for a three minute side at
// 44.1kHz -- which is still cheaper than decoding the track twice.
//
// Resampling on the way in bounds that by duration rather than by sample rate,
// but only where it happens: 22.05kHz and its powers of two reproduce the
// analysis exactly and so are kept at their own rate.  44.1kHz is therefore the
// expensive case, and a 192kHz file costs what a 48kHz one does.

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#import  <Foundation/Foundation.h>
#include <AudioToolbox/AudioToolbox.h>

typedef struct BPMAnalyzer BPMAnalyzer;

// `totalFrames` is how long the track is, in frames at `sampleRate`, which the
// worker has out of the file before it decodes a byte of it.  It sizes that
// buffer and nothing else: told 0, or told wrong, the analyzer holds the same
// audio and measures the same tempo.
//
// Worth passing all the same.  A vector that outgrows its reserve doubles, and
// the copy has the old buffer and the new one resident at once -- a fifteen
// minute side at 44.1kHz grew 42MB, 85MB, 169MB, holding 254MB at the last hop
// for audio that needs 159MB.  Upstream measured the whole scan's peak at
// 273MB that way and 152MB sized for the track; a side under four minutes does
// not move either way, because the old reserve was pages nothing touched.
extern BPMAnalyzer *BPMAnalyzerCreate(unsigned int channels, double sampleRate, size_t totalFrames);
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
