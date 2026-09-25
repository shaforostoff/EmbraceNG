#include "internal.h"
#include "parallel.h"
#include "real_fft.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

// Tuning offset, key, and the retune suggestion that follows from both.
//
// Three measurements off one spectral pass, in increasing order of how much
// they can be trusted:
//
//   tuning   where the recording's twelve-tone grid sits against A=440, in
//            cents. Known only modulo 100 - a transfer a whole semitone fast
//            measures the same as one at pitch - and resolving that ambiguity
//            is the retune suggestion's job, not this stage's.
//   key      the whole-track chroma correlated against the Albrecht and
//            Shanahan profiles over all 24 keys, with the mode then settled
//            separately by tracking. Right 79% of the time and on the right
//            tonic 93%, with the true key among the three candidates 95% of
//            the time, which is why the candidates are reported rather than
//            thrown away.
//
//            The margin ranks again since harmonics are attributed to their
//            fundamentals: top third by margin 100% exact, middle 74%, bottom
//            63%. The thresholds themselves are still the ones fitted before
//            either of the last two changes and have not been refitted.
//   retune   the era target and its semitone wraps, ranked.
//
// Every figure here was measured against TangoTunes' hand-made discography
// data - 130 Biagi transfers with a hand-set pitch, 58 Troilo sides with a
// hand-written recording key - and not against another detector's output.
// key-detection-feature-plan.md records what was tried and rejected, which
// includes three ideas that looked convincing on one track and died against
// the labels. Nothing here should be adopted on the strength of one example.

