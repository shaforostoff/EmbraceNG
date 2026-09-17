#!/bin/sh
#
# Syncs Vendor/bpmcore and Vendor/pffft from a foo_rubato checkout, and checks
# that what is here still matches the revision Vendor/PROVENANCE.md claims.
#
# Neither directory is developed in this tree.  That is easy to write down and
# easy to forget a year later, so this script is the thing that notices: it
# reads the pin out of PROVENANCE.md, compares every vendored file against it,
# and says which ones have drifted.  A local fix to a vendored file shows up as
# "patched", which is the warning that it is about to be lost.
#
# Usage: Build/SyncVendor.sh [--check | --log | --sync] [--rev <revision>]
#                            [--repo <path-to-foo_rubato>]
#
#   --check   (the default) Compare Vendor against the pinned revision and
#             exit non-zero on any difference.  Needs the upstream repo only
#             for bpmcore; pffft is checked against the sha256 sums that
#             PROVENANCE.md already records, so that half works anywhere.
#
#   --log     List the upstream commits that have touched the vendored paths
#             since the pin.  This is the "what would a sync bring over"
#             question, and it is worth asking before answering it.
#
#   --sync    Copy the files across and move the pin to match.  Takes them out
#             of `git show <rev>:<path>` rather than off the upstream working
#             tree, so what lands here is exactly the named revision whatever
#             state that checkout happens to be in.
#
# --rev names the revision to check or sync against; it defaults to the pin for
# --check and to the upstream default branch's tip for --log and --sync.  The
# repo defaults to ../foo_rubato beside this one, or $FOO_RUBATO_REPO.
#
# CMakeLists.txt is deliberately not vendored: it describes a build this
# project does not use, and what it settles the Xcode project settles instead.
# Every other file under bpmcore/ comes across.  If upstream adds one, --check
# and --sync both say so in as many words -- a new source file also has to be
# added to the Worker target by hand, because the project lists sources one by
# one rather than referencing the folder.
#
# The usual sequence for taking upstream's work:
#
#     Build/SyncVendor.sh --log            what is there
#     Build/SyncVendor.sh --sync           take it, and move the pin
#     Build/Build.sh                       it still builds
#     Tests/run-bpm-analyzer-tests.sh      it still measures
#
# and then read the diff, because a sync is a commit like any other.

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROVENANCE="$ROOT/Vendor/PROVENANCE.md"

REPO=${FOO_RUBATO_REPO:-"$ROOT/../foo_rubato"}
MODE=check
REV=

# bpmcore comes over whole, less the build file.  pffft is the two files
# upstream ships; COPYING beside them is ours, lifted out of the header.
BPMCORE_SKIP="CMakeLists.txt"
PFFFT_FILES="pffft.c pffft.h"

while [ $# -gt 0 ]; do
    case "$1" in
    --check) MODE=check;  shift ;;
    --log)   MODE=log;    shift ;;
    --sync)  MODE=sync;   shift ;;
    --rev)   REV="$2";    shift 2 ;;
    --repo)  REPO="$2";   shift 2 ;;
    -h|--help)
        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *)
        echo "SyncVendor: unknown argument '$1'" >&2
        exit 2 ;;
    esac
done

if [ ! -f "$PROVENANCE" ]; then
    echo "SyncVendor: no Vendor/PROVENANCE.md -- nothing records what is vendored here" >&2
    exit 2
fi


# --- the pin, which lives in PROVENANCE.md and nowhere else ------------------

# The bpmcore revision is the one on the line after the foo_rubato URL.  pffft
# carries a bitbucket revision of its own further down, which is why this is a
# state machine and not a grep for the first hash in the file.
pinned_revision()
{
    awk '
        /foo_rubato/            { seen = 1 }
        seen && /^[ \t]*revision[ \t]+[0-9a-f]{40}/ {
            sub(/^[ \t]*revision[ \t]+/, "");
            sub(/[,[:space:]].*$/, "");
            print; exit
        }
    ' "$PROVENANCE"
}

pinned_sha()
{
    awk -v want="$1" '
        $1 == "sha256" && $3 == want { print $2; exit }
    ' "$PROVENANCE"
}

