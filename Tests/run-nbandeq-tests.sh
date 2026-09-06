#!/bin/bash
#
# Builds and runs the AUNBandEQ test suite in several allocator configurations.
# A plain run catches contract violations and canary damage; the guard-malloc
# run catches out-of-bounds writes inside AudioToolbox itself, which is what an
# instrumented build of the app can never see on its own.
#
# Usage: Tests/run-nbandeq-tests.sh [--quick]

set -uo pipefail

cd "$(dirname "$0")/.."

SRC="Tests/NBandEQTests.m Source/AudioUnitStateValidation.m"
OUT="${TMPDIR:-/tmp}/nbandeq-tests"
ARGS="${1:-}"

echo "### building"
clang -o "$OUT" $SRC \
    -fobjc-arc -O1 -g -Wall \
    -framework Foundation -framework AudioToolbox -framework AVFoundation \
    || { echo "build failed"; exit 1; }

STATUS=0

echo
echo "### 1/3  plain run"
"$OUT" $ARGS || STATUS=1

echo
echo "### 2/3  libmalloc diagnostics (scribble + guard edges)"
MallocScribble=1 \
MallocPreScribble=1 \
MallocGuardEdges=1 \
MallocErrorAbort=1 \
"$OUT" $ARGS || STATUS=1

echo
echo "### 3/3  guard malloc (every allocation on its own page)"
# Catches out-of-bounds writes made by AudioToolbox itself, including into
# buffers the host owns.  Slow, so run the reduced suite.
#
# MALLOC_STRICT_SIZE is deliberately NOT set: it places allocations on byte
# boundaries, which crashes CoreFoundation's plist parser (CFBurstTrie) during
# process start, long before any audio unit is touched.  That is the documented
# "applications expecting word-aligned pointers may fail" caveat, not a finding.
DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib \
MALLOC_FILL_SPACE=1 \
"$OUT" --quick || STATUS=1

echo
if [ "$STATUS" -eq 0 ]; then
    echo "### all configurations passed"
else
    echo "### FAILURES -- see above"
fi
exit "$STATUS"
