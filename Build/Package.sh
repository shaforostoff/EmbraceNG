#!/bin/sh
#
# Wraps a built EmbraceNG.app in a compressed, read-only .dmg that installs by
# dragging onto the Applications alias inside the disk image.
#
# Build/Build.sh produces an .app for running on this Mac; Build/Archive.sh is the
# full distribution path and hands out a notarized .zip.  This sits between them:
# it packages the app the way most Mac software is still shipped.
#
# Usage: Build/Package.sh [--codesign <certificate>] [--notarize]
#                         [--notary-profile <name>] [output-directory]
#                                                    (output defaults to ~/Desktop)
#
# By default the app is built from scratch with Build/Build.sh.  Point APP_FILE at
# an existing bundle to skip the build and package that instead -- that is the way
# to wrap the stapled app Archive.sh leaves behind, so the notarization survives
# into the disk image:
#
#     APP_FILE=~/Desktop/EmbraceNG.app Build/Package.sh
#
# Signing is ad-hoc by default: no certificate, no team identifier, nothing read
# out of the keychain.  Whoever opens the image has to clear Gatekeeper by hand the
# first time, which is the usual trade for an unsigned open-source build.
#
# --codesign, or SIGN_IDENTITY in the environment, opens the other path when there
# is a certificate to sign with:
#
#     Build/Package.sh --codesign auto                    first installed
#                                                          Developer ID
#     Build/Package.sh --codesign "Developer ID Application: Some Name (TEAMID)"
#     SIGN_IDENTITY=auto Build/Package.sh
#
# One certificate covers both signatures: the app, and the disk image wrapped
# around it.  Both are signed with codesign and both matter -- the image is the
# file that gets downloaded, so an ad-hoc image is refused by Gatekeeper however
# well signed the app inside it is.  Both want a "Developer ID Application"
# certificate; a "Developer ID Installer" one signs .pkg files and cannot sign code
# at all, which is checked for before anything is built.
#
# "auto" means the first installed Developer ID Application certificate.  The
# keychain is only searched when it is asked for, so a certificate that happens to
# be installed -- a work certificate, say -- never ends up on a build unnamed.
#
# Pass --notarize to send the finished image to Apple's notary service and staple
# the ticket to it.  That needs a real identity plus a notarytool keychain profile,
# the kind 'xcrun notarytool store-credentials' writes.  The default path touches
# neither, so it needs no credentials at all.
#
# Which profile is used comes from Private/Archive.plist's keychain-profile entry,
# the same one Archive.sh reads.  --notary-profile names one directly instead, for
# an account that is not the one this checkout usually ships from:
#
#     Build/Package.sh --notarize --notary-profile ShellacFilters
#
# Notarization also requires every binary in the app to carry a secure timestamp,
# which the app is checked for before it is submitted -- Apple only reports that
# several minutes in, and reports it as the whole submission being invalid.

set -e

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)

NOTARIZE=no
NOTARY_PROFILE=""
OUTPUT_DIR=""

# SIGN_IDENTITY arrives from the environment and --codesign displaces it.  Empty
# stays empty here; ad-hoc is settled further down, once "auto" has had its chance
# to name a certificate.  The source is remembered so that a certificate that turns
# out to be unusable is blamed on whichever of the two named it.

IDENTITY_SOURCE="SIGN_IDENTITY"

# Reached from both spellings of every option that takes a value, and from the one
# that ran off the end of the arguments -- "$1" is empty there too.

require_option_value ()
{
    if [ -z "$2" ]; then
        echo "$1 needs $3." >&2

        if [ -n "$4" ]; then
            echo "$4" >&2
        fi

        exit 1
    fi
}

CERTIFICATE_HINT="Use \"auto\" for the first installed Developer ID Application certificate."

