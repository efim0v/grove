#!/bin/zsh
# Builds and runs the dev binary SIGNED with the stable development identity.
# Usage: Scripts/dev-run.sh [--release] [-- <args passed to Grove>]
#
# Why this exists: macOS keys every per-app consent (Automation/Apple Events for
# cmux, and any future TCC grant) by how the binary is signed:
#
#   ad-hoc (what SwiftPM produces)  -> keyed by cdhash  -> DIES on every rebuild
#   stable identity                 -> keyed by identifier + leaf certificate
#
# Signing the dev binary with the same identity AND the same identifier as
# dist/Grove.app makes it satisfy the requirement the app bundle is already
# trusted under, so a consent survives rebuilds. (Grove no longer reads Claude
# Code's Keychain credentials — Brow does — so the login-Keychain prompts that
# first motivated this script are gone either way.)
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
# Set GROVE_SIGN_IDENTITY to your own "Apple Development: Name (TEAMID)" identity.
IDENTITY="${GROVE_SIGN_IDENTITY:-}"
BUNDLE_ID="dev.artemefimov.grove3"

swift build -c "$CONFIGURATION" --product GroveApp
BINARY=".build/$CONFIGURATION/GroveApp"

if [[ -n "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$BINARY"
    echo "signed: $IDENTITY ($BUNDLE_ID)"
else
    echo "WARNING: '$IDENTITY' not found; leaving the ad-hoc signature in place." >&2
    echo "         The keychain will pin this build by cdhash and re-prompt after" >&2
    echo "         the next rebuild." >&2
fi

exec "$BINARY" "$@"
