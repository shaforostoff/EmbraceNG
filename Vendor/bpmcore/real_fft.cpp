#include "real_fft.h"

#include <cstdlib>
#include <cstring>
#include <initializer_list>

// The same test odf.cpp and resample.cpp make: SSE2 is the x64 baseline and
// the 32-bit Windows build asks for it.
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#define BPMCORE_WINDOW_SSE2
#endif

#if defined(BPMCORE_FFT_PFFFT)
#include <pffft/pffft.h>
#else
#include <kiss_fft/kiss_fftr.h>
#endif

namespace bpmcore
{

namespace
{
	//! Nearest even integer to `n` with no prime factor above 5.
	bool five_smooth_even(int n)
	{
		if (n < 2 || n % 2 != 0) return false;
		for (int f : { 2, 3, 5 }) while (n % f == 0) n /= f;
		return n == 1;
	}

#if defined(BPMCORE_WINDOW_SSE2)
	//! Four products, rounded to float.
	inline void window_four(const float * src, const double * w, float * out)
	{
		const __m128 x = _mm_loadu_ps(src);
		const __m128d lo = _mm_mul_pd(_mm_cvtps_pd(x), _mm_loadu_pd(w));
		const __m128d hi = _mm_mul_pd(_mm_cvtps_pd(_mm_movehl_ps(x, x)), _mm_loadu_pd(w + 2));
		_mm_storeu_ps(out, _mm_movelh_ps(_mm_cvtpd_ps(lo), _mm_cvtpd_ps(hi)));
	}

