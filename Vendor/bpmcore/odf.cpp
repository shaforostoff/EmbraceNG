#include "internal.h"
#include "parallel.h"
#include "real_fft.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <vector>

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
			  m_prev(plan.span, 0.0), m_cur(plan.span, 0.0) {}

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
				fft_scalar * frame = m_fft.input();
				for (int i = 0; i < p.nfft; i++)
					frame[i] = static_cast<fft_scalar>(src[i] * p.window[i]);
				m_fft.forward();

				// Two tight loops rather than one fused one. Computing the whole
				// span of logarithms first and differencing afterwards measured a
				// third faster than interleaving them: the transcendental loop
				// pipelines cleanly only when nothing else is storing alongside
				// it. log(1 + z) rather than log1p(z): z is never small enough
				// here for the difference to reach the sums, and log is faster.
				const fft_cpx * bins = m_fft.bins() + p.bin_lo;
				for (int k = 0; k < p.span; k++)
				{
					const double re = bins[k].r, im = bins[k].i;
					m_cur[k] = std::log(1.0 + p.scale * std::sqrt(re * re + im * im));
				}

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
							// onset, energy dying away does not.
							const double d = m_cur[k] - m_prev[k];
							if (d > 0) sum += d;
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
		std::vector<double> m_prev, m_cur;
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
