#include "internal.h"
#include "parallel.h"
#include "real_fft.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

// The same test resample.cpp makes: SSE2 is the x64 baseline and the 32-bit
// Windows build asks for it. Elsewhere the magnitude loop calls the C library.
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#define BPMCORE_ODF_SSE2
#endif

namespace bpmcore
{

const double odf_window_seconds = 1024.0 / 22050.0;
const double odf_hop_seconds    =  256.0 / 22050.0;
const double odf_gamma          = 100.0;

// Six bands from the bottom of the bandoneon to the top of what a 78 actually
// carries. Splitting here rather than at mel-spaced edges keeps the marcato
// (low), the melody instruments (mid) and the transient region (top) apart,
// which is what the rhythm classifier reads.
const double odf_band_edges_hz[odf::band_count + 1] =
	{ 60.0, 200.0, 400.0, 800.0, 1600.0, 3200.0, 8000.0 };

namespace
{
	//! Symmetric Hann window, matching numpy's hanning(), which is what the
	//! model was trained against.
	double hann(int i, int n)
	{
		return n > 1 ? 0.5 * (1.0 - std::cos(6.283185307179586 * i / (n - 1))) : 1.0;
	}

#if defined(BPMCORE_ODF_SSE2)
	//! Cephes' logf, four at a time. Neither MSVC nor the CRT will vectorise
	//! `logf`, and a call per bin was half the envelope's run time on x64 and
	//! more than that on x86, whose CRT logf is three times slower again.
	//!
	//! The mantissa is folded into [sqrt(1/2), sqrt(2)) by subtracting the bits
	//! of sqrt(1/2) as an integer - which carries into the exponent exactly when
	//! Cephes' compare would have decremented it - so there is no select. Valid
	//! for positive normal arguments; this loop only ever passes 1 or more.
	//!
	//! At most 0.82 ulp from the true logarithm against the CRT's 0.56, checked
	//! over every seventh float in [1, 2^24); the two differ by an ulp on about
	//! 2% of arguments. log_one() is the same arithmetic in the same order, so a
	//! bin's value does not depend on whether it fell in a vector or the tail.
	struct log_coefficients
	{
		static const float p[9];
		static const float ln2_lo, ln2_hi;
	};
	const float log_coefficients::p[9] = {
		 7.0376836292e-2f, -1.1514610310e-1f,  1.1676998740e-1f,
		-1.2420140846e-1f,  1.4249322787e-1f, -1.6668057665e-1f,
		 2.0000714765e-1f, -2.4999993993e-1f,  3.3333331174e-1f };
	const float log_coefficients::ln2_lo = -2.12194440e-4f;
	const float log_coefficients::ln2_hi = 0.693359375f;
	const std::int32_t log_sqrt_half_bits = 0x3f3504f3;

	inline __m128 log_four(__m128 x)
	{
		typedef log_coefficients c;
		const __m128i off = _mm_set1_epi32(log_sqrt_half_bits);
		__m128i ix = _mm_sub_epi32(_mm_castps_si128(x), off);
		const __m128 e = _mm_cvtepi32_ps(_mm_srai_epi32(ix, 23));
		ix = _mm_add_epi32(_mm_and_si128(ix, _mm_set1_epi32(0x007fffff)), off);
		const __m128 f = _mm_sub_ps(_mm_castsi128_ps(ix), _mm_set1_ps(1.0f));
		const __m128 z = _mm_mul_ps(f, f);
		__m128 y = _mm_set1_ps(c::p[0]);
		for (int i = 1; i < 9; i++)
			y = _mm_add_ps(_mm_mul_ps(y, f), _mm_set1_ps(c::p[i]));
		y = _mm_mul_ps(_mm_mul_ps(y, f), z);
		y = _mm_add_ps(y, _mm_mul_ps(e, _mm_set1_ps(c::ln2_lo)));
		y = _mm_add_ps(y, _mm_mul_ps(_mm_set1_ps(-0.5f), z));
		return _mm_add_ps(_mm_add_ps(f, y), _mm_mul_ps(e, _mm_set1_ps(c::ln2_hi)));
	}

