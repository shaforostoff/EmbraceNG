#ifndef BPMCORE_H
#define BPMCORE_H

// Tempo and rhythm analysis for Argentine tango recordings.
//
// This library is deliberately free of foobar2000, Windows and any other host:
// it takes mono PCM and standard C++, and nothing else. The foobar2000
// component is a thin shell around it, and the same sources are meant to build
// on macOS, Linux and ARM without change.
//
// Two things come out of one pass over a track:
//
//   * the tempo, expressed on the metrical level a dancer taps - the beat for
//     a tango, the bar for a vals or a milonga, the quarter note beneath
//     the skank for a reggae;
//   * which of those four rhythms it is, or none of them.
//
// The two are not independent. Deciding the tapped level needs the rhythm, so
// the classifier runs first and the tempo is reported on the level that rhythm
// implies. See docs/tango-analysis.md for how both were derived and measured.

#include <cstddef>
#include <memory>
#include <vector>

namespace bpmcore
{

class resampler;

enum rhythm_class
{
	rhythm_tango = 0,
	rhythm_vals,
	rhythm_milonga,
	rhythm_reggae,
	rhythm_other,
	rhythm_class_count
};

//! "Tango", "Vals", "Milonga", "Reggae" or "Other". Never null.
const char * rhythm_name(int cls);

struct analysis
{
	bool ok = false;         //!< false when the track was too short or too quiet
	double bpm = 0;          //!< tempo on the level a dancer taps
	int rhythm = rhythm_other;
	double confidence = 0;   //!< classifier probability for `rhythm`, 0..1
	double beat_bpm = 0;     //!< the underlying beat, before the level is chosen
	int meter = 0;           //!< beats per bar the grid settled on
	double duration = 0;     //!< seconds of audio analysed

	//! How much the tempo moves over the track, in BPM at the same metrical
	//! level as `bpm`: half the span between the 10th and 90th percentile of
	//! the tempo measured in each 12-second window. So the middle 80% of the
	//! track sits within +/- this of the middle, and a steady digital
	//! recording reads near zero while a shellac side with a wandering
	//! turntable, or an orquesta playing hard rubato, does not.
	//!
	//! Percentiles rather than a standard deviation because a beatless
	//! introduction or one badly tracked window should not set the figure.
	//! It is a floor on the real variation, not an exact account of it: each
	//! window carries its own measurement error, and a wobble finishing well
	//! inside 12 seconds is averaged away rather than seen.
	double bpm_spread = 0;
	//! Windows the spread was measured over. Below `spread_min_windows` it is
	//! left at zero, there being too little of the track to say anything.
	int spread_windows = 0;

	//! The tempo the track starts at, in BPM at the same metrical level as
	//! `bpm`; 0 where the opening had no beat to measure.
	//!
	//! Not the same question as `bpm`, which is the median over the whole
	//! side. A tango often opens faster than it settles - the orchestra eases
	//! off when the singer enters - so this is what a DJ needs to know to
	//! follow one track with another, and the two figures differ by more than
	//! rounding on any side worth the distinction.
	//!
	//! The median of the first few autocorrelation windows rather than the
	//! very first: one window is 12 seconds and carries its own error, and the
	//! first three overlap so heavily that they still describe only the
	//! opening. Where the opening is beatless the first windows that do have a
	//! beat are used, so on a track with a long rubato introduction this is the
	//! first tempo there was one to measure.
	double initial_bpm = 0;
};

//! Windows a track needs before `bpm_spread` is reported at all. At a
//! 3-second hop this is a little over 20 seconds of audio.
extern const int spread_min_windows;

//! Optional host hook. Analysis stops early and returns `ok == false` when
//! `cancelled` goes true.
class listener
{
public:
	virtual ~listener() {}
	virtual bool cancelled() { return false; }
	virtual void progress(double fraction) { (void)fraction; }
};

struct options
{
	//! Threads used for the spectral stage, which is over 90% of the run time.
	//! 0 asks the library to decide from the hardware; 1 keeps everything on
	//! the calling thread. The answer is identical either way.
	int threads = 0;
};

//! Longest stretch of audio analysed. A tango side is two to three minutes;
//! the cap only bounds memory on a mis-tagged long file.
double max_seconds();

//! Analyse mono PCM in one call.
analysis analyse(const float * mono, std::size_t count, unsigned sample_rate,
                 listener * l = nullptr, const options * opt = nullptr);

//! Accumulates audio as a decoder produces it, then analyses the lot.
//!
//! The envelope has to be normalised by the track's overall level before it is
//! compressed, and that is not knowable until the whole side has been seen, so
//! the audio is buffered rather than streamed. Mono floats cost about 10MB for
//! a three minute track, which is cheaper than decoding twice.
//!
//! Audio is downmixed and, where the input rate calls for it, resampled to the
//! analysis rate on the way in, so what is held is bounded by the track's
//! duration rather than by its sample rate - a 192kHz file costs no more to
//! collect than a 44.1kHz one.
class collector
{
public:
	explicit collector(unsigned sample_rate);
	~collector();

	//! The rate audio is being handed in at, which is not necessarily the rate
	//! the analysis will run at.
	unsigned sample_rate() const { return m_rate; }
	//! Mono samples held, at the analysis rate.
	std::size_t size() const { return m_mono.size(); }
	//! True once `max_seconds` has been reached; the host can stop decoding.
	bool full() const { return m_mono.size() >= m_limit; }

	//! Both sample types are accepted because hosts differ: foobar2000 hands
	//! over doubles on 64 bit and floats on 32 bit, for instance.
	void add_interleaved(const float * data, std::size_t frames, unsigned channels);
	void add_interleaved(const double * data, std::size_t frames, unsigned channels);
	void add_mono(const float * data, std::size_t count);
	void add_mono(const double * data, std::size_t count);

	analysis finish(listener * l = nullptr, const options * opt = nullptr);

	collector(const collector &) = delete;
	collector & operator=(const collector &) = delete;

private:
	//! Mono at the input rate, through the resampler if there is one.
	void feed(const float * mono, std::size_t count);
	std::size_t room(std::size_t frames) const;

	std::vector<float> m_mono;      //!< at m_analysis_rate
	std::vector<float> m_scratch;   //!< downmix at m_rate, before resampling
	std::unique_ptr<resampler> m_resampler;   //!< null when the rate already fits
	unsigned m_rate;
	unsigned m_analysis_rate;
	std::size_t m_limit;
};

}   // namespace bpmcore

#endif // BPMCORE_H