while [ $# -gt 0 ]; do
    case "$1" in
        --notarize)
            NOTARIZE=yes
            ;;
        --notary-profile)
            shift
            require_option_value --notary-profile "$1" \
                "the name of a notarytool keychain profile" \
                "Store one with 'xcrun notarytool store-credentials'."
            NOTARY_PROFILE="$1"
            ;;
        --notary-profile=*)
            require_option_value --notary-profile "${1#--notary-profile=}" \
                "the name of a notarytool keychain profile" \
                "Store one with 'xcrun notarytool store-credentials'."
            NOTARY_PROFILE="${1#--notary-profile=}"
            ;;
        --codesign)
            shift
            require_option_value --codesign "$1" \
                "the name of a certificate to sign with" "$CERTIFICATE_HINT"
            SIGN_IDENTITY="$1"
            IDENTITY_SOURCE="--codesign"
            ;;
        --codesign=*)
            require_option_value --codesign "${1#--codesign=}" \
                "the name of a certificate to sign with" "$CERTIFICATE_HINT"
            SIGN_IDENTITY="${1#--codesign=}"
            IDENTITY_SOURCE="--codesign"
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            OUTPUT_DIR="$1"
            ;;
    esac

    shift
done

OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Desktop}"

if [ -n "$NOTARY_PROFILE" ] && [ "$NOTARIZE" = "no" ]; then
    echo "--notary-profile has nothing to name without --notarize." >&2
    exit 1
fi

VOLUME_NAME="EmbraceNG"
STAGING_DIR=$(mktemp -d /tmp/EmbraceNG-Package.XXXXXX)
BUILD_DIR=""

cleanup ()
{
    # Grabbed first and re-raised last: an EXIT trap otherwise reports the status of
    # whatever it did itself, which turns a clean run into a failure.
    STATUS=$?

    # A failed hdiutil can leave the volume mounted and the staging directory busy.
    if [ -d "/Volumes/$VOLUME_NAME" ]; then
        hdiutil detach "/Volumes/$VOLUME_NAME" -force > /dev/null 2>&1 || true
    fi

    rm -rf "$STAGING_DIR"

    if [ -n "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi

    exit "$STATUS"
}

trap cleanup EXIT

# ----------------------------------
# Settle the two signing identities
#
# Unset means ad-hoc.  Answers land in RESOLVED_IDENTITY rather than coming back on
# stdout, so that a command substitution does not swallow the exits below.

resolve_identity ()
{
    case "$1" in
        auto)
            RESOLVED_IDENTITY=$(security find-identity -v -p codesigning |
                sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)

            if [ -z "$RESOLVED_IDENTITY" ]; then
                echo "$2 is \"auto\", but no Developer ID Application identity is installed." >&2
                exit 1
            fi
            ;;
        "")
            RESOLVED_IDENTITY="-"
            ;;
        *)
            RESOLVED_IDENTITY="$1"

            # A "Developer ID Installer" certificate is the usual thing to land here by
            # mistake: it signs .pkg installers, and codesign refuses it outright.  The
            # codesigning policy leaves those out, which makes it the test.  codesign
            # matches a certificate by any substring of its name, and by its hash, so
            # the whole line is searched rather than the quoted name alone.

            if ! security find-identity -v -p codesigning | grep -qF "$RESOLVED_IDENTITY"; then
                echo "$2 names \"$RESOLVED_IDENTITY\", which cannot sign code." >&2

                case "$RESOLVED_IDENTITY" in
                    *"Developer ID Installer"*)
                        echo >&2
                        echo "That one signs .pkg installers, through productsign. Both the app and" >&2
                        echo "the .dmg around it are signed with codesign, which takes a Developer ID" >&2
                        echo "Application certificate instead." >&2
                        ;;
                esac

                echo >&2
                echo "Installed certificates that can sign code:" >&2

                security find-identity -v -p codesigning |
                    sed -n 's/.*"\(.*\)"/    \1/p' >&2

                exit 1
            fi
            ;;
    esac
}

resolve_identity "$SIGN_IDENTITY" "$IDENTITY_SOURCE"
SIGN_IDENTITY="$RESOLVED_IDENTITY"

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Signing ad-hoc. Set --codesign to sign with a certificate."
else
    echo "Signing with: $SIGN_IDENTITY"
fi

