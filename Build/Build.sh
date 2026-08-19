#!/bin/sh
#
# Builds a Release Embrace.app for running on this Mac.
#
# Build/Archive.sh is the distribution path: it exports a signed archive, sends it
# to Apple's notary service and uploads the result.  This script stops short of all
# of that, so it needs no Private/Archive.plist and no notarization credentials.
#
# Usage: Build/Build.sh [output-directory]     (defaults to ~/Desktop)
#
# Set SIGN_IDENTITY to choose a signing identity.  When it is unset, the first
# installed "Developer ID Application" identity is used, falling back to an ad-hoc
# signature.  Ad-hoc signatures change on every build, so macOS re-asks for the
# app's Automation and file access permissions each time -- prefer a real identity
# if you have one.  Neither signature is timestamped; that is only needed for
# notarization, so use Archive.sh when building something to hand out.

set -e

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT_DIR="${1:-$HOME/Desktop}"

CONFIGURATION="Release"
DERIVED_DATA="${TMPDIR:-/tmp/}Embrace-Build"
DSTROOT=$(mktemp -d /tmp/Embrace-Build.XXXXXX)

trap 'rm -rf "$DSTROOT"' EXIT

# ----------------------------------
# Pick a signing identity

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning |
        sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)
fi

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
    echo "No Developer ID Application identity found, signing ad-hoc."
else
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
    -project Embrace.xcodeproj \
    -target Embrace \
    -configuration "$CONFIGURATION" \
    DSTROOT="$DSTROOT" \
    SYMROOT="$DERIVED_DATA/Products" \
    OBJROOT="$DERIVED_DATA/Intermediates" \
    SHARED_PRECOMPS_DIR="$DERIVED_DATA/PrecompiledHeaders" \
    CODE_SIGN_STYLE="Manual" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER=""

APP_FILE=$(find "$DSTROOT" -maxdepth 3 -name "Embrace.app" | head -1)

if [ -z "$APP_FILE" ]; then
    echo "Build finished but no Embrace.app was produced." >&2
    exit 1
fi

# ----------------------------------
# Move into place and verify

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/Embrace.app"
ditto "$APP_FILE" "$OUTPUT_DIR/Embrace.app"

codesign --verify --deep --strict "$OUTPUT_DIR/Embrace.app"

BUILD_NUMBER=$(defaults read "$OUTPUT_DIR/Embrace.app/Contents/Info.plist" CFBundleVersion)
VERSION=$(defaults read "$OUTPUT_DIR/Embrace.app/Contents/Info.plist" CFBundleShortVersionString)

echo
echo "Built Embrace $VERSION ($BUILD_NUMBER)"
echo "$OUTPUT_DIR/Embrace.app"
