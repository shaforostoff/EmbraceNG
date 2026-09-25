#ifndef BPMCORE_H
#define BPMCORE_H

// Tempo, rhythm, tuning and key analysis for Argentine tango recordings.
//
// This library is deliberately free of foobar2000, Windows and any other host:
// it takes mono PCM and standard C++, and nothing else. The foobar2000
// component is a thin shell around it, and the same sources are meant to build
// on macOS, Linux and ARM without change.
//
// Four things come out of one decode of a track:
//
//   * the tempo, expressed on the metrical level a dancer taps - the beat for
//     a tango, the bar for a vals or a milonga, the quarter note beneath
//     the skank for a reggae;
//   * which of those four rhythms it is, or none of them;
//   * how far the recording sits from the A=440 grid, in cents;
//   * what key it is in, with two alternates and a confidence.
//
// The first two are not independent. Deciding the tapped level needs the
// rhythm, so the classifier runs first and the tempo is reported on the level
// that rhythm implies. See docs/tango-analysis.md for how both were derived
// and measured.
//
// The other two are independent of the tempo and of each other, and ride along
// on a decode that is happening anyway - which is the expensive part of a
// library scan. See key-detection-feature-plan.md for how they were measured
// and what was tried and rejected along the way.

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

enum key_confidence
{
	key_confidence_low = 0,
	key_confidence_medium,
	key_confidence_high
};

//! "low", "medium" or "high". Never null.
const char * key_confidence_name(int confidence);

//! One of the 24 keys, with how well the track's chroma fits its profile.
struct key_candidate
{
	int root = -1;      //!< pitch class of the tonic, 0 = C; -1 when unset
	bool minor = false;
	double score = 0;   //!< correlation with the profile, -1 to 1
};

//! How a key is spelt, given its signature: flat keys get flat names.
//!
//! Tango sits in Bb, Eb, Ab, Gm, Cm and Fm constantly, and printing those as
//! A#, D#, G# is the wrong spelling rather than a different one. Never null.
const char * key_name(int root, bool minor);

//! Candidates reported. The true key is the first of them 60% of the time and
//! somewhere in the three 93% of the time, which is the whole reason there is
//! a list rather than an answer.
enum { key_candidate_count = 3 };

//! Where a recording sits against A=440, and what key it is in.
//!
//! Two separate measurements that share one spectral pass, because the key
//! cannot be read off an off-speed transfer until the offset is known and
//! taken out.
struct key_analysis
{
	bool ok = false;   //!< false when the track was too short or had no pitch in it

	//! Cents from A=440, in (-50, +50].
	//!
	//! Known only modulo 100: a transfer running a whole semitone fast
	//! measures the same as one at pitch. `suggest_retune` is what resolves
	//! that, using the year; nothing here can.
	double tuning_cents = 0;
	//! How tightly the peaks agree about that offset, 0 to 1. Below about 0.25
	//! the track had no stable pitch to measure - applause, a drum solo, noise.
	double tuning_r = 0;
	bool tuning_ok = false;    //!< `tuning_r` cleared the threshold
	//! The offset is within 5 cents of the wrap, where the pitch-class binning
	//! becomes unstable and the key can land a semitone out.
	bool near_wrap = false;

	//! The key to report. Not necessarily `candidates[0]`: where the mode was
	//! tracked it is the profile's key signature with the mode that actually
	//! held for most of the track, which is the better answer and sometimes a
	//! different one.
	key_candidate best;

	//! The profile's own ranking, best first, with the scores it gave them.
	key_candidate candidates[key_candidate_count];
	int candidate_count = 0;
	//! Gap between the first and second candidate, which is what the
	//! confidence band is drawn from. In the top band the answer is right 86%
	//! of the time and the true key is among the candidates every time.
	double margin = 0;
	int confidence = key_confidence_low;

	//! Share of the track where the major of the relative pair was in charge,
	//! and how many times it changed hands. -1 when the track was too short to
	//! track, which needs about 21 seconds.
	//!
	//! This is not a key change: a tango with a minor A section and a major B
	//! section keeps one key signature throughout. It is which of the
	//! signature's two tonics the music is sitting on.
	double major_fraction = -1;
	int mode_switches = -1;
	int mode_windows = 0;

	//! Weight in each pitch class, summing to 1, after the tuning offset has
	//! been taken out. Kept for diagnostics; nothing downstream needs it.
	double chroma[12] = { 0 };

	double duration = 0;
	int frames = 0;
	std::size_t peaks = 0;     //!< sinusoid peaks the measurements were drawn from
};

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

	//! Tuning and key, from the same decode but not from the same spectral
	//! pass - the two want different window lengths, a tempo wanting 46ms and
	//! a pitch wanting 372ms. Left at `ok == false` when `options::detect_key`
	//! was off, and filled in even on a track whose tempo could not be
	//! measured: the two answers stand or fall separately.
	key_analysis key;
};

//! Windows a track needs before `bpm_spread` is reported at all. At a
//! 3-second hop this is a little over 20 seconds of audio.
extern const int spread_min_windows;

//! A=435 expressed against A=440, in cents. -19.79.
double key_a435_offset();

//! Speed change that applies a correction of `cents`, as a percentage.
//! Negative slows the playback down.
double retune_percent(double cents);

enum retune_target { retune_a440 = 0, retune_a435 };

//! "A=440" or "A=435". Never null.
const char * retune_target_name(int target);

//! One way of putting a transfer back on pitch.
struct retune_option
{
	double cents = 0;     //!< correction to apply
	double percent = 0;   //!< the same, as a speed change
	int target = retune_a440;
};

//! Share of recordings still cut at A=435 in `year`; -1 where no suggestion
//! should be made at all, which is an unknown year or 1976 onwards.
//!
//! Measured from TangoTunes' hand-set transfer pitches. Two orquestas three
//! years apart in switching, so the transition window 1939-1944 is wide and
//! its values are shrunk toward even odds.
double key_era_p435(int year);

//! Ranked speed corrections for a measured offset, best first.
//!
//! Writes at most `max_out` and returns how many. Returns 0 for an unknown
//! year or one from 1976 on, when there is nothing useful to say.
//!
//! There is more than one answer because the measurement is modulo 100 cents
//! and because, in the transition years, both reference pitches were in use -
//! so the year chooses the target and the candidates carry the rest.
int suggest_retune(double tuning_cents, int year, retune_option * out, int max_out);

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

	//! Measure the tuning offset and the key as well as the tempo.
	//!
	//! Roughly doubles the analysis, which is still a small fraction of what
	//! decoding the track costs. Off leaves `analysis::key` empty.
	bool detect_key = true;
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
//! the audio is buffered rather than streamed. That is one mono float per
//! sample at the analysis rate - 30MB for a three minute side at 44.1kHz -
//! which is still cheaper than decoding the side twice.
//!
//! Audio is downmixed and, where the input rate calls for it, resampled to the
//! analysis rate on the way in, so what is held is bounded by the track's
//! duration rather than by its sample rate: a 192kHz file costs no more to
//! collect than a 48kHz one. A rate that needs no resampling keeps its own,
//! though, so 44.1kHz costs twice what 48kHz does.
class collector
{
public:
	//! `expected_seconds` is how long the track is, where the host knows
	//! before it starts decoding, and 0 where it does not. It sizes the buffer
	//! and nothing else: told nothing, or told wrong, the collector holds the
	//! same audio and still stops at `max_seconds`.
	explicit collector(unsigned sample_rate, double expected_seconds = 0);
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
