#ifndef BPMCORE_REAL_FFT_H
#define BPMCORE_REAL_FFT_H

// The forward real transform, behind one interface.
//
// `odf.cpp` is the only thing in bpmcore that transforms anything, and it wants
// exactly one operation: window a frame, transform it, read the magnitudes of a
// contiguous range of bins. Everything a particular library wants in order to
// provide that - alignment, scratch, a packing convention, a size restriction -
// lives here rather than in the analysis.
//
// Two backends, chosen at build time by BPMCORE_FFT_BACKEND:
//
//   kiss    portable scalar C, at either width. Builds anywhere, and is the
//           reference the other is checked against - see fft_backend_test.
//   pffft   SIMD, single precision only, about six times faster at the sizes
//           used here.
//
// The width is separate, and is BPMCORE_FFT_SCALAR's business. See
// cmake/fft_backend.cmake for why those are two questions rather than one.

#include <cstddef>

namespace bpmcore
{

//! The width the spectral stage computes at.
//!
//! Carried as its own definition rather than read off whichever backend was
//! linked: kiss publishes kiss_fft_scalar and pffft publishes nothing, so
//! taking it from the backend would make the analysis's arithmetic depend on
//! which library happened to be in the link. Both come from the one CMake
//! variable, and real_fft.cpp asserts that they still agree.
#if defined(BPMCORE_FFT_SCALAR_TYPE)
typedef BPMCORE_FFT_SCALAR_TYPE fft_scalar;
#else
typedef double fft_scalar;
#endif

//! One frequency bin. Laid out to match both backends: kiss_fft_cpx is this
//! struct, and pffft writes interleaved real/imaginary pairs of floats.
struct fft_cpx
{
	fft_scalar r;
	fft_scalar i;
};

//! Sizes the selected backend can transform.
//!
//! kiss takes any even size, though it only has butterflies for 2, 3 and 5 and
//! drops to a stage quadratic in the factor for anything else. pffft takes
//! 5-smooth sizes that are also a multiple of 32 - its own documented
//! restriction, N = (2^a)(3^b)(5^c) with a >= 5.
//!
//! Every rate that reaches the transform by the ordinary route is the model
//! rate times a power of two, giving 512, 1024, 2048 or 4096, all of which
//! satisfy both. This matters on the one path left: when no usable resampling
//! ratio exists the track is analysed at its own rate, and there the size is
//! whatever the window duration asks for.
bool fft_size_supported(int n);

//! The supported size nearest `ideal`.
//!
//! The window has to last 46.4ms whatever the rate, or the analysis is not the
//! one the model was fitted at, so the size follows from the duration and then
//! moves to the nearest one the transform can take. Every rate that reaches
//! here by the ordinary route is the model rate times a power of two and gets
//! 512, 1024, 2048 or 4096 exactly, under either backend. It is the odd-rate
//! fallback - where no usable resampling ratio existed and the track is
//! analysed at its own rate - that can land between sizes.
//!
//! Nothing may transform a size this did not return. pffft checks its own
//! restriction with assert() alone, so a release build hands back a setup for
//! an unsupported size and then produces a wrong spectrum with no complaint;
//! this function and `fft_size_supported` are what stand in the way of that.
int fft_size_for(int ideal);

//! A forward real transform of one fixed size.
//!
//! Not copyable and not shared between threads: one per worker. Building one
//! is what costs - twiddle tables and buffers - so a worker builds it once and
//! reuses it for every frame it takes.
class real_fft
{
public:
	explicit real_fft(int nfft);
	~real_fft();

	//! False when the size was refused or an allocation failed. A worker that
	//! is not valid must not transform anything.
	bool valid() const { return m_ok; }

	//! Where the caller writes the `nfft` windowed samples, aligned as the
	//! backend requires. Writing here rather than passing a pointer in is what
	//! lets pffft have its 16-byte alignment without the analysis knowing.
	fft_scalar * input() { return m_in; }

	//! Transform what `input` currently holds.
	void forward();

	//! Bins 0 to nfft/2 inclusive, valid until the next `forward`.
	//!
	//! Canonical order in both backends, with DC and Nyquist carrying a zero
	//! imaginary part. pffft natively packs those two real values together in
	//! its first bin; unpacking them here costs four stores a frame and means
	//! the analysis reads one layout whichever library computed it.
	const fft_cpx * bins() const { return m_bins; }

	real_fft(const real_fft &) = delete;
	real_fft & operator=(const real_fft &) = delete;

private:
	void * m_state = nullptr;      //!< kiss_fftr_cfg or PFFFT_Setup
	void * m_work = nullptr;       //!< pffft scratch; unused by kiss
	fft_scalar * m_in = nullptr;
	fft_cpx * m_bins = nullptr;
	int m_nfft = 0;
	bool m_ok = false;
};

}   // namespace bpmcore

#endif // BPMCORE_REAL_FFT_H
