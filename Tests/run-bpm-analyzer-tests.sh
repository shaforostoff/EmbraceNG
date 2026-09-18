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

# The app's own Objective-C.  WorkerService.m is in here because the suite drives
# the real worker: the gate deciding whether a scan measures the tempo lives in
# it, and a transcription of that gate would be a transcription of the thing
# under test.  It brings MetadataParser, LoudnessMeasurer and TrackKeys with it.
#
# The -Wno- flags are here because -Wall -Wextra is stricter than what the
# project builds these files with, and every one of them fires on code that was
# already there: an ASBD written as {0}, a signed loop counter against a size_t,
# UTTypeConformsTo, and the unused `self` that a static function inside a class
# body is handed.  A suite that reported them would report them on every run
# forever, which is how a real warning goes unread.  Waiving them here rather
# than editing the files keeps the suite's opinion out of the app's sources.
#
# -Wno-unused-but-set-variable was for two byte counters in WorkerService.m that
# nothing read.  They are gone, so it is too -- and if either comes back the
# suite says so.
for f in Source/HugAudioFile.m Source/HugError.m Source/HugUtils.m \
         Source/WorkerService.m Source/MetadataParser.m Source/LoudnessMeasurer.m Source/TrackKeys.m; do

    # WorkerService.m is the XPC service's executable and carries its own
    # main(), which the suite already has one of.  Renaming it at the
    # preprocessor is the whole of the accommodation: `main` appears in that
    # file exactly once, as the definition, and the suite reaches the Worker
    # class directly rather than through a listener.
    EXTRA=""
    if [ "$f" = "Source/WorkerService.m" ]; then
        EXTRA="-Dmain=sUnusedWorkerServiceMain"
    fi

    clang -c -o "$OBJ/$(basename $f .m).o" "$f" \
        -std=gnu99 -O2 -g -fobjc-arc -Wall -Wextra \
        -Wno-missing-field-initializers -Wno-sign-compare \
        -Wno-deprecated-declarations \
        -Wno-unused-parameter \
        $EXTRA -ISource \
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
    -framework iTunesLibrary -framework Accelerate -framework CoreMedia -framework CoreServices \
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
