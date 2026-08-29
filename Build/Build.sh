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

trap 'rm -rf "$DSTROOT"' EXIT

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