namespace bpmcore
{

// The geometry the measurements were made at, in seconds rather than samples,
// so a 44.1kHz file gets a 16384-point window and the same 2.69Hz per bin that
// 8192 points give at 22.05kHz. Everything downstream - the whitening width,
// the search band, the peak threshold - is then in Hz and rate-independent by
// construction, which is what lets this run on whatever the collector happens
// to hold rather than resampling the track a second time.
const double key_window_seconds = 8192.0 / 22050.0;   // 371.5ms
const double key_hop_seconds    = 2048.0 / 22050.0;   //  92.9ms

// Bandoneon and violin fundamentals through their first few harmonics. Below
// this is turntable rumble; above it, on a 78, mostly surface noise.
//
// The floor is not free to move. A semitone at 180Hz is 10.7Hz, which at this
// window is four bins - the width of the Hann main lobe - so below it peak
// picking cannot separate two semitones at all. Reaching the bass would mean a
// window over twice as long, and that was measured: at 743ms the whole thing
// falls to 47% exact from 60%, band unchanged, because a window that long
// straddles two beats at tango tempo and mixes the chords either side. Opening
// the ceiling to 3520Hz is worse too - it spends the peak budget on surface
// noise. Both directions are in the record; neither is an oversight.
const double key_fmin_hz = 180.0;
const double key_fmax_hz = 2200.0;

// Half the width of the running median the spectrum is divided by, as a
// distance in pitch rather than in Hz. Flattening the shellac rolloff this way
// is what makes peak picking work on a 78 at all: without it every peak found
// is in the bottom two octaves.
//
// It used to be a fixed 134.6Hz, which is a different thing entirely at each
// end of the band - 33 semitones wide at 180Hz, and 2.1 at 2200Hz, where it is
// narrower than the spacing it is supposed to be measuring against. It was
// right only around 1400Hz. Holding it at a fixed pitch width instead is worth
// 60.3% -> 69.0% exact and 74.1% -> 79.3% on the tonic over the 58 labelled
// Troilo sides, gaining five and losing none.
//
// 3.17 semitones is nnls-chroma's own whitening window (19 bins at three per
// semitone), taken from there rather than fitted here - which matters, because
// a sweep over this collection puts its best cell at exactly that value and a
// sweep of twelve cells on 58 tracks would find a best cell anywhere. What the
// sweep does support is the weaker claim: at 3.17, 4.0, 6.0 and 9.0 semitones
// the change never loses a side and gains three to five, while below about 2.5
// it is worse than the fixed width was. The size of the gain is not
// established; its sign is.
const double key_whiten_half_semitones = 3.17;

// Never narrower than this, whatever the rate and window make of the figure
// above. A partial is four bins wide, so a window much under this would divide
// a peak by a median that the peak itself dominates and whiten it away.
const int key_whiten_min_bins = 12;

// A local maximum counts as a sinusoid at this multiple of the whitened
// background, and at most this many are kept per frame - enough for a chord
// and its harmonics, few enough that a noisy frame cannot flood the histogram.
const double key_peak_floor = 3.0;
const int key_peaks_per_frame = 16;

// Frequency ratios at which a peak is taken to be a harmonic of a stronger
// peak below it, and counted at that peak's pitch class instead of its own.
//
// A bandoneon or piano note puts real energy in its 3rd harmonic, which is a
// fifth up, and its 5th, a major third up. Peak picking counts those as notes
// played, and that is where the fifth-above error comes from: 11 of the 23
// Troilo misses before this. nnls-chroma handles it with a harmonic
// dictionary and a non-negative least-squares fit per frame. This is a far
// cheaper approximation of the same idea - a pairwise check over at most
// sixteen peaks.
//
// 3, 5, 6 and 7 are harmonics that land on another pitch class (2, 4 and 8
// are octaves and land on the same one anyway). 1.5 is the 3rd harmonic over
// the 2nd of a bass note below the 180Hz floor, whose fundamental is never
// seen here. 1.25, the 5th over the 4th, is left out on purpose: it deletes
// the major third of every major chord, and with it in, 62 corpus tracks that
// nnls-chroma reads major came out as the parallel minor.
//
// Measured with the rest of the stage unchanged, on the 58 labelled Troilo
// sides and against nnls-chroma's own treble chroma over a 766-track sample
// of C:\TangoTunes:
//
//                      Troilo exact   tonic   agrees with nnls
//     without           69.0%        79.3%     74.4%
//     with              79.3%        93.1%     91.5%
//     nnls-chroma       81.0%        93.1%
//
// Eight sides gained and two lost (Tinta roja, Barrio de tango - both major
// read as the parallel minor), which on 58 sides alone is z=1.90 and short of
// significance; the agreement figure, over thirteen times as many tracks, is
// the stronger evidence. nnls-chroma is a fair yardstick for it because the
// Troilo keys were set by ear, on passages where only the piano plays, not
// read off any detector. Adding 2.5, 3.5 (and 1.75) was within two sides
// either way on Troilo and about a point lower on agreement, so the smaller
// set was kept.
const double key_harmonic_ratios[] = { 3.0, 5.0, 6.0, 7.0, 1.5 };
const int key_harmonic_ratio_count =
	static_cast<int>(sizeof key_harmonic_ratios / sizeof *key_harmonic_ratios);
const double key_harmonic_tolerance_cents = 30.0;

// Frames quieter than this fraction of the track's median frame are skipped: a
// lead-in groove has no pitch in it, and its noise floor whitens into peaks
// like anything else would.
const double key_frame_gate = 0.4;

// Windows the mode is tracked over. Twelve seconds is about a phrase, and at a
// three-second hop a 32-bar section gets several windows to itself.
const double key_mode_window_seconds = 12.0;
const double key_mode_hop_seconds = 3.0;

const double key_tuning_min_r = 0.25;
const double key_wrap_warn_cents = 45.0;
// Fitted against the fixed-Hz background window. They stopped ranking under the
// pitch-width one and rank again with harmonic attribution - high 89% exact,
// medium and low 64% on the labelled sides. Left alone on purpose: refitting
// them would be refitting them on the only 58 sides there are to test against.
const double key_margin_high = 0.104;
const double key_margin_medium = 0.040;
const double key_retune_max_cents = 60.0;

// Albrecht and Shanahan (2013), fitted to a corpus of common-practice tonal
// music. Measured best on this material by a wide margin: 58% exact against
// Temperley's 53% and Krumhansl-Kessler's 20%, on the labelled sides and with
// the Python reference, which is where the three were compared. KK is tuned
// to classical probe-tone data and is not usable here at all.
const double key_profile_major[12] =
	{ .238, .006, .111, .006, .137, .094, .016, .214, .009, .080, .008, .081 };
const double key_profile_minor[12] =
	{ .220, .006, .104, .123, .019, .103, .012, .214, .062, .022, .061, .052 };

// A=435 against A=440, in cents. Not a constant expression while this target
// still offers to build as C++11, so it is computed once at load.
const double key_a435_cents = -1200.0 * std::log(440.0 / 435.0) / std::log(2.0);

// The background window as a fraction of the centre frequency. A span of
// +/-s semitones reaches further above a bin than below it, so the symmetric
// window the median slides over takes the average of the two - the difference
// is under a bin at the bottom of the band and immaterial to a median anyway.
const double key_whiten_frac =
	0.5 * ((std::pow(2.0, key_whiten_half_semitones / 12.0) - 1.0) +
	       (1.0 - std::pow(2.0, -key_whiten_half_semitones / 12.0)));

namespace
{
	//! key_harmonic_ratios in octaves, which is what the per-frame check compares.
	struct harmonic_log2_table
	{
		double v[sizeof key_harmonic_ratios / sizeof *key_harmonic_ratios];
		harmonic_log2_table()
		{
			for (int k = 0; k < key_harmonic_ratio_count; k++)
				v[k] = std::log(key_harmonic_ratios[k]) / std::log(2.0);
		}
		double operator[](int k) const { return v[k]; }
	};
	const harmonic_log2_table key_harmonic_log2;