PIN=$(pinned_revision)

if [ -z "$PIN" ]; then
    echo "SyncVendor: PROVENANCE.md does not name a bpmcore revision" >&2
    exit 2
fi


# --- the upstream repo, needed for everything except the pffft sums ----------

need_repo()
{
    if [ ! -d "$REPO/.git" ]; then
        echo "SyncVendor: no git repository at $REPO" >&2
        echo "            pass --repo <path>, or set FOO_RUBATO_REPO" >&2
        exit 2
    fi

    if ! git -C "$REPO" cat-file -e "$PIN^{commit}" 2>/dev/null; then
        echo "SyncVendor: $REPO has no commit $PIN" >&2
        echo "            the pin is from that repository; fetch it, or point --repo elsewhere" >&2
        exit 2
    fi
}

upstream_files()   # revision -> the bpmcore files that revision carries
{
    git -C "$REPO" ls-tree --name-only "$1" bpmcore/ | sed 's|^bpmcore/||' | while read -r name; do
        skip=
        for s in $BPMCORE_SKIP; do [ "$name" = "$s" ] && skip=1; done
        [ -z "$skip" ] && echo "$name"
    done
}


# --- --log -------------------------------------------------------------------

if [ "$MODE" = log ]; then
    need_repo
    TO=${REV:-$(git -C "$REPO" rev-parse HEAD)}

    echo "pinned at $(git -C "$REPO" log -1 --format='%h %ad  %s' --date=short "$PIN")"
    echo

    COUNT=$(git -C "$REPO" rev-list --count "$PIN..$TO" -- bpmcore/ pffft/ 2>/dev/null || echo 0)

    if [ "$COUNT" = 0 ]; then
        echo "nothing has touched bpmcore/ or pffft/ since."
    else
        echo "$COUNT commit(s) touching bpmcore/ or pffft/ since:"
        echo
        git -C "$REPO" log --reverse --format='  %h %ad  %s' --date=short "$PIN..$TO" -- bpmcore/ pffft/
        echo
        echo "files:"
        git -C "$REPO" diff --stat "$PIN..$TO" -- bpmcore/ pffft/ | sed 's/^/  /'
    fi
    exit 0
fi


# --- --check -----------------------------------------------------------------

DRIFT=0

