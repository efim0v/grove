#!/bin/zsh
# Measures test coverage and enforces the project's coverage policy (see COVERAGE.md).
#
# The GATE is the pure/mockable LOGIC layer (services, models, presentation, app
# state) and must be >= 95%. SwiftUI views are validated by the snapshot/render
# tests; real cmux/osascript/socket adapters and the NSApplication entry point are
# validated by manual/integration testing — both are excluded from the gate.
set -euo pipefail
cd "$(dirname "$0")/.."

swift test --enable-code-coverage
PROF=$(find .build -name default.profdata -path '*debug*' | head -1)
BIN=$(find .build -name GrovePackageTests -path '*debug*xctest*' -type f | head -1)

# Excluded from the logic gate (validated by other means, not unit coverage).
GATE_IGNORE='Tests|\.build|GroveAppKit/Views/|GroveMenuBarApp|DesignSystem|GroveLog|Snapshot/SnapshotMode|Services/Cmux|Diagnostics/CmuxProbe'

cover() {
    xcrun llvm-cov report "$BIN" -instr-profile="$PROF" \
        -ignore-filename-regex="$1" --show-region-summary=false 2>/dev/null \
        | grep TOTAL | awk '{n=NF; v=$(n-3); gsub("%","",v); print v}'
}

ALL=$(cover 'Tests|\.build')
GATE=$(cover "$GATE_IGNORE")
echo "Overall line coverage:    ${ALL}%"
echo "Logic-gate coverage:      ${GATE}%   (policy: >= 95%)"

awk -v g="$GATE" 'BEGIN { exit (g+0 >= 95) ? 0 : 1 }' \
    && echo "GATE PASS" || { echo "GATE FAIL"; exit 1; }