# Both halves of an ad-hoc build are unnotarizable: the app carries no secure
# timestamp, which Apple requires, and the image is what Gatekeeper judges once it
# has been downloaded.  Caught here rather than by the timestamp check further
# down, which would only say so after sitting through a whole build first.

if [ "$NOTARIZE" = "yes" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "--notarize needs a Developer ID Application certificate: an ad-hoc app" >&2
    echo "carries no secure timestamp and an ad-hoc image cannot be notarized." >&2
    echo "Pass --codesign or set SIGN_IDENTITY." >&2
    exit 1
fi

# ----------------------------------
# Get the app

if [ -n "$APP_FILE" ]; then
    if [ ! -d "$APP_FILE" ]; then
        echo "APP_FILE is set but '$APP_FILE' is not a bundle." >&2
        exit 1
    fi

    echo "Packaging $APP_FILE"
else
    BUILD_DIR=$(mktemp -d /tmp/EmbraceNG-Package-Build.XXXXXX)

    SIGN_IDENTITY="$SIGN_IDENTITY" "$PROJECT_DIR/Build/Build.sh" "$BUILD_DIR"

    APP_FILE="$BUILD_DIR/EmbraceNG.app"
fi

# ----------------------------------
# Check the app can be notarized at all
#
# Apple turns down any binary whose signature has no secure timestamp, and marks
# the entire submission Invalid to say so -- several minutes after it was sent, and
# only in the log the submission ID has to be fetched with.  The nested app and XPC
# service are signed separately from the app around them, so each one is asked.

if [ "$NOTARIZE" = "yes" ]; then
    NESTED_CODE=$(find "$APP_FILE/Contents" \
        \( -name "*.app" -o -name "*.xpc" -o -name "*.framework" \) -print)

    UNTIMESTAMPED=""

    # find separates with newlines and bundle names contain spaces ("Crash Pad.app"),
    # so the split has to happen on newlines alone.

    SAVED_IFS=$IFS
    IFS='
'
    for CODE_FILE in "$APP_FILE" $NESTED_CODE; do
        if ! codesign --display --verbose=4 "$CODE_FILE" 2>&1 | grep -q "^Timestamp="; then
            UNTIMESTAMPED="$UNTIMESTAMPED  $CODE_FILE
"
        fi
    done
    IFS=$SAVED_IFS

    if [ -n "$UNTIMESTAMPED" ]; then
        echo "--notarize needs every binary signed with a secure timestamp. These are not:" >&2
        echo >&2
        printf '%s' "$UNTIMESTAMPED" >&2
        echo >&2
        echo "Ad-hoc signatures never carry one. Build with a Developer ID certificate," >&2
        echo "which timestamps as it signs:" >&2
        echo >&2
        echo "    Build/Package.sh --codesign auto --notarize" >&2
        exit 1
    fi
fi

VERSION=$(defaults read "$APP_FILE/Contents/Info.plist" CFBundleShortVersionString)
BUILD_NUMBER=$(defaults read "$APP_FILE/Contents/Info.plist" CFBundleVersion)

# x86_64, arm64, or universal -- named after what the binary actually contains
# rather than after whatever this Mac happens to be.

ARCHITECTURES=$(lipo -archs "$APP_FILE/Contents/MacOS/EmbraceNG")

case "$(echo "$ARCHITECTURES" | wc -w)" in
    1) ARCHITECTURE="$ARCHITECTURES" ;;
    *) ARCHITECTURE="universal" ;;
esac

DMG_NAME="embraceng-${VERSION}-${ARCHITECTURE}.dmg"
DMG_FILE="$OUTPUT_DIR/$DMG_NAME"

# ----------------------------------
# Stage the contents of the image
#
# ditto rather than cp -R: it preserves the symlinks, resource forks and extended
# attributes inside the bundle, and a mangled bundle breaks its signature.

ditto "$APP_FILE" "$STAGING_DIR/EmbraceNG.app"
ln -s /Applications "$STAGING_DIR/Applications"

# Finder shows this in place of the generic white disk icon.  SetFile ships with
# the Command Line Tools; skip the icon rather than fail the build without it.

