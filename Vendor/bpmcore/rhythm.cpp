#include "internal.h"
#include "rhythm_model.h"

#include <algorithm>
#include <cmath>

namespace bpmcore
{

// Folding at 2, 3 and 4 beats regardless of the meter search means a mis-read
// meter can no longer corrupt the whole pattern - the classifier sees all three
// and decides for itself.
const int fixed_fold_mult[fixed_fold_count] = { 2, 3, 4 };
const int fixed_fold_bins[fixed_fold_count] = { 12, 12, 16 };

namespace
{
	//! Multiples of the beat period the autocorrelation is sampled at. The
	//! thirds expose a 3/4 bar, the halves and quarters the habanera
	//! subdivision, and the long ones the phrase structure.
	const double rel_lags[rel_lag_count] =
	{
		0.25, 1.0/3, 0.5, 2.0/3, 0.75, 1.0, 1.25, 4.0/3, 1.5, 5.0/3, 2.0, 7.0/3,
		2.5, 8.0/3, 3.0, 10.0/3, 3.5, 4.0, 4.5, 5.0, 6.0, 8.0, 9.0, 12.0
	};
}

void fold_pattern(const float * const * bands, int nb, int T,
                  double period, int bins, std::vector<float> & out)
{
	out.assign(static_cast<std::size_t>(nb) * bins, 0.0f);
	if (period < 4.0 || T < period * 3 || nb <= 0) return;

	std::vector<double> acc(static_cast<std::size_t>(nb) * bins, 0.0);
	std::vector<double> count(bins, 0.0);

	for (int t = 0; t < T; t++)
	{
		// Where in the period this frame falls, split across the two nearest
		// bins so the pattern does not shimmer as the period drifts.
		const double pos = std::fmod(static_cast<double>(t), period) / period * bins;
		int b0 = static_cast<int>(std::floor(pos));
		const double frac = pos - b0;
		b0 %= bins;
		if (b0 < 0) b0 += bins;
		const int b1 = (b0 + 1) % bins;

		count[b0] += 1.0 - frac;
		count[b1] += frac;
		for (int b = 0; b < nb; b++)
		{
			const double v = bands[b][t];
			acc[static_cast<std::size_t>(b) * bins + b0] += v * (1.0 - frac);
			acc[static_cast<std::size_t>(b) * bins + b1] += v * frac;
		}
	}

	for (int k = 0; k < bins; k++) if (count[k] < 1e-9) count[k] = 1e-9;
	for (int b = 0; b < nb; b++)
		for (int k = 0; k < bins; k++)
			acc[static_cast<std::size_t>(b) * bins + k] /= count[k];

	// Align on the strongest accent in the bottom two rows - the marcato - so
	// two recordings of the same rhythm line up whatever their downbeat offset.
	int shift = 0;
	if (nb >= 2)
	{
		double best = -1e18;
		for (int k = 0; k < bins; k++)
		{
			const double low = acc[k] + acc[static_cast<std::size_t>(bins) + k];
			if (low > best) { best = low; shift = k; }
		}
	}

	for (int b = 0; b < nb; b++)
	{
		double sum = 0;
		for (int k = 0; k < bins; k++) sum += acc[static_cast<std::size_t>(b) * bins + k];
		const double mean = sum / bins;
		for (int k = 0; k < bins; k++)
		{
			const double v = acc[static_cast<std::size_t>(b) * bins + (k + shift) % bins];
			// A deviation from the band's own average, so a loud band and a
			// quiet one contribute the same shape.
			out[static_cast<std::size_t>(b) * bins + k] =
				static_cast<float>(mean > 1e-9 ? v / mean - 1.0 : 0.0);
		}
	}
}

void build_features(const odf & o, const std::vector<float> & novelty,
                    const std::vector<double> & acf, const grid & g,
                    std::vector<double> & out)
{
	const int nb = odf::band_count;
	const int T = o.frames;
	out.clear();
	out.reserve(feature_count);

	const double lag = g.beat_lag;
	const double beat_bpm = lag > 0 ? lag_to_bpm(lag, o.frame_rate) : 1.0;

	out.push_back(std::log(std::max(beat_bpm, 1.0)));
	out.push_back(static_cast<double>(g.meter));
	out.push_back(g.score);
	out.push_back(g.beat_acf);

	for (int i = 0; i < rel_lag_count; i++)
		out.push_back(lag > 0 ? acf_at(acf, lag * rel_lags[i]) : 0.0);

	const double a2 = acf_at(acf, lag * 2);
	const double a3 = acf_at(acf, lag * 3);
	const double a4 = acf_at(acf, lag * 4);
	const double a6 = acf_at(acf, lag * 6);
	out.push_back(a3 - a4);
	out.push_back(a3 - a2);
	out.push_back(a6 - a4);

	// Per-band flux share and variability: a rough timbre descriptor, and the
	// main thing separating a 1935 shellac side from a modern cortina.
	double band_mean[odf::band_count] = { 0 };
	double band_sd[odf::band_count] = { 0 };
	for (int b = 0; b < nb; b++)
	{
		const float * src = o.band(b);
		double sum = 0;
		for (int t = 0; t < T; t++) sum += src[t];
		band_mean[b] = T ? sum / T : 0.0;
		double var = 0;
		for (int t = 0; t < T; t++) { const double d = src[t] - band_mean[b]; var += d * d; }
		band_sd[b] = T ? std::sqrt(var / T) : 0.0;
	}
	double total = 1e-12;
	for (int b = 0; b < nb; b++) total += band_mean[b];
	for (int b = 0; b < nb; b++) out.push_back(band_mean[b] / total);
	for (int b = 0; b < nb; b++) out.push_back(band_sd[b] / (band_mean[b] + 1e-9));

	double peak = 0;
	for (std::size_t i = 8; i < acf.size(); i++) peak = std::max(peak, acf[i]);
	out.push_back(peak);

	// Shape of the novelty curve: a sharply articulated marcato and a smooth
	// legato line have very different kurtosis at the same tempo.
	{
		const std::size_t n = novelty.size();
		double sum = 0;
		for (float v : novelty) sum += v;
		const double mean = n ? sum / n : 0.0;
		double m2 = 0, m3 = 0, m4 = 0;
		for (float v : novelty)
		{
			const double d = v - mean;
			const double d2 = d * d;
			m2 += d2; m3 += d2 * d; m4 += d2 * d2;
		}
		if (n) { m2 /= n; m3 /= n; m4 /= n; }
		const double sd = std::sqrt(m2);
		out.push_back(m4 / (m2 * m2 + 1e-12));
		out.push_back(m3 / (sd * sd * sd + 1e-12));
	}

	const float * all_bands[odf::band_count];
	for (int b = 0; b < nb; b++) all_bands[b] = o.band(b);

	std::vector<float> pattern;
	fold_pattern(all_bands, nb, T, lag * g.meter, bar_bins, pattern);
	out.insert(out.end(), pattern.begin(), pattern.end());
	fold_pattern(all_bands, nb, T, lag, beat_bins, pattern);
	out.insert(out.end(), pattern.begin(), pattern.end());

	// The same fold at fixed beat multiples, over low / mid / high groups.
	std::vector<float> grouped(static_cast<std::size_t>(fixed_group_count) * std::max(T, 0));
	const float * group_ptr[fixed_group_count];
	for (int gi = 0; gi < fixed_group_count; gi++)
	{
		float * dst = &grouped[static_cast<std::size_t>(gi) * T];
		const float * lo = o.band(2 * gi);
		const float * hi = o.band(2 * gi + 1);
		for (int t = 0; t < T; t++) dst[t] = lo[t] + hi[t];
		group_ptr[gi] = dst;
	}
	for (int f = 0; f < fixed_fold_count; f++)
	{
		fold_pattern(group_ptr, fixed_group_count, T,
		             lag * fixed_fold_mult[f], fixed_fold_bins[f], pattern);
		out.insert(out.end(), pattern.begin(), pattern.end());
	}
}

int classify(const std::vector<double> & features, double * confidence)
{
	// Adding a class is exactly the change that can leave the exported model and
	// the enum disagreeing, and the disagreement is a read off the end of the
	// baseline rather than anything that shows. Catch it at build time.
	static_assert(rhythm_model::class_count == rhythm_class_count,
	              "the exported model has a different number of classes than rhythm_class");
	static_assert(rhythm_model::feature_count == feature_count,
	              "the exported model was fitted on a different feature vector");
	// Child references are shorts. A refit large enough to overrun that would
	// otherwise read as a slightly wrong answer rather than as a failure.
	static_assert(rhythm_model::split_count <= 32767 && rhythm_model::leaf_count <= 32767,
	              "the exported model has outgrown the short its child references use");

	if (confidence) *confidence = 0.0;
	if (static_cast<int>(features.size()) != feature_count) return rhythm_other;

	double x[feature_count];
	for (int i = 0; i < feature_count; i++)
	{
		const double v = features[i];
		x[i] = (v == v && v > -1e300 && v < 1e300) ? v : 0.0;   // NaN and inf guard
	}

	// Gradient boosted decision trees: one additive score per class, then softmax.
	double score[rhythm_class_count];
	for (int c = 0; c < rhythm_class_count; c++) score[c] = rhythm_model::baseline[c];

	for (int t = 0; t < rhythm_model::tree_count; t++)
	{
		// Splits and leaves are held in separate arrays, because a split never
		// reads a value and a leaf never reads a threshold. A child reference
		// is a split index when it is >= 0 and the leaf -1 - c when it is
		// negative; tree_root carries the same encoding, so a tree that is a
		// bare leaf takes no steps here rather than a special case.
		int n = rhythm_model::tree_root[t];
		while (n >= 0)
			n = (x[rhythm_model::split_feature[n]] <= rhythm_model::split_threshold[n])
			    ? rhythm_model::split_left[n]
			    : rhythm_model::split_right[n];
		score[rhythm_model::tree_target[t]] += rhythm_model::leaf_value[-1 - n];
	}

	int best = 0;
	for (int c = 1; c < rhythm_class_count; c++) if (score[c] > score[best]) best = c;

	if (confidence)
	{
		double sum = 0;
		for (int c = 0; c < rhythm_class_count; c++) sum += std::exp(score[c] - score[best]);
		*confidence = sum > 0 ? 1.0 / sum : 0.0;
	}
	return best;
}

}   // namespace bpmcore
