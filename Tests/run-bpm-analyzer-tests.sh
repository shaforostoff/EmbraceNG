#!/bin/bash
#
# Builds and runs the checks on Source/BPMAnalyzer and the vendored bpmcore
# under it.  Headless -- no window server and no audio device -- so this runs
# over a plain SSH login; it does write two WAV files into $TMPDIR and delete
# them again, since the point of half the suite is to go through a real decode.
#
# Built the way the worker builds it: pffft at single precision, which is what
# BPMCORE_FFT_PFFFT and BPMCORE_FFT_SCALAR_TYPE=float select.  Those two have to
# match Config/TargetWorker.xcconfig or this is testing a different analyser
# from the one that ships, and real_fft.cpp refuses to compile if they disagree
# with each other.
#
# Usage: Tests/run-bpm-analyzer-tests.sh

set -uo pipefail

cd "$(dirname "$0")/.."

OUT="${TMPDIR:-/tmp}/bpm-analyzer-tests"
OBJ="${TMPDIR:-/tmp}/bpm-analyzer-tests.objs"

DEFS="-DBPMCORE_FFT_PFFFT -DBPMCORE_FFT_SCALAR_TYPE=float"

rm -rf "$OBJ" && mkdir -p "$OBJ"

echo "### building"

# Three passes rather than one line, because these are three languages and the
# app builds them as three.  Handing the whole list to clang++ with -x
# objective-c++ does work for most of it and then stops at HugUtils.m, which is
# C enough to want an implicit void * conversion -- and a suite that compiled
# the app's own files under a different language from the app would be checking
# something the app does not build.

# pffft, C.
clang -c -o "$OBJ/pffft.o" Vendor/pffft/pffft.c \
    -O2 -g -IVendor $DEFS \
    -Wall -Wextra -Wno-missing-prototypes -Wno-shadow \
    || { echo "build failed"; exit 1; }

# The app's own Objective-C.  -Wno-missing-field-initializers because these are
# existing files and every ASBD in them is a {0}; the suite is not the place to
# start reporting that.
for f in Source/HugAudioFile.m Source/HugError.m Source/HugUtils.m; do
    clang -c -o "$OBJ/$(basename $f .m).o" "$f" \
        -std=gnu99 -O2 -g -fobjc-arc -Wall -Wextra -Wno-missing-field-initializers \
        -ISource \
        || { echo "build failed"; exit 1; }
done

# bpmcore, C++.
for f in Vendor/bpmcore/*.cpp; do
    clang++ -c -o "$OBJ/$(basename $f .cpp).o" "$f" \
        -std=gnu++11 -stdlib=libc++ -O2 -g -Wall -Wextra \
        -IVendor $DEFS \
        || { echo "build failed"; exit 1; }
done

# The wrapper and the suite, Objective-C++, and the link.
clang++ -o "$OUT" Source/BPMAnalyzer.mm Tests/BPMAnalyzerTests.mm "$OBJ"/*.o \
    -std=gnu++11 -stdlib=libc++ -O2 -g -fobjc-arc -Wall -Wextra \
    -ISource -IVendor $DEFS \
    -framework Foundation -framework AudioToolbox -framework AVFoundation \
    || { echo "build failed"; exit 1; }

echo
echo "### running"

"$OUT"
STATUS=$?

echo
if [ "$STATUS" -eq 0 ]; then
    echo "### passed"
else
    echo "### FAILURES -- see above"
fi

exit "$STATUS"
