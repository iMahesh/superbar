# Sourced by build.sh and tools/test.sh.
# The macOS 27 SDK in the Command Line Tools makes SwiftUI's @State a macro but
# ships no plugin for it ("plugin for module 'SwiftUIMacros' not found"), and the
# Testing macros fail the same way. Build against the newest 26.x SDK there.
# With Xcode selected, or SDKROOT already set, nothing changes.
if [[ -z "${SDKROOT:-}" ]] && [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* ]]; then
  sdk=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
  [[ -n "$sdk" ]] && export SDKROOT=$sdk
fi
