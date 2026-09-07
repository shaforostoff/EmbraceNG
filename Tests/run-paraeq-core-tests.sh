#!/bin/bash
#
# Builds and runs the checks on the portable parametric EQ core.  Headless and
# framework-free -- no window server, no audio device, no Xcode target -- so
# this runs anywhere clang++ does, including over a plain SSH login.
#
# Runs twice: once at -O2, which is how the app ships it, and once at -O0 with
# the address and undefined-behaviour sanitizers, which is where an out-of-range
# stage index or a signed overflow in the design would show up.
#
# Usage: Tests/run-paraeq-core-tests.sh

set -uo pipefail

cd "$(dirname "$0")/.."

SRC="Tests/ParaEQCoreTests.cpp Source/paraeq_core.cpp"
OUT="${TMPDIR:-/tmp}/paraeq-core-tests"

STATUS=0

run_pass() {
    local label="$1"; shift

    echo "### building ($label)"
    clang++ -o "$OUT" $SRC \
        -std=c++17 -g -Wall -Wextra -Wshadow -Wconversion \
        -ISource "$@" \
        || { echo "build failed"; exit 1; }

    echo
    echo "### running ($label)"
    "$OUT" || STATUS=1
    echo
}

run_pass "-O2, as shipped" -O2
run_pass "-O0, asan + ubsan" -O0 -fsanitize=address,undefined -fno-omit-frame-pointer

if [ "$STATUS" -eq 0 ]; then
    echo "### passed"
else
    echo "### FAILURES -- see above"
fi
exit "$STATUS"