check_bpmcore()
{
    REF=${REV:-$PIN}
    need_repo

    echo "bpmcore  against $(git -C "$REPO" rev-parse --short "$REF")"

    for name in $(upstream_files "$REF"); do
        here="$ROOT/Vendor/bpmcore/$name"

        if [ ! -f "$here" ]; then
            echo "  MISSING   $name  (upstream has it, we do not -- and the Worker target lists sources one by one)"
            DRIFT=1
            continue
        fi

        a=$(git -C "$REPO" show "$REF:bpmcore/$name" | shasum -a 256 | cut -d' ' -f1)
        b=$(shasum -a 256 < "$here" | cut -d' ' -f1)

        if [ "$a" = "$b" ]; then
            echo "  ok        $name"
        else
            echo "  PATCHED   $name  (differs from the pinned revision -- a sync will overwrite it)"
            DRIFT=1
        fi
    done

    # The other direction: something here that upstream does not have, which is
    # either a file upstream deleted or one this tree invented.
    for here in "$ROOT"/Vendor/bpmcore/*; do
        name=$(basename "$here")
        if ! upstream_files "$REF" | grep -qx "$name"; then
            echo "  EXTRA     $name  (not in the pinned revision)"
            DRIFT=1
        fi
    done
}

check_pffft()
{
    echo "pffft    against the sums in PROVENANCE.md"

    for name in $PFFFT_FILES; do
        want=$(pinned_sha "$name")
        here="$ROOT/Vendor/pffft/$name"

        if [ -z "$want" ]; then
            echo "  UNPINNED  $name  (PROVENANCE.md records no sha256 for it)"
            DRIFT=1
        elif [ ! -f "$here" ]; then
            echo "  MISSING   $name"
            DRIFT=1
        elif [ "$(shasum -a 256 < "$here" | cut -d' ' -f1)" = "$want" ]; then
            echo "  ok        $name"
        else
            echo "  PATCHED   $name  (differs from the recorded sum)"
            DRIFT=1
        fi
    done
}

if [ "$MODE" = check ]; then
    check_bpmcore
    echo
    check_pffft
    echo

    if [ "$DRIFT" = 0 ]; then
        echo "Vendor matches its provenance."
        exit 0
    fi

    echo "Vendor does NOT match its provenance."
    echo "Either the difference belongs upstream -- send it there and sync back --"
    echo "or PROVENANCE.md should say what was changed here and why."
    exit 1
fi


# --- --sync ------------------------------------------------------------------

need_repo

TO=${REV:-$(git -C "$REPO" rev-parse HEAD)}
TO=$(git -C "$REPO" rev-parse "$TO")
DATE=$(git -C "$REPO" log -1 --format=%ad --date=short "$TO")

if [ "$TO" = "$PIN" ]; then
    echo "Already at $(git -C "$REPO" rev-parse --short "$TO") -- syncing anyway, to undo any local edit."
fi

echo "syncing bpmcore to $(git -C "$REPO" rev-parse --short "$TO")  $DATE"

NEW=
for name in $(upstream_files "$TO"); do
    here="$ROOT/Vendor/bpmcore/$name"
    [ -f "$here" ] || NEW="$NEW $name"

    git -C "$REPO" show "$TO:bpmcore/$name" > "$here"
done

# A file upstream dropped stays here until somebody says so: deleting sources
# out from under a project file that references them by path turns a sync into
# a build that cannot be opened.
for here in "$ROOT"/Vendor/bpmcore/*; do
    name=$(basename "$here")
    if ! upstream_files "$TO" | grep -qx "$name"; then
        echo "  note: $name is no longer upstream, and has been left alone"
        echo "        remove it here and from the Worker target when you are sure"
    fi
done

for name in $PFFFT_FILES; do
    git -C "$REPO" show "$TO:pffft/$name" > "$ROOT/Vendor/pffft/$name"
done

# Move the pin.  Both halves of it: the revision and date for bpmcore, and the
# sha256 lines for pffft, which is pinned by content because it comes from
# bitbucket rather than from this repository.
PFFFT_C_SHA=$(shasum -a 256 < "$ROOT/Vendor/pffft/pffft.c" | cut -d' ' -f1)
PFFFT_H_SHA=$(shasum -a 256 < "$ROOT/Vendor/pffft/pffft.h" | cut -d' ' -f1)

awk -v rev="$TO" -v date="$DATE" -v csha="$PFFFT_C_SHA" -v hsha="$PFFFT_H_SHA" '
    /foo_rubato/ { seen = 1 }
    seen && !done && /^[ \t]*revision[ \t]+[0-9a-f]{40}/ {
        match($0, /^[ \t]*/);
        print substr($0, 1, RLENGTH) "revision " rev ", " date;
        done = 1;
        next
    }
    $1 == "sha256" && $3 == "pffft.c" { sub($2, csha); print; next }
    $1 == "sha256" && $3 == "pffft.h" { sub($2, hsha); print; next }
    { print }
' "$PROVENANCE" > "$PROVENANCE.new" && mv "$PROVENANCE.new" "$PROVENANCE"

echo
echo "pin moved to $(git -C "$REPO" rev-parse --short "$TO"), $DATE"

if [ -n "$NEW" ]; then
    echo
    echo "NEW FILES:$NEW"
    echo "  These are not in the Xcode project.  The Worker target lists Vendor"
    echo "  sources one by one, so a new .cpp or .c will not be compiled and a"
    echo "  new .h will not show in the navigator until it is added by hand."
fi

echo
echo "what came across:"
git -C "$REPO" log --reverse --format='  %h %ad  %s' --date=short "$PIN..$TO" -- bpmcore/ pffft/ 2>/dev/null || true
echo
echo "PROVENANCE.md now names the new revision, but only the prose around it"
echo "knows why any of this is here -- read it and see if it is still true."