	inline float log_one(float x)
	{
		typedef log_coefficients c;
		std::uint32_t ix;
		std::memcpy(&ix, &x, sizeof ix);
		ix -= static_cast<std::uint32_t>(log_sqrt_half_bits);
		const float e = static_cast<float>(static_cast<std::int32_t>(ix) >> 23);
		ix = (ix & 0x007fffffu) + static_cast<std::uint32_t>(log_sqrt_half_bits);
		float f;
		std::memcpy(&f, &ix, sizeof f);
		f -= 1.0f;
		const float z = f * f;
		float y = c::p[0];
		for (int i = 1; i < 9; i++)
			y = y * f + c::p[i];
		y = y * f * z;
		y += e * c::ln2_lo;
		y += -0.5f * z;
		return (f + y) + e * c::ln2_hi;
	}

	//! Real and imaginary parts of four bins, rounded to float if the
	//! transform ran wider - which is what the scalar loop does to each.
	inline void load_four(const float * p, __m128 & re, __m128 & im)
	{
		const __m128 a = _mm_loadu_ps(p), b = _mm_loadu_ps(p + 4);
		re = _mm_shuffle_ps(a, b, _MM_SHUFFLE(2, 0, 2, 0));
		im = _mm_shuffle_ps(a, b, _MM_SHUFFLE(3, 1, 3, 1));
	}

	inline void load_four(const double * p, __m128 & re, __m128 & im)
	{
		const __m128 a = _mm_movelh_ps(_mm_cvtpd_ps(_mm_loadu_pd(p)),
		                               _mm_cvtpd_ps(_mm_loadu_pd(p + 2)));
		const __m128 b = _mm_movelh_ps(_mm_cvtpd_ps(_mm_loadu_pd(p + 4)),
		                               _mm_cvtpd_ps(_mm_loadu_pd(p + 6)));
		re = _mm_shuffle_ps(a, b, _MM_SHUFFLE(2, 0, 2, 0));
		im = _mm_shuffle_ps(a, b, _MM_SHUFFLE(3, 1, 3, 1));
	}
#endif

	//! log(1 + scale * |bin|) over `n` bins.
	void compressed_magnitudes(const fft_cpx * bins, int n, float scale, float * out)
	{
		int k = 0;
#if defined(BPMCORE_ODF_SSE2)
		const __m128 one = _mm_set1_ps(1.0f), s = _mm_set1_ps(scale);
		for (; k + 4 <= n; k += 4)
		{
			__m128 re, im;
			load_four(&bins[k].r, re, im);
			const __m128 mag = _mm_sqrt_ps(_mm_add_ps(_mm_mul_ps(re, re), _mm_mul_ps(im, im)));
			_mm_storeu_ps(out + k, log_four(_mm_add_ps(one, _mm_mul_ps(s, mag))));
		}
		for (; k < n; k++)
		{
			const float re = static_cast<float>(bins[k].r);
			const float im = static_cast<float>(bins[k].i);
			out[k] = log_one(1.0f + scale * std::sqrt(re * re + im * im));
		}
#else
		for (; k < n; k++)
		{
			const float re = static_cast<float>(bins[k].r);
			const float im = static_cast<float>(bins[k].i);
			out[k] = std::log(1.0f + scale * std::sqrt(re * re + im * im));
		}
#endif
	}

	//! Everything the per-frame loop needs that does not change between frames.
	struct stft_plan
	{
		const float * mono = nullptr;
		int hop = 0;
		int nfft = 0;
		int bin_lo = 0;
		int span = 0;
		int band_lo[odf::band_count] = { 0 };
		int band_hi[odf::band_count] = { 0 };
		const double * window = nullptr;
		double scale = 0;
		int total_frames = 0;
		int frames = 0;
		float * out = nullptr;
	};

	//! Transforms frames and writes their flux rows.
	//!
	//! One of these is built per thread and reused for every block it takes, so
	//! the twiddle tables and scratch buffers are allocated once per analysis
	//! rather than once per block.
	class stft_worker
	{
	public:
		explicit stft_worker(const stft_plan & plan)
			: m_plan(plan), m_fft(plan.nfft),
			  m_prev(plan.span, 0.0f), m_cur(plan.span, 0.0f) {}