	//! Four products, left at double.
	inline void window_four(const float * src, const double * w, double * out)
	{
		const __m128 x = _mm_loadu_ps(src);
		_mm_storeu_pd(out, _mm_mul_pd(_mm_cvtps_pd(x), _mm_loadu_pd(w)));
		_mm_storeu_pd(out + 2, _mm_mul_pd(_mm_cvtps_pd(_mm_movehl_ps(x, x)),
		                                  _mm_loadu_pd(w + 2)));
	}
#endif
}

void real_fft::window_from(const float * src, const double * window)
{
	fft_scalar * const out = m_in;
	const int n = m_nfft;
	int i = 0;
#if defined(BPMCORE_WINDOW_SSE2)
	// Bounded by a count worked out once, rather than by i + 4 <= n: written
	// that way the 32-bit build kept a second counter for i + 4 and, out of
	// registers, kept it on the stack, so every step waited on a store to
	// forward from the step before.
	const int whole = n & ~3;
	for (; i < whole; i += 4) window_four(src + i, window + i, out + i);
#endif
	for (; i < n; i++) out[i] = static_cast<fft_scalar>(src[i] * window[i]);
}

int fft_size_for(int ideal)
{
	// 32 is the floor under both backends, and below it there is no window
	// worth transforming anyway.
	if (ideal < 32) return 32;
	for (int d = 0; d <= ideal; d++)
	{
		if (ideal - d >= 32 && fft_size_supported(ideal - d)) return ideal - d;
		if (fft_size_supported(ideal + d)) return ideal + d;
	}
	return 1024;   // unreachable: every power of two from 32 up is supported
}

#if defined(BPMCORE_FFT_PFFFT)

// pffft is single precision and says so in its own header; if the build has
// asked for double somewhere, that has to stop here rather than quietly
// truncate every sample on the way into the transform.
static_assert(sizeof(fft_scalar) == sizeof(float),
              "pffft is single precision; build it with BPMCORE_FFT_SCALAR=float");

bool fft_size_supported(int n)
{
	// N = (2^a)(3^b)(5^c) with a >= 5, which is pffft's documented restriction:
	// 5-smooth and a multiple of 32. Below 32 there is nothing it can do at all.
	return n >= 32 && n % 32 == 0 && five_smooth_even(n);
}

real_fft::real_fft(int nfft) : m_nfft(nfft)
{
	if (!fft_size_supported(nfft)) return;

	PFFFT_Setup * setup = pffft_new_setup(nfft, PFFFT_REAL);
	if (setup == nullptr) return;
	m_state = setup;

	// Every buffer pffft touches has to be 16-byte aligned, which is what its
	// own allocator is for - std::vector gives no such promise, least of all in
	// the 32 bit build.
	//
	// The bin buffer is two floats longer than pffft writes. pffft packs the
	// two real-valued bins, DC and Nyquist, together into its first complex
	// slot; `forward` unpacks them into the extra room, so that the analysis
	// sees the same nfft/2+1 bins it would have got from kiss.
	m_in = static_cast<fft_scalar *>(pffft_aligned_malloc(sizeof(float) * nfft));
	m_bins = static_cast<fft_cpx *>(pffft_aligned_malloc(sizeof(float) * (nfft + 2)));
	m_work = pffft_aligned_malloc(sizeof(float) * nfft);
	if (m_in == nullptr || m_bins == nullptr || m_work == nullptr) return;

	m_ok = true;
}

real_fft::~real_fft()
{
	if (m_state != nullptr) pffft_destroy_setup(static_cast<PFFFT_Setup *>(m_state));
	pffft_aligned_free(m_in);
	pffft_aligned_free(m_bins);
	pffft_aligned_free(m_work);
}

void real_fft::forward()
{
	float * out = reinterpret_cast<float *>(m_bins);
	// Ordered, not raw. The raw layout is about a tenth faster but permuted,
	// and the analysis reads a contiguous range of bins - band edges are bin
	// numbers, so a permuted spectrum is unusable without reordering it anyway.
	pffft_transform_ordered(static_cast<const PFFFT_Setup *>(m_state),
	                        reinterpret_cast<const float *>(m_in), out,
	                        static_cast<float *>(m_work), PFFFT_FORWARD);

	// out[0] and out[1] hold F(0) and F(nfft/2), both real. Bins 1 to
	// nfft/2 - 1 are already where they belong, so only the two ends move.
	const float nyquist = out[1];
	out[1] = 0.0f;                  // imaginary part of DC
	out[m_nfft] = nyquist;
	out[m_nfft + 1] = 0.0f;         // imaginary part of Nyquist
}

#else   // kiss

// fft_cpx has to be laid out exactly as kiss's own complex type, because the
// bins are written by kiss and read as ours with no conversion in between.
static_assert(sizeof(fft_cpx) == sizeof(kiss_fft_cpx),
              "fft_cpx and kiss_fft_cpx disagree: BPMCORE_FFT_SCALAR_TYPE and "
              "kiss_fft_scalar were built at different widths");
static_assert(sizeof(fft_scalar) == sizeof(kiss_fft_scalar),
              "fft_scalar and kiss_fft_scalar disagree in width");

bool fft_size_supported(int n)
{
	// kiss_fftr needs an even size, and only has butterflies for 2, 3 and 5 -
	// anything else falls to a generic stage quadratic in the factor, which is
	// slow enough to be worth avoiding even though it would work.
	return five_smooth_even(n);
}

real_fft::real_fft(int nfft) : m_nfft(nfft)
{
	if (!fft_size_supported(nfft)) return;

	m_state = kiss_fftr_alloc(nfft, 0, nullptr, nullptr);
	if (m_state == nullptr) return;

	m_in = static_cast<fft_scalar *>(std::malloc(sizeof(fft_scalar) * nfft));
	m_bins = static_cast<fft_cpx *>(std::malloc(sizeof(fft_cpx) * (nfft / 2 + 1)));
	if (m_in == nullptr || m_bins == nullptr) return;

	m_ok = true;
}

real_fft::~real_fft()
{
	if (m_state != nullptr) kiss_fftr_free(static_cast<kiss_fftr_cfg>(m_state));
	std::free(m_in);
	std::free(m_bins);
}

void real_fft::forward()
{
	kiss_fftr(static_cast<kiss_fftr_cfg>(m_state),
	          reinterpret_cast<const kiss_fft_scalar *>(m_in),
	          reinterpret_cast<kiss_fft_cpx *>(m_bins));
}

#endif

}   // namespace bpmcore
