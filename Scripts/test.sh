#!/bin/zsh
# Build the test bundles and run them with Xcode's `xctest` directly.
#
# Usage:
#   Scripts/test.sh                                   # every bundle
#   Scripts/test.sh GroveCoreTests                    # one bundle
#   Scripts/test.sh BrowKitTests LimitsStoreTests     # one XCTestCase class
#   Scripts/test.sh BrowKitTests LimitsStoreTests/testFoo
#
# See Scripts/xcode-env.sh for why `swift test` is not used.
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/xcode-env.sh

BUNDLE="${1:-}"
FILTER="${2:-}"

swift build --build-tests 2>&1 | grep -E "error:|warning:|Build complete" | awk '!seen[$0]++' || true
if [[ ${pipestatus[1]} -ne 0 ]]; then
    echo "BUILD FAILED" >&2
    exit 1
fi

# SwiftPM's newer build system puts products under .build/out; the classic one under .build/debug.
if [[ -d .build/out/Products/Debug ]]; then
    PRODUCTS=.build/out/Products/Debug
else
    PRODUCTS=.build/debug
fi

if [[ -n "$BUNDLE" ]]; then
    bundles=("$PRODUCTS/$BUNDLE.xctest")
else
    bundles=("$PRODUCTS"/*.xctest(N))
fi
if [[ ${#bundles[@]} -eq 0 ]]; then
    echo "no test bundles under $PRODUCTS" >&2
    exit 1
fi

failed=0
for b in "${bundles[@]}"; do
    if [[ ! -d "$b" ]]; then
        echo "missing bundle: $b" >&2
        failed=1
        continue
    fi
    name="${b:t:r}"
    args=()
    [[ -n "$FILTER" ]] && args=(-XCTest "$FILTER")
    out=$("$DEVELOPER_DIR/usr/bin/xctest" "${args[@]}" "$b" 2>&1)
    rc=$?
    # Failures, crashes, and the outermost "Executed N tests" summary.
    echo "$out" | grep -E "error:|Fatal error|failed \(|XCTAssert" | head -40
    summary=$(echo "$out" | grep -E "Executed [0-9]+ tests?" | tail -1)
    echo "$name (xctest exit $rc): ${summary:-no summary}"
    # xctest's exit code is not a reliable pass/fail signal (a skipped test can make it
    # non-zero); the outermost summary line is.
    if [[ -z "$summary" ]] || ! echo "$summary" | grep -qE "(with|and) 0 failures"; then
        failed=1
    fi
done
exit $failed
