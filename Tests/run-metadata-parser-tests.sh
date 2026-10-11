#!/bin/bash
#
# Builds and runs the checks on MetadataParser's two byte-level walks: the AIFF
# chunk walk that finds an embedded ID3 tag, and the ID3v2 frame walk that cuts
# padding off a tag before handing it to AVFoundation.  Each gets a tag that
# should read and damaged ones that must return rather than crash or hang.
#
# No window server and no audio device.  It writes its files into $TMPDIR and
# removes them on the way out.
#
# Usage: Tests/run-metadata-parser-tests.sh

set -uo pipefail

cd "$(dirname "$0")/.."

DIR="${TMPDIR:-/tmp}/metadata-parser-tests-build"
OUT="$DIR/metadata-parser-tests"

rm -rf "$DIR"
mkdir -p "$DIR"

echo "### building"

# Not Prefix.pch: the parser needs Foundation and AVFoundation, and the prefix
# would bring the app's Utils and window classes with it.  UTTypeConformsTo is
# deprecated since macOS 12 and the app builds it the same way.
clang -o "$OUT" \
    Tests/MetadataParserTests.m Source/MetadataParser.m Source/TrackKeys.m \
    -fobjc-arc -O1 -g -Wall -Wno-deprecated-declarations -ISource \
    -framework Foundation -framework AudioToolbox -framework AVFoundation -framework CoreMedia -framework CoreServices \
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
