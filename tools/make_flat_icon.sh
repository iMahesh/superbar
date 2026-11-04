#!/bin/zsh
# Renders the app icon from AppIconArt (Sources/Superbar/UI/AppIconArt.swift) and packs it
# into Resources/AppIcon.icns with iconutil, which ships with macOS. build.sh runs this when
# Xcode's actool is missing (Command Line Tools only) and the drawing changed.
# Usage: tools/make_flat_icon.sh <path to the built Superbar binary>
set -euo pipefail
here=${0:A:h}
repo=${here:h}
bin=${1:?usage: make_flat_icon.sh <Superbar binary>}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$bin" --render-icon "$work"
mkdir -p "$repo/Resources"
iconutil -c icns "$work/AppIcon.iconset" -o "$repo/Resources/AppIcon.icns"
cp "$work/AppIcon.iconset/icon_512x512@2x.png" "$repo/Resources/AppIcon-1024.png"
echo "wrote Resources/AppIcon.icns"
