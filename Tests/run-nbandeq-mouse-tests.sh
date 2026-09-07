#!/bin/bash
#
# Builds and runs the synthesized-mouse tests against Apple's AUNBandEQ editor.
# Needs a window server session.  Each test group runs in its own exec'd child
# under a watchdog, because a wedged AppKit tracking loop would otherwise hang
# the run indefinitely.
#
# Usage: Tests/run-nbandeq-mouse-tests.sh

set -uo pipefail

cd "$(dirname "$0")/.."

OUT="${TMPDIR:-/tmp}/nbandeq-mouse-tests"

echo "### building"
clang -o "$OUT" Tests/NBandEQMouseTests.m \
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
