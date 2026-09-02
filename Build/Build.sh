#!/bin/sh
#
# Builds a Release EmbraceNG.app for running on this Mac.
#
# Build/Archive.sh is the distribution path: it exports a signed archive, sends it
# to Apple's notary service and uploads the result.  This script stops short of all
# of that, so it needs no Private/Archive.plist and no notarization credentials.
#
# Usage: Build/Build.sh [output-directory]     (defaults to ~/Desktop)
#
# Signing is ad-hoc by default: no certificate, no team identifier.  Set
# SIGN_IDENTITY to sign with one instead -- either "auto" for the first installed
# "Developer ID Application" identity, or the full name of the one to use.
#
# Ad-hoc signatures change on every build, so macOS re-asks for the app's
# Automation and file access permissions each time; a real identity is worth
# setting if you have one to hand.
#
# Signing with a real identity also asks Apple's timestamp server for a secure
# timestamp, which notarization requires and an ad-hoc signature cannot carry.  So
# a build made with SIGN_IDENTITY can be handed straight to Package.sh --notarize,
# at the cost of needing the network; an ad-hoc build stays offline and local.

set -e

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT_DIR="${1:-$HOME/Desktop}"

CONFIGURATION="Release"
DERIVED_DATA="${TMPDIR:-/tmp/}EmbraceNG-Build"
DSTROOT=$(mktemp -d /tmp/EmbraceNG-Build.XXXXXX)
BUILD_LOG=$(mktemp /tmp/EmbraceNG-Build-Log.XXXXXX)

trap 'rm -rf "$DSTROOT" "$BUILD_LOG"' EXIT

# ----------------------------------
# Pick a signing identity

if [ "$SIGN_IDENTITY" = "auto" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning |
        sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)

    if [ -z "$SIGN_IDENTITY" ]; then
        echo "SIGN_IDENTITY=auto, but no Developer ID Application identity is installed." >&2
        exit 1
    fi
fi

# Apple rejects a signature without a secure timestamp, so a real identity always
# gets one.  Ad-hoc signing cannot carry a timestamp at all -- codesign refuses the
# combination -- which is why the flag is turned off rather than simply left out.

if [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = "-" ]; then
    SIGN_IDENTITY="-"
    TIMESTAMP_FLAG="--timestamp=none"
    echo "Signing ad-hoc. Set SIGN_IDENTITY to sign with a certificate."
else
    TIMESTAMP_FLAG="--timestamp"
    echo "Signing with: $SIGN_IDENTITY"
fi

# ----------------------------------
# Build
#
# "install" rather than "build" so the Remove Debug Files phase runs -- it is
# marked deployment-postprocessing-only and strips the test tones and the debug
# window out of the app.

cd "$PROJECT_DIR"

run_xcodebuild ()
{
    xcodebuild install \
        -project EmbraceNG.xcodeproj \
        -target EmbraceNG \
        -configuration "$CONFIGURATION" \
        DSTROOT="$DSTROOT" \
        SYMROOT="$DERIVED_DATA/Products" \
        OBJROOT="$DERIVED_DATA/Intermediates" \
        SHARED_PRECOMPS_DIR="$DERIVED_DATA/PrecompiledHeaders" \
        CODE_SIGN_STYLE="Manual" \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        OTHER_CODE_SIGN_FLAGS="$TIMESTAMP_FLAG" \
        DEVELOPMENT_TEAM="" \
        PROVISIONING_PROFILE_SPECIFIER=""
}

# Apple's timestamp server turns requests away when it is asked for several in
# quick succession, and this build asks three times in a row -- the app, the XPC
# service and the nested Crash Pad.  It surfaces as "The timestamp service is not
# available" against whichever signature happened to be third, and it fails the
# whole build, so the build is simply asked for again.  Xcode redoes only the
# signing that did not finish, which takes seconds rather than another full build.
#
# Success is read off xcodebuild's own banner: the exit status is out of reach
# behind the tee that keeps the build's output on screen while it runs.

BUILD_ATTEMPTS=4
ATTEMPT=1
RETRY_DELAY=10

while : ; do
    set +e
    run_xcodebuild 2>&1 | tee "$BUILD_LOG"
    set -e

    if grep -q "^\*\* INSTALL SUCCEEDED \*\*" "$BUILD_LOG"; then
        break
    fi

    if ! grep -q "The timestamp service is not available" "$BUILD_LOG"; then
        echo "Build failed." >&2
        exit 1
    fi

    if [ "$ATTEMPT" -ge "$BUILD_ATTEMPTS" ]; then
        echo >&2
        echo "Apple's timestamp server refused $BUILD_ATTEMPTS times. Try again later, or" >&2
        echo "build without a certificate -- an ad-hoc build asks it for nothing." >&2
        exit 1
    fi

    ATTEMPT=$((ATTEMPT + 1))

    # Backed off rather than retried at a fixed interval: a run of builds close
    # together gets refused for longer than a few seconds at a time.

    echo
    echo "Apple's timestamp server was busy. Retrying ($ATTEMPT of $BUILD_ATTEMPTS)" \
         "in ${RETRY_DELAY}s."

    sleep "$RETRY_DELAY"
    RETRY_DELAY=$((RETRY_DELAY * 2))
done

APP_FILE=$(find "$DSTROOT" -maxdepth 3 -name "EmbraceNG.app" | head -1)

if [ -z "$APP_FILE" ]; then
    echo "Build finished but no EmbraceNG.app was produced." >&2
    exit 1
fi

# ----------------------------------
# Move into place and verify

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/EmbraceNG.app"
ditto "$APP_FILE" "$OUTPUT_DIR/EmbraceNG.app"

codesign --verify --deep --strict "$OUTPUT_DIR/EmbraceNG.app"

BUILD_NUMBER=$(defaults read "$OUTPUT_DIR/EmbraceNG.app/Contents/Info.plist" CFBundleVersion)
VERSION=$(defaults read "$OUTPUT_DIR/EmbraceNG.app/Contents/Info.plist" CFBundleShortVersionString)

echo
echo "Built EmbraceNG $VERSION ($BUILD_NUMBER)"
echo "$OUTPUT_DIR/EmbraceNG.app"
