#!/bin/zsh
# Builds Superbar and installs it to ~/Applications/Superbar.app.
# Build products live in ~/Library/Developer/Superbar, outside the repo
# (and outside Dropbox or iCloud, which would try to sync them).
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then quit the running copy and open the new one
#        APP_DIR=dir ./build.sh  build the app into another folder (tools/package.sh)
#        UNIVERSAL=1 ./build.sh  also build for Intel Macs, as one binary
set -euo pipefail
here=${0:A:h}
name="Superbar"
scratch="$HOME/Library/Developer/$name/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug
source "$here/tools/sdk.sh"

# Sign with your Apple Development certificate when you have one (Xcode >
# Settings > Accounts). Otherwise sign ad hoc, which is fine for your own Mac.
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-

swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error|warning|Build complete" | grep -v "^\[" || true
bin="$scratch/$config/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }
if [[ -n "${UNIVERSAL:-}" ]]; then
  # The Command Line Tools can't build both at once (that needs Xcode), so build Intel
  # separately and join the two with lipo.
  swift build -c $config --package-path "$here" --scratch-path "$scratch-x86_64" --triple x86_64-apple-macosx26.0 2>&1 | grep -E "error" | head -20 || true
  [[ -x "$scratch-x86_64/$config/$name" ]] || { echo "Intel build failed"; exit 1; }
  lipo -create "$bin" "$scratch-x86_64/$config/$name" -output "$scratch/$name-universal"
  bin="$scratch/$name-universal"
fi
# swift build can report success while an edited file failed to compile. Catch that.
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" | head -1)
if [[ -n "$stale" ]]; then
  echo "build failed: binary is older than $stale"
  swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error" | head -20
  exit 1
fi

app="${APP_DIR:-$HOME/Applications}/$name.app"
mkdir -p "${app:h}"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
# The icon: Icon/AppIcon.icon -> Resources/Assets.car + AppIcon.icns, rebuilt when it changed.
# actool ships with Xcode only; with just the Command Line Tools the app keeps the generic icon.
if [[ -d "$here/Icon/AppIcon.icon" ]] && xcrun -f actool >/dev/null 2>&1; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
else
  # No actool: a flat AppIcon.icns drawn by the app itself (tools/make_flat_icon.sh).
  icns="$here/Resources/AppIcon.icns"
  if [[ ! -f "$icns" || "$here/Sources/Superbar/UI/AppIconArt.swift" -nt "$icns" || "$here/Sources/Superbar/UI/TaskbarView.swift" -nt "$icns" ]]; then
    "$here/tools/make_flat_icon.sh" "$bin"
  fi
  cp -X "$icns" "$app/Contents/Resources/"
  # CFBundleIconName points at Assets.car, which only actool makes. Without it, use the .icns.
  plutil -remove CFBundleIconName "$app/Contents/Info.plist" 2>/dev/null || true
fi
touch "$app"   # Finder and Launch Services pick up a changed icon
xattr -cr "$app"
codesign --force --sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
echo "installed $app (signed: ${identity})"

if [[ " $* " == *" --open "* ]]; then
  osascript -e "quit app \"$name\"" 2>/dev/null || true
  sleep 0.5
  open "$app"
fi
