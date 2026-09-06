#!/bin/bash
#
# Builds and runs the AUNBandEQ editor tests.  Unlike the headless suite these
# need a window server session -- they load Apple's AUNBandEQView, host it in an
# offscreen window and draw it -- so they will not run over a plain SSH login.
#
# Each case runs in its own exec'd child, because two of them are known Apple
# crashes and would otherwise take the whole run with them.
#
# Usage: Tests/run-nbandeq-view-tests.sh

set -uo pipefail

cd "$(dirname "$0")/.."

SRC="Tests/NBandEQViewTests.m Source/AudioUnitStateValidation.m"
OUT="${TMPDIR:-/tmp}/nbandeq-view-tests"

echo "### building"
clang -o "$OUT" $SRC \
    -fobjc-arc -O1 -g -Wall \
    -framework Cocoa -framework AudioToolbox -framework AVFoundation -framework CoreAudioKit \
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
