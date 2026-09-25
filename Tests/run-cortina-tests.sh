#!/bin/bash
#
# Builds and runs the checks on the cortina switch: how a track's rhythm is read
# from a genre tag or from bpmcore's measurement, how a preset named "cortina"
# is found among an effect type's recent ones, and what CortinaEffects does with
# the two answers.  Also whether a track's key is worth measuring, and that the
# key names bpmcore spells are ones the app's Utils can parse -- the same scan,
# and a suite that already links Cocoa.
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
     Source/Utils.m \
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

    # Utils.m is here for GetTonalityForString alone, and brings eight uses of
    # UTType and NSAppearance API deprecated in macOS 12 with it.  The app
    # builds it the same way and says nothing; a suite that reported them on
    # every run would be how a real warning goes unread.
    EXTRA=""
    if [ "$src" = "Source/Utils.m" ]; then
        EXTRA="-Wno-deprecated-declarations"
    fi

    clang -c -o "$obj" "$src" -fobjc-arc -O1 -g -Wall -ISource -include Source/Prefix.pch $EXTRA \
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
