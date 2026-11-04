#!/bin/zsh
# Unit tests for SuperbarKit (the [unit] acceptance checks in docs/STORIES.md).
set -u
here=${0:A:h}
source "$here/sdk.sh"
extra=()
# With only the Command Line Tools, SwiftPM does not pass the Testing macro plugin
# ("plugin for module 'TestingMacros' not found"). Pass it by hand.
clt=/Library/Developer/CommandLineTools
if [[ "$(xcode-select -p 2>/dev/null)" == $clt* && -d $clt/usr/lib/swift/host/plugins/testing ]]; then
  extra=(-Xswiftc -plugin-path -Xswiftc $clt/usr/lib/swift/host/plugins/testing)
fi
swift test --package-path "$here/.." --scratch-path ~/Library/Developer/Superbar/test-build "${extra[@]}" "$@"
