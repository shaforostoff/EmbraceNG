#include "internal.h"

// The fingerprint features: the key stage's chroma and the tempo stage's
// novelty, frame by frame. See `features` in bpmcore.h.

namespace bpmcore
{

namespace
{
	features run_features(const float * mono, std::size_t count, unsigned sample_rate,
	                      listener * l, int threads)
	{
		features out;
		progress_range key_progress(l, 0.0, 0.5);
		progress_range odf_progress(l, 0.5, 1.0);

		key_analysis key;
		key_frames frames;
		if (!compute_key(mono, count, sample_rate, key, l != nullptr ? &key_progress : nullptr, threads, &frames) ||
		    frames.frames <= 0)
			return out;
		if (l != nullptr && l->cancelled()) return out;

		odf o;
		if (!compute_odf(mono, count, sample_rate, o, l != nullptr ? &odf_progress : nullptr, threads)) return out;
		mix_bands(o, out.novelty);
		make_novelty(out.novelty, o.frame_rate);

		out.duration = static_cast<double>(count) / sample_rate;
		out.tuning_cents = key.tuning_cents;
		out.tuning_r = key.tuning_r;
		out.chroma_hop = frames.hop_seconds;
		out.chroma.swap(frames.chroma);
		out.loudness.swap(frames.rms);
		out.silence = frames.gate;
		out.novelty_rate = o.frame_rate;
		out.ok = true;
		return out;
	}
}

features extract_features(const float * mono, std::size_t count, unsigned sample_rate,
                          listener * l, int threads)
{
	// At the model rate, as analyse() does, so a track's features do not
	// depend on the rate it happens to be stored at.
	if (mono != nullptr && count != 0 && sample_rate != 0 && !rate_matches_model(sample_rate))
	{
		resampler rs(sample_rate, odf_model_rate);
		if (rs.valid())
		{
			std::vector<float> converted;
			rs.convert_all(mono, count, converted, threads);
			return run_features(converted.data(), converted.size(), rs.rate_out(), l, threads);
		}
	}
	if (mono == nullptr || count == 0 || sample_rate == 0) return features();
	return run_features(mono, count, sample_rate, l, threads);
}

features collector::finish_features(listener * l, int threads)
{
	if (m_resampler != nullptr && m_mono.size() < m_limit) m_resampler->flush(m_mono);
	m_scratch.clear();
	m_scratch.shrink_to_fit();
	if (m_mono.empty() || m_analysis_rate == 0) return features();
	return run_features(m_mono.data(), m_mono.size(), m_analysis_rate, l, threads);
}

}   // namespace bpmcore
