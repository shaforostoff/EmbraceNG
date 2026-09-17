# Vendored sources

Both directories are verbatim copies, and neither is developed here.  A change
made in this tree is a change that will be lost the next time either is synced,
so fix things upstream and copy the result back.

`Build/SyncVendor.sh` is what does the copying, and what checks that paragraph
is still true: it reads the revision below, compares every file against it, and
names the ones that have drifted.

    Build/SyncVendor.sh              does this still match what it says it is?
    Build/SyncVendor.sh --log        what has upstream done since
    Build/SyncVendor.sh --sync       take it, and move the revision below

The pin lives in this file and nowhere else, which is why the script edits it
rather than keeping a copy of its own.

## bpmcore

The tempo and rhythm analysis behind `Source/BPMAnalyzer`, taken from

    https://github.com/shaforostoff/foo_rubato   bpmcore/
    revision 550f38744f71b165ed86992f63d8d3d2b35a55b1, 2026-09-13

`bpmcore` is deliberately free of any host -- no foobar2000, no Windows, no
AudioToolbox -- so the same sources build here as they do in the foobar2000
component.  It takes mono PCM and the standard library and nothing else, and
`real_fft.h` is the only file in it that names a transform.  That is why this
is a copy of a directory rather than a port of one: nothing needed changing.

Start at `bpmcore/bpmcore.h`.  The method and the measurements are in
`docs/tango-analysis.md` upstream.

Every file is here except `CMakeLists.txt`, which describes a build this
project does not use.  What it settles, the Xcode project settles instead:

  * `BPMCORE_FFT_PFFFT` selects the transform, and
  * `BPMCORE_FFT_SCALAR_TYPE=float` fixes the width of the spectral stage.

Both definitions have to reach every file that includes `real_fft.h`, and
`pffft` requires the second -- it is single precision and has no double
variant.  `real_fft.cpp` asserts the pair still agree, so a build that drops
one fails to compile rather than transforming at the wrong width.

## pffft

    https://bitbucket.org/jpommier/pffft
    revision 0aec0327a6912e1a0ec5326eef737c2ce19bc836
    retrieved 2026-09-13, by way of foo_rubato

    sha256  485f2c641b9bc9434720757307e825c2f694b682438da9052959ab1e445e1f16  pffft.c
    sha256  d6ac7f26f7c3f87ed2ad7f0264c09d72285526d937b4dccc5fc1c97645a0d55d  pffft.h

`COPYING` is the licence block lifted out of the header.  Upstream ships the
transform as those two files, so that is all there is.

The SIMD transform rather than the portable scalar one upstream ships by
default: it is about six times faster at the sizes used here, which is most of
what an analysis costs, and this runs while the DJ is waiting for a track to
become playable.  It uses SSE on Intel and NEON on Apple silicon, both of which
are always present on a Mac, so there is no configuration to make and no
fallback path to keep working.

Nothing in either directory is patched, and `Build/SyncVendor.sh` with no
arguments is how to be sure of that rather than hopeful about it.  If it ever
does change, say so here and keep the diff alongside -- a silent local change to
a vendored file is how a build stops matching its provenance.

A sync that brings over a file that was not here before needs one more step:
the Worker target lists these sources one by one rather than referencing the
folder, so a new `.cpp` will not be compiled until it is added to the project.
The script says so when it happens.

## Warnings

`pffft.c` is compiled with `-Wno-missing-prototypes -Wno-shadow`, set on its
build file in the Xcode project rather than in the file.  It is clean under its
own upstream build and only trips these because this project turns them on; the
seven warnings would otherwise be on every build forever, which is how a real
one goes unread.  Fixing them in the file would be a patch, and the point of the
paragraph above is that there are none.

`bpmcore` compiles clean at this project's warning level with nothing waived.
