#include "internal.h"

#include <algorithm>
#include <cmath>

namespace bpmcore
{

namespace
{
	// Five seconds of lag covers two bars of the slowest vals and eight beats of
	// the fastest milonga.
	const double acf_max_lag_seconds = 5.0;

	const double buffer_max_seconds = 900.0;

	//! The analysis proper, on mono already at the rate it will be analysed at.
	analysis run_analysis(const float * mono, std::size_t count, unsigned sample_rate,
	                      listener * l, const options * opt)
	{
		analysis result;
		const int threads = opt != nullptr ? opt->threads : 0;

		odf o;
		if (!compute_odf(mono, count, sample_rate, o, l, threads)) return result;
		result.duration = o.duration;

		std::vector<float> novelty;
		mix_bands(o, novelty);
		make_novelty(novelty, o.frame_rate);

		std::vector<double> acf;
		std::vector<std::vector<double> > per_window;
		autocorrelate(novelty, acf,
		              static_cast<int>(std::lround(acf_max_lag_seconds * o.frame_rate)),
		              o.frame_rate, threads, &per_window);
		if (acf.empty()) return result;

		if (l != nullptr && l->cancelled()) return result;

		const grid g = find_grid(acf, o.frame_rate);
		if (g.beat_lag <= 0) return result;

		// The rhythm has to be settled before the tempo can be, because the
		// metrical level a dancer taps is different for each of them.
		std::vector<double> features;
		build_features(o, novelty, acf, g, features);
		result.rhythm = classify(features, &result.confidence);

		result.beat_bpm = lag_to_bpm(g.beat_lag, o.frame_rate);
		result.meter = g.meter;
		result.bpm = tapped_bpm(acf, g.beat_lag, result.rhythm, g.meter, o.frame_rate);
		result.ok = result.bpm > 0;

		// Measured against the beat period, then expressed at whatever level the
		// tempo is reported on: the ratio is dimensionless, so one figure serves
		// a tango tapped on the beat and a vals tapped once a bar alike.
		std::vector<double> ratios;
		const double rel = local_tempo_spread(per_window, g.beat_lag,
		                                      &result.spread_windows, &ratios);
		result.bpm_spread = rel * result.bpm;
		// Same windows, same level: the opening tempo rather than its spread.
		result.initial_bpm = initial_tempo_ratio(ratios) * result.bpm;

		if (l != nullptr) l->progress(1.0);
		return result;
	}
}

// Seven 12-second windows at a 3-second hop, so a track under about 30
// seconds reports no spread rather than one drawn from two or three windows.
const int spread_min_windows = 7;

double max_seconds() { return buffer_max_seconds; }

analysis analyse(const float * mono, std::size_t count, unsigned sample_rate,
                 listener * l, const options * opt)
{
	if (mono != nullptr && count != 0 && sample_rate != 0 && !rate_matches_model(sample_rate))
	{
		resampler rs(sample_rate, odf_model_rate);
		if (rs.valid())
		{
			// Converted in one call rather than in chunks with an abort poll
			// between them: even a quarter of an hour of audio is a fraction of
			// a second here, and `compute_odf` polls from then on. The component
			// does not come through this path at all - its collector converts as
			// the decoder produces audio, inside a loop that already aborts.
			std::vector<float> converted;
			rs.convert_all(mono, count, converted, opt != nullptr ? opt->threads : 0);
			return run_analysis(converted.data(), converted.size(),
			                    rs.rate_out(), l, opt);
		}
		// No usable ratio. The seconds-based geometry still gets the window and
		// hop right in time, so analysing at the input rate is a good deal
		// better than refusing the track.
	}
	return run_analysis(mono, count, sample_rate, l, opt);
}

collector::collector(unsigned sample_rate)
	: m_rate(sample_rate), m_analysis_rate(sample_rate), m_limit(0)
{
	if (sample_rate != 0 && !rate_matches_model(sample_rate))
	{
		std::unique_ptr<resampler> rs(new resampler(sample_rate, odf_model_rate));
		if (rs->valid())
		{
			m_analysis_rate = rs->rate_out();
			m_resampler = std::move(rs);
		}
	}

	m_limit = static_cast<std::size_t>(
		buffer_max_seconds * (m_analysis_rate ? m_analysis_rate : 1));
	// Three minutes covers almost every tango side; the buffer grows past this
	// only for the rare long track.
	m_mono.reserve(std::min<std::size_t>(m_limit, static_cast<std::size_t>(m_analysis_rate) * 240));
}

collector::~collector() {}

namespace
{
	template<typename sample_t>
	void downmix(std::vector<float> & out, const sample_t * data,
	             std::size_t frames, unsigned channels)
	{
		out.resize(frames);
		const double scale = 1.0 / channels;
		for (std::size_t i = 0; i < frames; i++)
		{
			double sum = 0;
			for (unsigned c = 0; c < channels; c++) sum += *data++;
			out[i] = static_cast<float>(sum * scale);
		}
	}

	template<typename sample_t>
	void widen(std::vector<float> & out, const sample_t * data, std::size_t count)
	{
		out.resize(count);
		for (std::size_t i = 0; i < count; i++) out[i] = static_cast<float>(data[i]);
	}
}

void collector::feed(const float * mono, std::size_t count)
{
	if (mono == nullptr || count == 0 || m_mono.size() >= m_limit) return;

	if (m_resampler == nullptr)
	{
		m_mono.insert(m_mono.end(), mono, mono + count);
		return;
	}

	// Truncating the output to the limit here instead would leave the
	// resampler's idea of how much it has emitted out of step with the buffer,
	// and `flush` trims against that count.
	m_resampler->process(mono, count, m_mono);
}

//! Frames worth taking. Only bounded where the input rate is the analysis rate
//! and the count carries straight across; with a resampler in the way the block
//! that crosses the limit is allowed to finish.
std::size_t collector::room(std::size_t frames) const
{
	if (m_mono.size() >= m_limit) return 0;
	if (m_resampler != nullptr) return frames;
	return std::min(frames, m_limit - m_mono.size());
}

void collector::add_mono(const float * data, std::size_t count)
{
	if (data == nullptr) return;
	feed(data, room(count));
}

void collector::add_mono(const double * data, std::size_t count)
{
	if (data == nullptr) return;
	count = room(count);
	if (count == 0) return;
	widen(m_scratch, data, count);
	feed(m_scratch.data(), m_scratch.size());
}

void collector::add_interleaved(const float * data, std::size_t frames, unsigned channels)
{
	if (data == nullptr || channels == 0) return;
	frames = room(frames);
	if (frames == 0) return;
	if (channels == 1) { feed(data, frames); return; }
	downmix(m_scratch, data, frames, channels);
	feed(m_scratch.data(), m_scratch.size());
}

void collector::add_interleaved(const double * data, std::size_t frames, unsigned channels)
{
	if (data == nullptr || channels == 0) return;
	frames = room(frames);
	if (frames == 0) return;
	downmix(m_scratch, data, frames, channels);
	feed(m_scratch.data(), m_scratch.size());
}

analysis collector::finish(listener * l, const options * opt)
{
	// The last output samples still have part of the resampler's filter hanging
	// past the end of the track. Not worth chasing for a tempo, but it keeps the
	// analysed duration equal to the decoded one.
	if (m_resampler != nullptr && m_mono.size() < m_limit) m_resampler->flush(m_mono);

	m_scratch.clear();
	m_scratch.shrink_to_fit();
	return run_analysis(m_mono.data(), m_mono.size(), m_analysis_rate, l, opt);
}

}   // namespace bpmcore