		bool valid() const { return m_fft.valid(); }

		//! Frames [begin, end). The frame before `begin` is re-derived here, so
		//! the result does not depend on how the work was divided - one thread
		//! and eight produce the same envelope, bit for bit.
		void run(int begin, int end)
		{
			const stft_plan & p = m_plan;
			const int first = std::max(0, begin - 1);
			for (int f = first; f < end; f++)
			{
				const float * src = p.mono + static_cast<std::size_t>(f) * p.hop;
				// Written straight into the transform's own buffer, which is
				// aligned however the backend needs it. The product is formed in
				// double whatever the transform's width: the window carries the
				// loudness normalisation, and rounding it to the input's width
				// before multiplying would quantise that.
				m_fft.window_from(src, p.window);
				m_fft.forward();

				// Two tight loops rather than one fused one. Computing the whole
				// span of logarithms first and differencing afterwards measured a
				// third faster than interleaving them: the transcendental loop
				// pipelines cleanly only when nothing else is storing alongside
				// it. log(1 + z) rather than log1p(z): z is never small enough
				// here for the difference to reach the sums, and log is faster.
				//
				// The magnitude and its logarithm are formed at single
				// precision whatever width the transform ran at - `logf` and
				// `sqrtf` are about a third cheaper than their double
				// counterparts and this loop is the largest single cost in the
				// analysis. Stored as float and widened for the difference
				// below, which is then exact; on x86 the logarithm is
				// compressed_magnitudes' own, four bins at a time.
				//
				// Not bit-exact, so it was measured rather than argued: over
				// the whole 12,163-track collection not one changed rhythm,
				// meter or metrical level, and the largest tempo difference
				// anywhere was 0.0005 BPM. docs/tango-analysis.md carries the
				// run and the yardstick it is small against.
				compressed_magnitudes(m_fft.bins() + p.bin_lo, p.span,
				                      static_cast<float>(p.scale), m_cur.data());

				// `first` is only the predecessor of this block's first output
				// frame. Frame 0 lands here too, and rightly produces no row.
				if (f != first)
				{
					const int index = f - 1;
					for (int b = 0; b < odf::band_count; b++)
					{
						double sum = 0;
						for (int k = p.band_lo[b] - p.bin_lo; k < p.band_hi[b] - p.bin_lo; k++)
						{
							// Half-wave rectified: energy appearing counts as an
							// onset, energy dying away does not. Written as a
							// select rather than a branch - the sign is not
							// predictable, and adding a zero changes no sum -
							// which measured six times faster over this loop.
							const double d = static_cast<double>(m_cur[k]) - m_prev[k];
							sum += d > 0 ? d : 0.0;
						}
						p.out[static_cast<std::size_t>(b) * p.frames + index] =
							static_cast<float>(sum);
					}
				}

				m_prev.swap(m_cur);
			}
		}

	private:
		const stft_plan & m_plan;
		real_fft m_fft;
		std::vector<float> m_prev, m_cur;
	};

