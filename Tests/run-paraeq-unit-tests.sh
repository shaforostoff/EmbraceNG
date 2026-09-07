#!/bin/bash
#
# Builds and runs the checks on the parametric EQ audio unit -- registration,
# EffectType discovery, the parameter tree, rendering through the unit's own
# AUInternalRenderBlock, preset round-tripping and the editor.
#
# Needs a window server session, because it builds the editor and draws it, so
# this will not run over a plain SSH login.  The core's own maths has no such
# requirement: see run-paraeq-core-tests.sh.
#
# Usage: Tests/run-paraeq-unit-tests.sh

set -uo pipefail

cd "$(dirname "$0")/.."

# Two groups, because -std=c++17 is not a thing you may hand a .m file.
CXX_SRC="Tests/ParametricEQUnitTests.mm \
         Source/paraeq_core.cpp \
         Source/ParametricEQAudioUnit.mm \
         Source/ParametricEQView.mm"

OBJC_SRC="Source/ParameterFormView.m \
          Source/EffectType.m \
          Source/EffectAdditions.m \
          Source/AudioUnitStateValidation.m"

DIR="${TMPDIR:-/tmp}/paraeq-unit-tests-build"
OUT="${TMPDIR:-/tmp}/paraeq-unit-tests"

rm -rf "$DIR"
mkdir -p "$DIR"

echo "### building"

OBJECTS=""

for src in $CXX_SRC; do
    obj="$DIR/$(basename "$src").o"
    clang++ -c -o "$obj" "$src" -fobjc-arc -std=c++17 -O1 -g -Wall -ISource \
        || { echo "build failed"; exit 1; }
    OBJECTS="$OBJECTS $obj"
done

for src in $OBJC_SRC; do
    obj="$DIR/$(basename "$src").o"
    clang -c -o "$obj" "$src" -fobjc-arc -O1 -g -Wall -ISource \
        || { echo "build failed"; exit 1; }
    OBJECTS="$OBJECTS $obj"
done

clang++ -o "$OUT" $OBJECTS \
    -fobjc-arc \
    -framework Cocoa -framework AudioToolbox -framework AVFoundation -framework CoreAudioKit \
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
