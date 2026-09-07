#!/bin/bash
#
# Builds and runs the checks on the recent-presets list in each effect editor's
# "..." menu -- that the menu is found through the xib, and that the list is
# ordered, capped, deduplicated and kept apart per effect type.
#
# Needs a window server session, because it loads the real nibs and creates
# their windows, so this will not run over a plain SSH login.
#
# Usage: Tests/run-preset-menu-tests.sh

set -uo pipefail

cd "$(dirname "$0")/.."

SRC="Tests/PresetMenuTests.m \
     Source/EditEffectController.m \
     Source/Effect.m \
     Source/EffectType.m \
     Source/EffectAdditions.m \
     Source/AudioUnitStateValidation.m"

XIBS="Resources/EditSystemEffectWindow.xib \
      Resources/EditGraphicEQEffectWindow.xib"

DIR="${TMPDIR:-/tmp}/preset-menu-tests-build"
OUT="$DIR/preset-menu-tests"

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

# -[NSWindowController windowNibName] resolves against the bundle of its class,
# which for a bare executable is the directory the executable sits in.
for xib in $XIBS; do
    ibtool --errors --warnings --compile "$DIR/$(basename "$xib" .xib).nib" "$xib" > /dev/null \
        || { echo "nib compile failed"; exit 1; }
done

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
