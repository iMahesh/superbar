#!/bin/zsh
# Makes dist/Superbar-<version>.dmg to share: Superbar.app (Apple silicon and Intel),
# a shortcut to Applications to drag it onto, and a read-me for opening it the first time.
# Doesn't touch the copy installed in ~/Applications, so its permissions stay.
#
# Usage: tools/package.sh
set -euo pipefail
here=${0:A:h:h}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

APP_DIR="$stage/Superbar" UNIVERSAL=1 "$here/build.sh"
app="$stage/Superbar/Superbar.app"
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
ln -s /Applications "$stage/Superbar/Applications"
cp "$here/tools/dmg-readme.txt" "$stage/Superbar/Read Me First.txt"

mkdir -p "$here/dist"
dmg="$here/dist/Superbar-$version.dmg"
rm -f "$dmg"
hdiutil create -volname "Superbar $version" -srcfolder "$stage/Superbar" -fs HFS+ -format UDZO -quiet "$dmg"
echo "made $dmg ($(du -h "$dmg" | cut -f1)), $(lipo -archs "$app/Contents/MacOS/Superbar")"