	// Name a key the way its own key signature spells it.
	//
	// Tango sits in Bb, Eb, Ab, Gm, Cm and Fm constantly. Printing those as A#,
	// D#, G# is not a matter of taste - it is the wrong spelling for the
	// signature, and it is the first thing anyone reading the tag will notice.
	const char * const major_names[12] =
		{ "C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B" };
	const char * const minor_names[12] =
		{ "Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "Bbm", "Bm" };

	const double two_pi = 6.283185307179586;

	double hann(int i, int n)
	{
		return n > 1 ? 0.5 * (1.0 - std::cos(two_pi * i / (n - 1))) : 1.0;
	}

	//! Pearson correlation of two twelve-element vectors.
	double correlate12(const double * a, const double * b)
	{
		double ma = 0, mb = 0;
		for (int i = 0; i < 12; i++) { ma += a[i]; mb += b[i]; }
		ma /= 12; mb /= 12;
		double num = 0, da = 0, db = 0;
		for (int i = 0; i < 12; i++)
		{
			const double x = a[i] - ma, y = b[i] - mb;
			num += x * y; da += x * x; db += y * y;
		}
		const double d = std::sqrt(da * db);
		return d > 0 ? num / d : 0.0;
	}

	//! Correlation of a chroma against a profile rooted on `root`.
	double correlate_profile(const double * chroma, const double * profile, int root)
	{
		double rolled[12];
		for (int i = 0; i < 12; i++) rolled[i] = profile[((i - root) % 12 + 12) % 12];
		return correlate12(chroma, rolled);
	}

	//! Sliding median over a fixed window, advanced one sample at a time.
	//!
	//! This, not the transform, is the expensive part of the stage: 750 medians
	//! of 101 values for every frame of every track. Keeping the window sorted
	//! and moving one element per step costs a binary search and a memmove of
	//! at most half the window, which measured about ten times faster than an
	//! nth_element per bin.
	class running_median
	{
	public:
		//! `first` points at `width` values - the window in its starting
		//! position, which this takes a sorted copy of.
		void reset(const float * first, int width)
		{
			m_sorted.assign(first, first + width);
			std::sort(m_sorted.begin(), m_sorted.end());
		}

		float median() const { return m_sorted[m_sorted.size() / 2]; }

		//! Replace `out`, which must be in the window, with `in`.
		//!
		//! Both positions are counted rather than searched for. Over a sorted
		//! window the number of values below `out` is its own index, and the
		//! number at or below `in` is one past where `in` belongs, so two
		//! branchless passes give what two binary searches would - and the
		//! compiler vectorises the passes, which it cannot do with a search.
		//! Measured 1.8x faster over the real geometry, bit for bit the same
		//! window afterwards.
		void slide(float out, float in)
		{
			float * const s = m_sorted.data();
			const int n = static_cast<int>(m_sorted.size());
			if (in > out)
			{
				int i = 0, j = 0;
				for (int k = 0; k < n; k++) { i += (s[k] < out); j += (s[k] <= in); }
				--j;
				// Everything in (i, j] slides down one place and `in` lands at j.
				for (int k = i; k < j; k++) s[k] = s[k + 1];
				s[j] = in;
			}
			else if (in < out)
			{
				int i = 0, j = 0;
				for (int k = 0; k < n; k++) { i += (s[k] < out); j += (s[k] < in); }
				for (int k = i; k > j; k--) s[k] = s[k - 1];
				s[j] = in;
			}
			// in == out leaves the window exactly as it was.
		}

	private:
		std::vector<float> m_sorted;
	};

	//! Half the width of the background window at `bin`, in bins.
	//!
	//! Held constant within each octave rather than recomputed per bin, which
	//! is what keeps the sliding median affordable: the window is rebuilt once
	//! per octave and slid everywhere else. Inside an octave the width is up to
	//! 41% away from the figure a per-bin calculation would give, which for a
	//! median of a few hundred noise bins is not a distinction that survives
	//! being measured.
	int whiten_half_bins(int bin, int nfft, unsigned rate)
	{
		const double f = static_cast<double>(bin) * rate / nfft;
		const double octave = std::floor(std::log(f / key_fmin_hz) / std::log(2.0));
		const double centre = key_fmin_hz * std::pow(2.0, octave + 0.5);
		const int h = static_cast<int>(
			std::lround(centre * key_whiten_frac * nfft / rate));
		return h > key_whiten_min_bins ? h : key_whiten_min_bins;
	}

	//! Everything the per-frame loop needs that does not change between frames.
	struct key_plan
	{
		const float * mono = nullptr;
		const float * rms = nullptr;
		double gate = 0;
		int hop = 0;
		int nfft = 0;
		int nbin = 0;
		int lo = 0, hi = 0;      //!< bins the peak search runs over, [lo, hi)
		const int * half_at = nullptr;   //!< median half width per bin of [lo, hi)
		int max_half = 0;        //!< the widest of those, which sets the reach
		int ext_len = 0;         //!< (hi - lo) + 2 * max_half
		unsigned rate = 0;
		const double * window = nullptr;
		int max_peaks = 0;
		//! max_peaks per frame, with `count` saying how many are set.
		float * freq = nullptr;
		float * mag = nullptr;
		std::uint8_t * count = nullptr;
	};

	//! Picks the sinusoid peaks out of one block of frames.
	//!
	//! Frames are independent here - unlike the onset envelope, nothing is
	//! differenced against the frame before - so a block boundary cannot change
	//! the result and no frame needs re-deriving.
	class key_worker
	{
	public:
		explicit key_worker(const key_plan & plan)
			: m_plan(plan), m_fft(plan.nfft),
			  m_ext(static_cast<std::size_t>(plan.ext_len)),
			  m_white(static_cast<std::size_t>(plan.hi - plan.lo)) {}

		bool valid() const { return m_fft.valid(); }

		void run(int begin, int end)
		{
			const key_plan & p = m_plan;
			for (int f = begin; f < end; f++)
			{
				p.count[f] = 0;
				if (p.rms[f] < p.gate) continue;
				frame(f);
			}
		}

		key_worker(const key_worker &) = delete;
		key_worker & operator=(const key_worker &) = delete;

	private:
		void frame(int f)
		{
			const key_plan & p = m_plan;
			const float * src = p.mono + static_cast<std::size_t>(f) * p.hop;
			fft_scalar * in = m_fft.input();
			for (int i = 0; i < p.nfft; i++)
				in[i] = static_cast<fft_scalar>(src[i] * p.window[i]);
			m_fft.forward();

			// Magnitudes over the search band plus the median's reach either
			// side. Bins past the ends of the spectrum repeat the edge, which
			// at every rate the analysis actually runs at never happens: the
			// band starts at bin 66 and the reach is 50.
			const fft_cpx * bins = m_fft.bins();
			for (int i = 0; i < p.ext_len; i++)
			{
				int k = p.lo - p.max_half + i;
				if (k < 0) k = 0;
				else if (k >= p.nbin) k = p.nbin - 1;
				const double re = bins[k].r, im = bins[k].i;
				m_ext[i] = static_cast<float>(std::sqrt(re * re + im * im) + 1e-12);
			}

			// Divide by the running median: what is left is how far each bin
			// stands above its own neighbourhood, which is flat across the
			// spectrum however steeply the transfer rolls off.
			//
			// The neighbourhood is a fixed distance in pitch, so it widens with
			// frequency. It changes once an octave, and the median is rebuilt
			// there and slid between - a handful of sorts per frame against the
			// several hundred slides they save.
			const int span = p.hi - p.lo;
			int cur_half = -1;
			for (int j = 0; j < span; j++)
			{
				const int h = p.half_at[j];
				const int centre = p.max_half + j;
				if (h != cur_half)
				{
					m_median.reset(m_ext.data() + centre - h, 2 * h + 1);
					cur_half = h;
				}
				else
				{
					m_median.slide(m_ext[centre - h - 1], m_ext[centre + h]);
				}
				m_white[j] = m_ext[centre] / m_median.median();
			}

			// Local maxima clear of the background. The interpolation reads the
			// raw magnitudes rather than the whitened ones: whitening applies a
			// different divisor at each of the three bins and would bend the
			// parabola the peak position is read off.
			m_freq.clear();
			m_val.clear();
			for (int j = 1; j < span - 1; j++)
			{
				const float w = m_white[j];
				if (!(w > m_white[j - 1] && w > m_white[j + 1] && w > key_peak_floor)) continue;
				const double a = m_ext[p.max_half + j - 1];
				const double b = m_ext[p.max_half + j];
				const double c = m_ext[p.max_half + j + 1];
				const double den = a - 2 * b + c;
				double d = 0;
				if (std::fabs(den) > 1e-12) d = 0.5 * (a - c) / den;
				if (d < -0.5) d = -0.5; else if (d > 0.5) d = 0.5;
				m_freq.push_back(static_cast<float>(
					(p.lo + j + d) * static_cast<double>(p.rate) / p.nfft));
				m_val.push_back(w);
			}
			// One peak is a hum or a click, not a chord.
			if (m_freq.size() < 2) return;

			// The strongest handful. Which order they end up in does not
			// matter: everything downstream is a weighted sum over them.
			const std::size_t take = std::min(m_freq.size(),
			                                  static_cast<std::size_t>(p.max_peaks));
			m_order.resize(m_freq.size());
			for (std::size_t i = 0; i < m_order.size(); i++) m_order[i] = i;
			if (take < m_order.size())
			{
				const std::vector<float> & v = m_val;
				std::nth_element(m_order.begin(), m_order.begin() + take, m_order.end(),
				                 [&v](std::size_t x, std::size_t y) { return v[x] > v[y]; });
			}

			float * fo = p.freq + static_cast<std::size_t>(f) * p.max_peaks;
			float * mo = p.mag + static_cast<std::size_t>(f) * p.max_peaks;
			for (std::size_t i = 0; i < take; i++)
			{
				fo[i] = m_freq[m_order[i]];
				mo[i] = m_val[m_order[i]];
			}
			p.count[f] = static_cast<std::uint8_t>(take);
		}

		const key_plan & m_plan;
		real_fft m_fft;
		running_median m_median;
		std::vector<float> m_ext;     //!< raw magnitudes, median reach included
		std::vector<float> m_white;   //!< whitened, over the search band
		std::vector<float> m_freq, m_val;
		std::vector<std::size_t> m_order;
	};

	//! Frames below this are not worth a thread hand-off.
	const int min_frames_per_thread = 64;

	//! Per-frame RMS of the raw audio, which the silence gate is drawn from.
	void frame_rms(const float * mono, int frames, int nfft, int hop,
	               std::vector<float> & out, int threads)
	{
		out.assign(static_cast<std::size_t>(frames), 0.0f);
		const int n_threads = resolve_threads(threads, frames, 4 * min_frames_per_thread);
		const int block = std::max(64, (frames + n_threads - 1) / n_threads);
		const int blocks = (frames + block - 1) / block;
		// Windows overlap four to one at the geometry this actually runs at,
		// so summing each one whole reads every sample four times. One sum per
		// hop, added up in fours, reads each sample once and measured four
		// times faster. The association changes, so the last bits of the sum
		// can; the gate it feeds is a comparison against 0.4 of the median,
		// and over 135 sides not one frame changed sides.
		//
		// Only where the window is a whole number of hops, which is every rate
		// that reaches here by the ordinary route. The odd-rate fallback keeps
		// the direct sum.
		if (nfft % hop == 0)
		{
			const int per = nfft / hop;
			const int blks = frames + per - 1;
			std::vector<double> hop_sum(static_cast<std::size_t>(blks), 0.0);
			const int hop_threads = resolve_threads(threads, blks, min_frames_per_thread);
			const int hop_block = std::max(64, (blks + hop_threads - 1) / hop_threads);
			parallel_blocks((blks + hop_block - 1) / hop_block, hop_threads, [&](int b)
			{
				const int begin = b * hop_block, end = std::min(begin + hop_block, blks);
				for (int h = begin; h < end; h++)
				{
					const float * src = mono + static_cast<std::size_t>(h) * hop;
					double sum = 0;
					for (int i = 0; i < hop; i++) sum += static_cast<double>(src[i]) * src[i];
					hop_sum[h] = sum;
				}
			});
			for (int f = 0; f < frames; f++)
			{
				double sum = 0;
				for (int i = 0; i < per; i++) sum += hop_sum[f + i];
				out[f] = static_cast<float>(std::sqrt(sum / nfft));
			}
			return;
		}

		parallel_blocks(blocks, n_threads, [&](int b)
		{
			const int begin = b * block, end = std::min(begin + block, frames);
			for (int f = begin; f < end; f++)
			{
				const float * src = mono + static_cast<std::size_t>(f) * hop;
				double sum = 0;
				for (int i = 0; i < nfft; i++) sum += static_cast<double>(src[i]) * src[i];
				out[f] = static_cast<float>(std::sqrt(sum / nfft));
			}
		});
	}

	//! Takes its copy by value: the median is wanted, not a sorted array.
	double median_of(std::vector<float> v)
	{
		if (v.empty()) return 0;
		const std::size_t n = v.size(), mid = n / 2;
		std::nth_element(v.begin(), v.begin() + mid, v.end());
		const double upper = v[mid];
		if (n % 2 != 0) return upper;
		const double lower = *std::max_element(v.begin(), v.begin() + mid);
		return 0.5 * (lower + upper);
	}
}

const char * key_name(int root, bool minor)
{
	if (root < 0 || root > 11) return "?";
	return minor ? minor_names[root] : major_names[root];
}

const char * key_confidence_name(int confidence)
{
	switch (confidence)
	{
	case key_confidence_high:   return "high";
	case key_confidence_medium: return "medium";
	default:                    return "low";
	}
}

const char * retune_target_name(int target)
{
	return target == retune_a435 ? "A=435" : "A=440";
}

double retune_percent(double cents)
{
	return (std::pow(2.0, -cents / 1200.0) - 1.0) * 100.0;
}

double key_a435_offset() { return key_a435_cents; }

// Share of recordings still cut at A=435, by year, from TangoTunes' own
// hand-set transfer pitches: Biagi 1927-1948 and Troilo 1938-1945, 281 dated
// sides between them. The two orquestas moved three years apart - Troilo was
// on 440 by 1941, Biagi stayed at 435 through 1943 - which is why no single
// cutover year works and why the transition window has to be a generous one.
// Values inside it are shrunk toward even odds, this being two orquestas and
// not a survey.
double key_era_p435(int year)
{
	if (year <= 0 || year >= 1976) return -1.0;     // no suggestion at all
	if (year < 1939) return 0.75;                   // measured 100%, shrunk
	switch (year)
	{
	case 1939: return 0.70;
	case 1940: return 0.65;
	case 1941: return 0.50;   // measured 43%
	case 1942: return 0.45;   // measured 33%
	case 1943: return 0.42;   // measured 29%
	case 1944: return 0.25;   // measured 0%, shrunk
	default:   return 0.0;    // 1945-1975: A=440 alone
	}
}

int suggest_retune(double tuning_cents, int year, retune_option * out, int max_out)
{
	if (out == nullptr || max_out <= 0) return 0;
	const double p435 = key_era_p435(year);
	if (p435 < 0) return 0;

	struct scored { double rank; retune_option opt; };
	scored all[6];
	int n = 0;

	// The offset is known only modulo 100 cents, so each era target is worth
	// three candidates: the offset itself and its two semitone wraps.
	const double wraps[3] = { 0.0, -100.0, +100.0 };
	for (int w = 0; w < 3; w++)
	{
		for (int t = 0; t < 2; t++)
		{
			// A=435 is only offered where the era gives it any weight at all,
			// so a 1950 side is never told to slow down 0.9% for no reason.
			const bool a435 = t == 0;
			if (a435 && p435 <= 0.0) continue;
			const double target = a435 ? key_a435_cents : 0.0;
			const double prior = a435 ? p435 : 1.0 - p435;
			const double err = tuning_cents + wraps[w] - target;
			if (std::fabs(err) > key_retune_max_cents) continue;
			// Nearest correction first, with the era prior worth up to 45
			// cents of distance: enough to prefer the historically likely
			// target when the two are close, never enough to push a wrap ahead
			// of a correction half its size.
			all[n].rank = std::fabs(err) / 100.0 - 0.45 * prior;
			all[n].opt.cents = err;
			all[n].opt.percent = retune_percent(err);
			all[n].opt.target = a435 ? retune_a435 : retune_a440;
			n++;
		}
	}

	std::stable_sort(all, all + n, [](const scored & a, const scored & b)
	                 { return a.rank < b.rank; });

	int kept = 0;
	for (int i = 0; i < n && kept < max_out; i++)
	{
		bool duplicate = false;
		for (int j = 0; j < kept; j++)
		{
			if (out[j].target == all[i].opt.target &&
			    std::fabs(out[j].cents - all[i].opt.cents) < 2.0)
			{
				duplicate = true;
				break;
			}
		}
		if (!duplicate) out[kept++] = all[i].opt;
	}
	return kept;
}

bool compute_key(const float * mono, std::size_t count, unsigned sample_rate,
                 key_analysis & out, listener * l, int threads)
{
	out = key_analysis();
	if (mono == nullptr || count == 0 || sample_rate == 0) return false;

	const int hop = std::max(1, static_cast<int>(std::lround(key_hop_seconds * sample_rate)));
	const int nfft = fft_size_for(
		static_cast<int>(std::lround(key_window_seconds * sample_rate)));
	const int nbin = nfft / 2 + 1;
	if (count < static_cast<std::size_t>(nfft) + static_cast<std::size_t>(hop)) return false;

	const int frames = 1 + static_cast<int>((count - nfft) / hop);
	if (frames < 4) return false;
	out.duration = static_cast<double>(count) / sample_rate;

	key_plan plan;
	plan.mono = mono;
	plan.hop = hop;
	plan.nfft = nfft;
	plan.nbin = nbin;
	plan.rate = sample_rate;
	plan.max_peaks = key_peaks_per_frame;
	plan.lo = static_cast<int>(key_fmin_hz * nfft / sample_rate);
	plan.hi = static_cast<int>(key_fmax_hz * nfft / sample_rate);
	if (plan.hi > nbin) plan.hi = nbin;
	if (plan.hi - plan.lo < 4) return false;

	// The background width per bin, and the widest of them, which is how far
	// past each end of the band the magnitudes have to be gathered.
	std::vector<int> half_at(static_cast<std::size_t>(plan.hi - plan.lo));
	plan.max_half = 1;
	for (int j = 0; j < plan.hi - plan.lo; j++)
	{
		const int h = whiten_half_bins(plan.lo + j, nfft, sample_rate);
		half_at[j] = h;
		if (h > plan.max_half) plan.max_half = h;
	}
	if (plan.max_half * 2 + 1 > nbin) return false;
	plan.half_at = half_at.data();
	plan.ext_len = (plan.hi - plan.lo) + 2 * plan.max_half;

	std::vector<float> rms;
	frame_rms(mono, frames, nfft, hop, rms, threads);
	plan.rms = rms.data();
	plan.gate = median_of(rms) * key_frame_gate;

	std::vector<double> window(static_cast<std::size_t>(nfft));
	for (int i = 0; i < nfft; i++) window[i] = hann(i, nfft);
	plan.window = window.data();

	std::vector<float> peak_freq(static_cast<std::size_t>(frames) * plan.max_peaks, 0.0f);
	std::vector<float> peak_mag(peak_freq.size(), 0.0f);
	std::vector<std::uint8_t> peak_count(static_cast<std::size_t>(frames), 0);
	plan.freq = peak_freq.data();
	plan.mag = peak_mag.data();
	plan.count = peak_count.data();

	// Blocks from a shared counter, and only the calling thread touches the
	// listener - a host's abort and progress hooks need not be thread safe.
	// This mirrors compute_odf; the note there explains why.
	const int n_threads = resolve_threads(threads, frames, min_frames_per_thread);
	const int block = std::max(32, frames / std::max(1, n_threads * 8));
	const int n_blocks = (frames + block - 1) / block;
	std::atomic<int> next(0);
	std::atomic<bool> stop(false);

	auto take = [&](key_worker & w)
	{
		for (;;)
		{
			const int i = next.fetch_add(1);
			if (i >= n_blocks || stop.load()) return;
			w.run(i * block, std::min((i + 1) * block, frames));
		}
	};

	std::vector<std::thread> pool;
	pool.reserve(static_cast<std::size_t>(std::max(0, n_threads - 1)));
	for (int t = 0; t < n_threads - 1; t++)
	{
		pool.emplace_back([&plan, &take]()
		{
			key_worker w(plan);
			if (w.valid()) take(w);
		});
	}
	{
		key_worker mine(plan);
		if (!mine.valid())
		{
			stop.store(true);
		}
		else
		{
			for (;;)
			{
				const int i = next.fetch_add(1);
				if (i >= n_blocks) break;
				if (l != nullptr)
				{
					if (l->cancelled()) { stop.store(true); break; }
					l->progress(static_cast<double>(i) / n_blocks);
				}
				mine.run(i * block, std::min((i + 1) * block, frames));
			}
		}
	}
	for (std::size_t t = 0; t < pool.size(); t++) pool[t].join();
	if (stop.load()) return false;

	// ---- tuning ----
	//
	// Each peak says where it sits between two semitones of the A=440 grid.
	// Averaging that on the 100-cent circle rather than on the line is what
	// stops a peak 49 cents sharp and one 49 cents flat - which are 2 cents
	// apart, not 98 - from cancelling. The fold to +/-50 cents that the
	// arithmetic would otherwise need falls out of the complex exponential on
	// its own: exp(2i.pi.dev/100) and exp(2i.pi.cents/100) are the same number.
	double vr = 0, vi = 0, wsum = 0;
	std::size_t total_peaks = 0;
	const double inv_log2 = 1.0 / std::log(2.0);
	for (int f = 0; f < frames; f++)
	{
		const int c = peak_count[f];
		const float * fp = peak_freq.data() + static_cast<std::size_t>(f) * plan.max_peaks;
		const float * mp = peak_mag.data() + static_cast<std::size_t>(f) * plan.max_peaks;
		for (int i = 0; i < c; i++)
		{
			const double cents = 1200.0 * std::log(fp[i] / 440.0) * inv_log2;
			const double w = std::log1p(mp[i]);
			const double a = two_pi * cents / 100.0;
			vr += w * std::cos(a);
			vi += w * std::sin(a);
			wsum += w;
		}
		total_peaks += static_cast<std::size_t>(c);
	}
	out.peaks = total_peaks;
	if (wsum <= 0 || total_peaks < 24) return false;

	vr /= wsum; vi /= wsum;
	out.tuning_cents = std::atan2(vi, vr) * 100.0 / two_pi;
	out.tuning_r = std::sqrt(vr * vr + vi * vi);
	out.tuning_ok = out.tuning_r >= key_tuning_min_r;
	out.near_wrap = std::fabs(out.tuning_cents) > key_wrap_warn_cents;

	// ---- chroma ----
	//
	// Subtracting the measured offset before binning is the step that makes any
	// of this work on an off-speed transfer: a side running 20 cents flat puts
	// every peak a fifth of a semitone low, and without the correction a good
	// share of them land in the wrong bin.
	//
	// Kept per frame as well as summed, because that is all the mode tracking
	// below needs - 12 floats a frame, against a second pass over the audio.
	//
	// A peak that is a harmonic of a stronger, lower peak in the same frame is
	// counted at that peak's pitch class rather than its own - see
	// key_harmonic_ratios for why and what it is worth.
	std::vector<float> frame_chroma(static_cast<std::size_t>(frames) * 12, 0.0f);
	double full[12] = { 0 };
	int pcs[key_peaks_per_frame];
	for (int f = 0; f < frames; f++)
	{
		const int c = peak_count[f];
		const float * fp = peak_freq.data() + static_cast<std::size_t>(f) * plan.max_peaks;
		const float * mp = peak_mag.data() + static_cast<std::size_t>(f) * plan.max_peaks;
		float * row = frame_chroma.data() + static_cast<std::size_t>(f) * 12;
		for (int i = 0; i < c; i++)
		{
			const double cents = 1200.0 * std::log(fp[i] / 440.0) * inv_log2;
			const long semis = std::lround((cents - out.tuning_cents) / 100.0);
			// A=440 is pitch class 9, so the grid is anchored there, not at C.
			pcs[i] = static_cast<int>(((semis + 9) % 12 + 12) % 12);
		}
		for (int j = 0; j < c; j++)
		{
			// The strongest lower peak this one is a harmonic of, if any.
			int owner = -1;
			for (int i = 0; i < c; i++)
			{
				if (i == j || fp[i] >= fp[j] || mp[i] < mp[j]) continue;
				if (owner >= 0 && mp[i] <= mp[owner]) continue;
				const double ratio = std::log(static_cast<double>(fp[j]) / fp[i]) * inv_log2;
				for (int k = 0; k < key_harmonic_ratio_count; k++)
				{
					if (std::fabs(ratio - key_harmonic_log2[k]) * 1200.0 < key_harmonic_tolerance_cents)
					{
						owner = i;
						break;
					}
				}
			}
			const int pc = owner >= 0 ? pcs[owner] : pcs[j];
			const float w = static_cast<float>(std::log1p(mp[j]));
			row[pc] += w;
			full[pc] += w;
		}
	}

	double sum = 0;
	for (int i = 0; i < 12; i++) sum += full[i];
	if (sum <= 0) return false;
	for (int i = 0; i < 12; i++) { full[i] /= sum; out.chroma[i] = full[i]; }

	// ---- key ----
	key_candidate all[24];
	for (int r = 0; r < 12; r++)
	{
		all[r].root = r;
		all[r].minor = false;
		all[r].score = correlate_profile(full, key_profile_major, r);
		all[12 + r].root = r;
		all[12 + r].minor = true;
		all[12 + r].score = correlate_profile(full, key_profile_minor, r);
	}
	std::stable_sort(all, all + 24, [](const key_candidate & a, const key_candidate & b)
	                 { return a.score > b.score; });
	for (int i = 0; i < key_candidate_count; i++) out.candidates[i] = all[i];
	out.candidate_count = key_candidate_count;
	out.margin = all[0].score - all[1].score;
	out.confidence = out.margin >= key_margin_high ? key_confidence_high
	               : (out.margin >= key_margin_medium ? key_confidence_medium
	                                                  : key_confidence_low);
	out.best = all[0];

	// ---- mode, by tracking rather than by the profile ----
	//
	// A tango that is minor in the A section and major in the B section does
	// not change key signature; it swaps which of the signature's two tonics is
	// in charge. So the signature is taken from the whole-track profile above
	// and the mode is decided here, by scoring each window against the two
	// relative triads and taking the majority. On the 60 labelled sides that
	// separates major from minor at r = +0.59 - 80% correct against a 52%
	// majority-guess baseline - and lifts exact keys from 57% to 60% and the
	// tonic alone from 71% to 74%.
	//
	// Both of those were measured before the background window became a pitch
	// width. Re-measured after it, the tracking is worth less but still worth
	// having: 67.2% to 69.0% exact, 77.6% to 79.3% on the tonic. A cleaner
	// chroma settles more of the mode by itself.
	//
	// Windows of the chroma already accumulated, rather than a second spectral
	// pass over the audio: the frames are the same frames, so this costs two
	// correlations per window and nothing else.
	const int maj_root = out.best.minor ? (out.best.root + 3) % 12 : out.best.root;
	const int min_root = (maj_root + 9) % 12;
	const std::size_t win = static_cast<std::size_t>(key_mode_window_seconds * sample_rate);
	const std::size_t mode_hop = static_cast<std::size_t>(key_mode_hop_seconds * sample_rate);
	if (count >= win && mode_hop > 0)
	{
		std::vector<bool> major;
		for (std::size_t s = 0; s + win <= count; s += mode_hop)
		{
			// Frames lying wholly inside the window, which is what slicing the
			// audio and re-analysing it would have used.
			const int f0 = static_cast<int>((s + hop - 1) / hop);
			const int f1 = std::min(frames,
				1 + static_cast<int>((s + win - nfft) / hop));
			if (f1 <= f0) continue;
			double c[12] = { 0 };
			int peaks = 0;
			for (int f = f0; f < f1; f++)
			{
				peaks += peak_count[f];
				const float * row = frame_chroma.data() + static_cast<std::size_t>(f) * 12;
				for (int i = 0; i < 12; i++) c[i] += row[i];
			}
			// A window this thin is a rubato introduction or a run-out groove.
			if (peaks < 20) continue;
			double cs = 0;
			for (int i = 0; i < 12; i++) cs += c[i];
			if (cs <= 0) continue;
			for (int i = 0; i < 12; i++) c[i] /= cs;
			major.push_back(correlate_profile(c, key_profile_major, maj_root) >
			                correlate_profile(c, key_profile_minor, min_root));
		}

		if (major.size() >= 4)
		{
			int n_major = 0, switches = 0;
			for (std::size_t i = 0; i < major.size(); i++)
			{
				if (major[i]) n_major++;
				if (i > 0 && major[i] != major[i - 1]) switches++;
			}
			out.mode_windows = static_cast<int>(major.size());
			out.mode_switches = switches;
			out.major_fraction = static_cast<double>(n_major) / major.size();
			// The natural half, and left there: the result is flat over
			// thresholds from 0.30 to 0.50, so there is nothing to tune, and a
			// threshold fitted on 60 tracks would be a threshold fitted on 60
			// tracks.
			const bool is_major = out.major_fraction > 0.5;
			out.best.root = is_major ? maj_root : min_root;
			out.best.minor = !is_major;
			out.best.score = is_major
				? correlate_profile(full, key_profile_major, maj_root)
				: correlate_profile(full, key_profile_minor, min_root);
		}
	}

	out.frames = frames;
	out.ok = true;
	return true;
}

}   // namespace bpmcore
