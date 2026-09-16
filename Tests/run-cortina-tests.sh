#!/bin/bash
#
# Builds and runs the checks on the cortina switch: how a track's rhythm is read
# from a genre tag or from bpmcore's measurement, how a preset named "cortina"
# is found among an effect type's recent ones, and what CortinaEffects does with
# the two answers.
#
# No window server and no audio device -- it instantiates audio units but never
# renders through them -- so this runs over a plain SSH login.  It writes preset
# files into $TMPDIR and uses a defaults domain named after its own executable,
# and clears both on the way out.
#
# Usage: Tests/run-cortina-tests.sh

set -uo pipefail

cd "$(dirname "$0")/.."

SRC="Tests/CortinaTests.m \
     Source/CortinaEffects.m \
     Source/DanceRhythm.m \
     Source/RecentPresets.m \
     Source/Effect.m \
     Source/EffectType.m \
     Source/AudioUnitStateValidation.m"

DIR="${TMPDIR:-/tmp}/cortina-tests-build"
OUT="$DIR/cortina-tests"

rm -rf "$DIR"
mkdir -p "$DIR"

echo "### building"

OBJECTS=""

for src in $SRC; do
    obj="$DIR/$(basename "$src").o"
    clang -c -o "$obj" "$src" -fobjc-arc -O1 -g -Wall -ISource -include Source/Prefix.pch \
        || { echo "build failed"; exit 1; }
    OBJECTS="$OBJECTS $obj"
done

clang -o "$OUT" $OBJECTS \
    -fobjc-arc \
    -framework Cocoa -framework AudioToolbox -framework AVFoundation \
    || { echo "link failed"; exit 1; }

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