if [ -f "$PROJECT_DIR/Resources/Embrace.icns" ] && command -v SetFile > /dev/null; then
    cp "$PROJECT_DIR/Resources/Embrace.icns" "$STAGING_DIR/.VolumeIcon.icns"
    SetFile -a C "$STAGING_DIR"
fi

# ----------------------------------
# Create the image
#
# UDZO is the read-only zlib-compressed format, and HFS+ keeps the image mountable
# on releases older than the app's own 11.0 deployment target -- an APFS image
# needs 10.13.  -srcfolder sizes the volume to fit.

mkdir -p "$OUTPUT_DIR"
rm -f "$DMG_FILE"

hdiutil create "$DMG_FILE" \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -quiet

# ----------------------------------
# Sign, and optionally notarize

# A secure timestamp is required for notarization, and an ad-hoc signature cannot
# carry one, so it is only asked for when there is a real identity.

if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --sign - "$DMG_FILE"
else
    # Apple's timestamp server refuses requests that arrive too close together, and
    # the app inside this image has just made three of them.  Build.sh rides that out
    # the same way; here it is one signature, so the retry is around codesign itself.

    SIGN_ATTEMPTS=4
    ATTEMPT=1
    RETRY_DELAY=10

    while : ; do
        set +e
        SIGN_OUTPUT=$(codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_FILE" 2>&1)
        SIGN_STATUS=$?
        set -e

        if [ "$SIGN_STATUS" = "0" ]; then
            break
        fi

        echo "$SIGN_OUTPUT" >&2

        case "$SIGN_OUTPUT" in
            *"timestamp service is not available"*) ;;
            *) exit "$SIGN_STATUS" ;;
        esac

        if [ "$ATTEMPT" -ge "$SIGN_ATTEMPTS" ]; then
            echo "Apple's timestamp server refused $SIGN_ATTEMPTS times. Try again later." >&2
            exit "$SIGN_STATUS"
        fi

        ATTEMPT=$((ATTEMPT + 1))

        echo "Apple's timestamp server was busy. Retrying ($ATTEMPT of $SIGN_ATTEMPTS)" \
             "in ${RETRY_DELAY}s."

        sleep "$RETRY_DELAY"
        RETRY_DELAY=$((RETRY_DELAY * 2))
    done
fi

if [ "$NOTARIZE" = "yes" ]; then
    # --notary-profile has already named one; otherwise fall back to the checkout's
    # own credentials, which is the usual case and the only one Archive.sh knows.

    if [ -z "$NOTARY_PROFILE" ]; then
        PRIVATE_PLIST="$PROJECT_DIR/Private/Archive.plist"

        if [ ! -f "$PRIVATE_PLIST" ]; then
            echo "Private/Archive.plist is missing and no --notary-profile was given," >&2
            echo "so there are no notarization credentials to use." >&2
            exit 1
        fi

        NOTARY_PROFILE=$(defaults read "$PRIVATE_PLIST" "keychain-profile")
    fi

    echo "Notarizing with keychain profile: $NOTARY_PROFILE"

    echo "Sending to Apple notary service. This may take several minutes."

    xcrun notarytool submit "$DMG_FILE" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    xcrun stapler staple "$DMG_FILE"
fi

# ----------------------------------
# Verify

codesign --verify --strict "$DMG_FILE"

echo
echo "Packaged EmbraceNG $VERSION ($BUILD_NUMBER) for $ARCHITECTURE"
echo "$DMG_FILE"

# spctl is the check that matters to whoever opens this: an unsigned, ad-hoc or
# un-notarized image is rejected on a Mac that downloaded it.

echo
if spctl --assess --type install "$DMG_FILE" 2> /dev/null; then
    echo "Gatekeeper: accepted."
else
    echo "Gatekeeper: rejected -- this image will be blocked on first open."

    if [ "$SIGN_IDENTITY" = "-" ]; then
        echo "It is signed ad-hoc. Use a Developer ID certificate, then --notarize."
    else
        echo "It is signed but not notarized. Run again with --notarize to hand it out."
    fi
fi