	//! Frames below this are not worth a thread hand-off.
	const int min_frames_per_thread = 512;
}

bool compute_odf(const float * mono, std::size_t count, unsigned sample_rate,
                 odf & out, listener * l, int threads)
{
	out = odf();
	if (mono == nullptr || count == 0 || sample_rate == 0) return false;

	const int hop = std::max(1, static_cast<int>(std::lround(odf_hop_seconds * sample_rate)));
	const int nfft = fft_size_for(
		static_cast<int>(std::lround(odf_window_seconds * sample_rate)));
	const int nbin = nfft / 2 + 1;

	if (count < static_cast<std::size_t>(nfft) + static_cast<std::size_t>(hop) * 8) return false;

	const int total_frames = 1 + static_cast<int>((count - nfft) / hop);
	if (total_frames < 9) return false;

	out.frames = total_frames - 1;   // one difference per adjacent pair of frames
	out.frame_rate = static_cast<double>(sample_rate) / hop;
	out.duration = static_cast<double>(count) / sample_rate;

	stft_plan plan;
	plan.mono = mono;
	plan.hop = hop;
	plan.nfft = nfft;
	plan.total_frames = total_frames;
	plan.frames = out.frames;

	// Bin ranges per band. Only the span they cover is ever read, so the
	// spectrum outside it is never turned into a magnitude - on a 44.1kHz file
	// that leaves 370 bins of the 1025 the transform produces, and the
	// logarithm is the most expensive thing in the loop.
	for (int b = 0; b < odf::band_count; b++)
	{
		plan.band_lo[b] = static_cast<int>(std::ceil(odf_band_edges_hz[b] * nfft / sample_rate));
		plan.band_hi[b] = static_cast<int>(std::ceil(odf_band_edges_hz[b + 1] * nfft / sample_rate));
		plan.band_lo[b] = std::min(std::max(plan.band_lo[b], 0), nbin);
		plan.band_hi[b] = std::min(std::max(plan.band_hi[b], plan.band_lo[b]), nbin);
	}
	plan.bin_lo = plan.band_lo[0];
	const int bin_hi = plan.band_hi[odf::band_count - 1];
	if (bin_hi <= plan.bin_lo) return false;
	plan.span = bin_hi - plan.bin_lo;

	// Loudness normalisation. The compression is not scale invariant, so two
	// transfers of the same side at different levels would otherwise give
	// different envelopes. Folding the scale into the window avoids a second
	// pass over the audio.
	double total = 0;
	for (std::size_t i = 0; i < count; i++) total += static_cast<double>(mono[i]) * mono[i];
	const double rms = std::sqrt(total / count);
	const double inv_rms = rms > 1e-12 ? 1.0 / rms : 1.0;

	std::vector<double> window(nfft);
	for (int i = 0; i < nfft; i++) window[i] = hann(i, nfft) * inv_rms;
	plan.window = window.data();
	plan.scale = odf_gamma / nfft;

	out.data.assign(static_cast<std::size_t>(odf::band_count) * out.frames, 0.0f);
	plan.out = out.data.data();

	const int n_threads = resolve_threads(threads, total_frames, min_frames_per_thread);
	if (n_threads <= 1)
	{
		stft_worker worker(plan);
		if (!worker.valid()) return false;
		// One pass, in slices, so a host still gets progress and can cancel.
		const int slice = std::max(256, total_frames / 32);
		for (int begin = 0; begin < total_frames; begin += slice)
		{
			if (l != nullptr)
			{
				if (l->cancelled()) return false;
				l->progress(static_cast<double>(begin) / total_frames);
			}
			worker.run(begin, std::min(begin + slice, total_frames));
		}
		return true;
	}

	// Blocks are handed out from a shared counter rather than split evenly, so
	// a core that is busy with something else does not hold up the rest.
	const int block = std::max(256, total_frames / (n_threads * 8));
	const int n_blocks = (total_frames + block - 1) / block;
	std::atomic<int> next(0);
	std::atomic<bool> stop(false);

	auto take_blocks = [&](stft_worker & w)
	{
		for (;;)
		{
			const int i = next.fetch_add(1);
			if (i >= n_blocks || stop.load()) return;
			w.run(i * block, std::min((i + 1) * block, total_frames));
		}
	};

	std::vector<std::thread> pool;
	pool.reserve(n_threads - 1);
	for (int t = 0; t < n_threads - 1; t++)
	{
		pool.emplace_back([&plan, &take_blocks]()
		{
			stft_worker w(plan);
			if (w.valid()) take_blocks(w);
		});
	}

	// The calling thread takes blocks too, and is the only one that touches the
	// listener - a host's abort and progress hooks need not be thread safe.
	stft_worker mine(plan);
	if (mine.valid())
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
			mine.run(i * block, std::min((i + 1) * block, total_frames));
		}
	}

	for (std::thread & t : pool) t.join();
	return !stop.load();
}

}   // namespace bpmcore
