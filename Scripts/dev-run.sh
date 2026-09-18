#!/bin/zsh
# Builds and runs the dev binary SIGNED with the stable development identity.
# Usage: Scripts/dev-run.sh [--release] [-- <args passed to Grove>]
#
# Why this exists: Grove reads Claude Code's OAuth credentials from the login
# keychain. Granting "Always Allow" records a trusted-application entry on the
# keychain item, and how that entry is keyed depends on how the binary is signed:
#
#   ad-hoc (what SwiftPM produces)  -> keyed by cdhash  -> DIES on every rebuild
#   stable identity                 -> keyed by identifier + leaf certificate
#
# So an ad-hoc dev binary re-prompts for the login password after every `swift
# build`, leaving a trail of dead ACL entries (the real items here had nine).
# Signing with the same identity AND the same identifier as dist/Grove.app makes
# the dev binary satisfy the requirement the app bundle is already trusted under,
# so the grant survives rebuilds — and may not need to be given again at all.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="debug"
if [[ "${1:-}" == "--release" ]]; then
    CONFIGURATION="release"
    shift
fi
[[ "${1:-}" == "--" ]] && shift

# Keep in sync with Scripts/build-app.sh — the ACL entry is keyed on BOTH, so a
# drift in either one silently reintroduces the prompt.
IDENTITY="Apple Development: Your Name (TEAMID)"
BUNDLE_ID="dev.artemefimov.grove3"

swift build -c "$CONFIGURATION" --product GroveApp
BINARY=".build/$CONFIGURATION/GroveApp"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$BINARY"
    echo "signed: $IDENTITY ($BUNDLE_ID)"
else
    echo "WARNING: '$IDENTITY' not found; leaving the ad-hoc signature in place." >&2
    echo "         The keychain will pin this build by cdhash and re-prompt after" >&2
    echo "         the next rebuild." >&2
fi

exec "$BINARY" "$@"
