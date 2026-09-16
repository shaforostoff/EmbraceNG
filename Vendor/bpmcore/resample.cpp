#include "internal.h"
#include "parallel.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace bpmcore
{

// 22050Hz is not an arbitrary choice. scripts/analysis/odf.py decodes every
// training track to it, so it is the rate the rhythm model was fitted at and the
// rate every accuracy figure in docs/tango-analysis.md was measured at.
const unsigned odf_model_rate = 22050;

bool rate_matches_model(unsigned rate)
{
	// The window and hop are 1024 and 256 samples at the model rate. They land
	// on whole samples, and the transform keeps the model's 21.53Hz per bin,
	// exactly when the rate is the model rate times a power of two - so 11.025,
	// 44.1 and 88.2kHz all reproduce the model's analysis, and 48kHz does not.
	if (rate == 0) return false;
	unsigned hi = std::max(rate, odf_model_rate);
	const unsigned lo = std::min(rate, odf_model_rate);
	while (hi > lo && (hi & 1u) == 0) hi >>= 1;
	return hi == lo;
}

namespace
{
	const double pi     = 3.14159265358979323846;
	const double two_pi = 6.28318530717958647693;

	//! Alias rejection the anti-alias filter is designed for.
	//!
	//! Well beyond what the envelope can notice: the flux is summed from
	//! log(1 + 100m) magnitudes, and 80dB below the signal is two orders of
	//! magnitude under the surface noise of any shellac transfer.
	const double stopband_db = 80.0;

	//! Filter phases allowed. A rate that is nearly coprime with the target -
	//! 44056Hz off an NTSC video transfer, say - would otherwise ask for one
	//! phase per interpolation step; the ratio is approximated instead.
	const int max_phases = 1024;
	const int min_taps_per_phase = 8;
	//! Enough for 80dB at 192kHz, which is the highest rate worth resampling
	//! from. Nothing realistic reaches the clamp.
	const int max_taps_per_phase = 160;

	//! Output blocks per thread. Enough that a core held up elsewhere does not
	//! leave the rest waiting on it, few enough that the hand-off is noise.
	const int blocks_per_thread = 8;
	const int min_outputs_per_thread = 8192;

	//! `taps` products, in four independent sums.
	//!
	//! MSVC will not reassociate float addition, so a single running total stays
	//! scalar. Four accumulators let it use the whole vector unit, and are still
	//! deterministic - which matters, because the answer must not depend on how
	//! the work was divided.
	float dot(const float * coeff, const float * x, int taps)
	{
		float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f, a3 = 0.0f;
		int k = 0;
		for (; k + 4 <= taps; k += 4)
		{
			a0 += coeff[k]     * x[k];
			a1 += coeff[k + 1] * x[k + 1];
			a2 += coeff[k + 2] * x[k + 2];
			a3 += coeff[k + 3] * x[k + 3];
		}
		float acc = (a0 + a1) + (a2 + a3);
		for (; k < taps; k++) acc += coeff[k] * x[k];
		return acc;
	}

	//! Modified Bessel function of the first kind, order zero.
	//!
	//! The argument here never exceeds the Kaiser beta, about 8, where the
	//! series has converged past double precision well inside the loop.
	double bessel_i0(double x)
	{
		double sum = 1.0, term = 1.0;
		const double quarter_sq = 0.25 * x * x;
		for (int k = 1; k < 64; k++)
		{
			term *= quarter_sq / (static_cast<double>(k) * k);
			sum += term;
			if (term <= 1e-18 * sum) break;
		}
		return sum;
	}

	//! Closest rational to `num`/`den` whose numerator is at most `cap`.
	//!
	//! The convergents of the continued fraction are the best approximations
	//! there are for their size, so walking them and stopping at the cap gives
	//! the least rate error available within the phase budget.
	void approximate_ratio(std::uint64_t num, std::uint64_t den, std::uint64_t cap,
	                       std::int64_t & p_out, std::int64_t & q_out)
	{
		std::uint64_t p_prev = 0, q_prev = 1, p = 1, q = 0;
		std::uint64_t a = num, b = den;
		while (b != 0)
		{
			const std::uint64_t whole = a / b;
			const std::uint64_t p_next = whole * p + p_prev;
			const std::uint64_t q_next = whole * q + q_prev;
			if (p_next > cap || q_next > cap) break;
			p_prev = p; q_prev = q;
			p = p_next; q = q_next;
			const std::uint64_t rem = a - whole * b;
			a = b; b = rem;
		}
		p_out = static_cast<std::int64_t>(p);
		q_out = static_cast<std::int64_t>(q);
	}
}

resampler::resampler(unsigned from, unsigned to)
{
	if (from == 0 || to == 0 || from == to) return;

	unsigned a = to, b = from;
	while (b != 0) { const unsigned t = a % b; a = b; b = t; }
	std::int64_t phases = to / a, decim = from / a;
	if (phases > max_phases || decim > max_phases)
		approximate_ratio(to, from, max_phases, phases, decim);
	if (phases <= 0 || decim <= 0) return;

	// What the filter has to do, in Hz. The passband has to carry everything the
	// analysis reads, which stops at the top band edge; the stopband has to start
	// where the first alias of that passband would fold back into it.
	//
	// That gap is what makes this cheap. Resampling 48kHz audio for playback
	// needs a filter clean from 20kHz up; this one only has to be clean from
	// 14kHz up, because an alias landing between 8 and 14kHz is in bins the
	// envelope never reads. Six kilohertz of transition band instead of one is
	// the difference between a filter that costs more than the transform it
	// feeds and one that costs a twentieth of it.
	const double lower_rate = static_cast<double>(std::min(from, to));
	const double passband = std::min(odf_band_edges_hz[odf::band_count], 0.45 * lower_rate);
	const double transition = lower_rate - 2.0 * passband;

	// Kaiser's order estimate, divided by the phase count: taps per phase comes
	// out independent of the ratio, and so does the work per output sample.
	int taps = static_cast<int>(std::ceil((stopband_db - 8.0) * from /
	                                      (2.285 * two_pi * transition)));
	taps = std::min(std::max(taps, min_taps_per_phase), max_taps_per_phase);

	const std::int64_t total = static_cast<std::int64_t>(taps) * phases;
	if (total < 2) return;

	m_phases = static_cast<int>(phases);
	m_decim = static_cast<int>(decim);
	m_taps = taps;
	// The prototype is symmetric about its midpoint, so it delays by half its
	// length. Outputs are read that much further along to put them back in time
	// with the input.
	m_delay = (total - 1) / 2;
	m_rate_out = to;

	const double cutoff = 0.5 * lower_rate / (static_cast<double>(phases) * from);
	const double beta = 0.1102 * (stopband_db - 8.7);
	const double norm = bessel_i0(beta);
	const double centre = 0.5 * static_cast<double>(total - 1);

	m_coeff.assign(static_cast<std::size_t>(total), 0.0f);
	for (std::int64_t i = 0; i < total; i++)
	{
		const double t = static_cast<double>(i) - centre;
		const double sinc = t == 0.0 ? 2.0 * cutoff
		                             : std::sin(two_pi * cutoff * t) / (pi * t);
		const double u = 2.0 * static_cast<double>(i) / static_cast<double>(total - 1) - 1.0;
		const double window = bessel_i0(beta * std::sqrt(std::max(0.0, 1.0 - u * u))) / norm;

		// Phase-major and time-reversed, so producing one output sample is a
		// contiguous forward dot product over `taps` coefficients and `taps`
		// input samples.
		const int phase = static_cast<int>(i % phases);
		const int tap = m_taps - 1 - static_cast<int>(i / phases);
		m_coeff[static_cast<std::size_t>(phase) * m_taps + tap] =
			static_cast<float>(sinc * window * static_cast<double>(phases));
	}

	// Silence before the track, which is what every resampler assumes and what
	// the one-shot and streaming paths have to agree on.
	m_hist.assign(static_cast<std::size_t>(m_taps - 1), 0.0f);
}

std::size_t resampler::expected_output(std::size_t in) const
{
	if (!valid() || in == 0) return 0;
	const std::uint64_t n = (static_cast<std::uint64_t>(in) * m_phases + m_decim - 1) / m_decim;
	return static_cast<std::size_t>(n);
}

void resampler::process(const float * in, std::size_t count, std::vector<float> & out)
{
	if (!valid() || in == nullptr || count == 0) return;

	const std::size_t history = static_cast<std::size_t>(m_taps - 1);
	m_work.resize(history + count);
	std::copy(m_hist.begin(), m_hist.end(), m_work.begin());
	std::copy(in, in + count, m_work.begin() + history);

	// m_work[0] is this many input samples into the track. Negative for the
	// first block, where the history is the assumed silence before it.
	const std::int64_t origin = m_consumed - static_cast<std::int64_t>(history);
	m_consumed += static_cast<std::int64_t>(count);

	// Every output whose newest input sample has now arrived.
	const std::int64_t reach = m_consumed * m_phases;
	const std::int64_t end = reach > m_delay ? (reach - m_delay + m_decim - 1) / m_decim : 0;
	if (end <= m_produced)
	{
		m_hist.assign(m_work.end() - history, m_work.end());
		return;
	}

	const std::size_t first = out.size();
	out.resize(first + static_cast<std::size_t>(end - m_produced));
	float * dst = out.data() + first;

	const int taps = m_taps;
	for (std::int64_t n = m_produced; n < end; n++)
	{
		const std::int64_t at = n * m_decim + m_delay;
		// The oldest input sample this output reads. Guaranteed inside m_work:
		// `end` is exactly the point at which it stops being.
		*dst++ = dot(m_coeff.data() + static_cast<std::size_t>(at % m_phases) * taps,
		             m_work.data() + (at / m_phases - (taps - 1) - origin), taps);
	}
	m_produced = end;

	m_hist.assign(m_work.end() - history, m_work.end());
}

void resampler::flush(std::vector<float> & out)
{
	if (!valid()) return;

	// The output has to cover the same duration as the input, and the last few
	// output samples still have part of the filter hanging past the end of the
	// track. Silence is fed until they can be formed.
	const std::int64_t want =
		static_cast<std::int64_t>(expected_output(static_cast<std::size_t>(m_consumed)));
	const std::vector<float> silence(static_cast<std::size_t>(m_taps), 0.0f);
	while (m_produced < want)
	{
		const std::int64_t before = m_produced;
		process(silence.data(), silence.size(), out);
		if (m_produced == before) break;
	}

	// Whatever ran past the end is the filter's tail beyond the track.
	if (m_produced > want)
	{
		out.resize(out.size() - static_cast<std::size_t>(m_produced - want));
		m_produced = want;
	}
}

float resampler::tap_edges(std::int64_t at, const float * in, std::size_t count) const
{
	const std::int64_t first = at / m_phases - (m_taps - 1);

	// Gathered into a zero-padded window and then put through the same dot
	// product as the interior, rather than summed here with the missing samples
	// skipped. Skipping them would sum in a different order, and the two paths
	// have to agree to the last bit - the streaming path reads those same zeros
	// out of its history buffer and its `flush` feed.
	std::vector<float> window(static_cast<std::size_t>(m_taps), 0.0f);
	for (int k = 0; k < m_taps; k++)
	{
		const std::int64_t i = first + k;
		if (i >= 0 && i < static_cast<std::int64_t>(count))
			window[static_cast<std::size_t>(k)] = in[static_cast<std::size_t>(i)];
	}
	return dot(m_coeff.data() + static_cast<std::size_t>(at % m_phases) * m_taps,
	           window.data(), m_taps);
}

void resampler::convert_all(const float * in, std::size_t count,
                            std::vector<float> & out, int threads)
{
	if (!valid() || in == nullptr || count == 0) return;

	const std::int64_t total = static_cast<std::int64_t>(expected_output(count));
	if (total <= 0) return;
	const std::size_t base = out.size();
	out.resize(base + static_cast<std::size_t>(total));
	float * dst = out.data() + base;

	// Where the filter sits wholly inside the input and no output has to look
	// past either end. Output n reads input samples at/L - taps + 1 through
	// at/L, with at = n*M + delay, so the first needs at >= (taps-1)*L and the
	// last needs at <= count*L - 1.
	const std::int64_t span = static_cast<std::int64_t>(m_taps - 1) * m_phases;
	const std::int64_t lo = span > m_delay
		? std::min(total, (span - m_delay + m_decim - 1) / m_decim) : 0;
	const std::int64_t last = static_cast<std::int64_t>(count) * m_phases - 1 - m_delay;
	const std::int64_t hi = last >= 0
		? std::max(lo, std::min(total, last / m_decim + 1)) : lo;

	for (std::int64_t n = 0; n < lo; n++)
		dst[n] = tap_edges(n * m_decim + m_delay, in, count);
	for (std::int64_t n = hi; n < total; n++)
		dst[n] = tap_edges(n * m_decim + m_delay, in, count);

	const int taps = m_taps;
	const int n_threads = resolve_threads(threads, static_cast<int>(hi - lo),
	                                      min_outputs_per_thread);
	const std::int64_t per_block =
		std::max<std::int64_t>(1, (hi - lo + n_threads * blocks_per_thread - 1) /
		                          (n_threads * blocks_per_thread));
	const int blocks = static_cast<int>((hi - lo + per_block - 1) / per_block);

	parallel_blocks(blocks, n_threads, [&](int b)
	{
		const std::int64_t begin = lo + static_cast<std::int64_t>(b) * per_block;
		const std::int64_t stop = std::min(hi, begin + per_block);
		for (std::int64_t n = begin; n < stop; n++)
		{
			const std::int64_t at = n * m_decim + m_delay;
			dst[n] = dot(m_coeff.data() + static_cast<std::size_t>(at % m_phases) * taps,
			             in + (at / m_phases - (taps - 1)), taps);
		}
	});

	// A one-shot conversion is the whole track, so the streaming state is left
	// consistent with having been fed and flushed.
	m_consumed = static_cast<std::int64_t>(count);
	m_produced = total;
}

}   // namespace bpmcore
