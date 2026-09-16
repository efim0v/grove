# Source me: `source Scripts/xcode-env.sh`
#
# Why this exists: after a macOS/Xcode update the Xcode license must be
# re-accepted with `sudo xcodebuild -license accept`. Until that happens every
# /usr/bin shim (swift, git, xcrun, python3, …) aborts with "You have not agreed
# to the Xcode license agreements". The check lives ONLY in those shims: the
# real binaries inside Xcode.app run fine. So put them first on PATH and hand
# SwiftPM the two things it would otherwise ask the shim for — the SDK path and
# the XCTest loader paths.
#
# Harmless once the license IS accepted (same toolchain, same SDK). Note that
# `swift test` still cannot DISCOVER XCTest cases this way (SwiftPM hardcodes
# /usr/bin/xcrun for that probe); use Scripts/test.sh, which runs the built
# bundles with Xcode's `xctest` directly.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$DEVELOPER_DIR/usr/bin:$PATH"
export DYLD_FRAMEWORK_PATH="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
export DYLD_LIBRARY_PATH="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib"
