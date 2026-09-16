// (c) 2026 Nick Shaforostov
// MIT License (or) 1-clause BSD License

#import "BPMAnalyzer.h"

#include <bpmcore/bpmcore.h>

#include <memory>
#include <vector>

NSString * const BPMAnalyzerRhythmUnknown = @"Unknown";


struct BPMAnalyzer {
    std::unique_ptr<bpmcore::collector> collector;
    std::vector<float> mono;        // downmix scratch, reused every buffer
    unsigned int channels;
    bpmcore::analysis result;
    bool finished;
};


BPMAnalyzer *BPMAnalyzerCreate(unsigned int channels, double sampleRate)
{
    if (!channels || !(sampleRate > 0)) return NULL;

    BPMAnalyzer *analyzer = new BPMAnalyzer();

    analyzer->collector.reset(new bpmcore::collector((unsigned)sampleRate));
    analyzer->channels = channels;
    analyzer->finished = false;

    return analyzer;
}


void BPMAnalyzerFree(BPMAnalyzer *analyzer)
{
    delete analyzer;
}


void BPMAnalyzerScanAudioBuffer(BPMAnalyzer *analyzer, AudioBufferList *bufferList, size_t frames)
{
    if (!analyzer || !bufferList || !frames || analyzer->finished) return;

    UInt32 bufferCount = bufferList->mNumberBuffers;

    // HugAudioFile asks ExtAudioFile for non-interleaved float32, so each
    // channel arrives in a buffer of its own and the downmix is a sum across
    // buffers rather than across a frame.  bpmcore's -add_interleaved would be
    // wrong here, which is why this does the mixing itself and hands over mono.
    //
    // Which makes the layout worth insisting on rather than assuming: a list
    // that is not one channel per buffer would have this reading a second
    // channel's samples as more of the first, and the tempo it measured from
    // that would look perfectly plausible.  Contributing nothing is the honest
    // failure -- too little audio reports Unknown.
    if (bufferCount != analyzer->channels) return;

    for (UInt32 i = 0; i < bufferCount; i++) {
        if (!bufferList->mBuffers[i].mData) return;
        if (bufferList->mBuffers[i].mNumberChannels != 1) return;

        // A buffer that came back short sets the count for all of them: reading
        // the full count out of the others would run past what was decoded.
        size_t available = bufferList->mBuffers[i].mDataByteSize / sizeof(float);
        if (available < frames) frames = available;
    }

    if (!frames) return;

    if (bufferCount == 1) {
        analyzer->collector->add_mono((const float *)bufferList->mBuffers[0].mData, frames);
        return;
    }

    analyzer->mono.assign(frames, 0.0f);

    for (UInt32 i = 0; i < bufferCount; i++) {
        const float *samples = (const float *)bufferList->mBuffers[i].mData;
        for (size_t j = 0; j < frames; j++) {
            analyzer->mono[j] += samples[j];
        }
    }

    float scale = 1.0f / bufferCount;
    for (size_t j = 0; j < frames; j++) {
        analyzer->mono[j] *= scale;
    }

    analyzer->collector->add_mono(analyzer->mono.data(), frames);
}


void BPMAnalyzerFinish(BPMAnalyzer *analyzer)
{
    if (!analyzer || analyzer->finished) return;

    analyzer->finished = true;

    // Left at 0, which asks bpmcore to decide from the hardware.  The stages
    // that take threads divide their work so that the answer does not depend on
    // how many they got, so this changes how long it takes and nothing else.
    bpmcore::options options;
    options.threads = 0;

    analyzer->result = analyzer->collector->finish(NULL, &options);

    // The buffered audio is the expensive part of this object and is of no
    // further use once the analysis has run.
    analyzer->collector.reset();

    analyzer->mono.clear();
    analyzer->mono.shrink_to_fit();
}


double BPMAnalyzerGetBeatsPerMinute(BPMAnalyzer *analyzer)
{
    if (!analyzer || !analyzer->result.ok) return 0;
    return analyzer->result.bpm;
}


NSString *BPMAnalyzerGetRhythm(BPMAnalyzer *analyzer)
{
    if (!analyzer || !analyzer->result.ok) return BPMAnalyzerRhythmUnknown;

    const char *name = bpmcore::rhythm_name(analyzer->result.rhythm);
    if (!name) return BPMAnalyzerRhythmUnknown;

    return [NSString stringWithUTF8String:name];
}


double BPMAnalyzerGetConfidence(BPMAnalyzer *analyzer)
{
    if (!analyzer || !analyzer->result.ok) return 0;
    return analyzer->result.confidence;
}


double BPMAnalyzerGetDuration(BPMAnalyzer *analyzer)
{
    if (!analyzer) return 0;
    return analyzer->result.duration;
}
