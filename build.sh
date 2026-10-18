#!/bin/sh
# Builds BarTimer and wraps it in an .app. macOS only (AppKit, UserNotifications).
#
#   ./build.sh           → .build/BarTimer.app
#   ./build.sh install   → copies it to ~/Applications/BarTimer.app and launches it
#
# Notifications need an .app with a bundle ID, so the bare executable is not used on its own.
set -eu
cd "$(dirname "$0")"
app=.build/BarTimer.app

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Without -target, the minimum OS becomes the version of the Mac that built it (not Info.plist's 12.0).
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" Sources/*.swift -o "$app/Contents/MacOS/BarTimer"
cp Info.plist "$app/Contents/Info.plist"
# The icon is drawn by icon.swift and packed into an .icns.
swiftc -O icon.swift -o .build/icon
rm -rf .build/AppIcon.iconset
.build/icon .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
# Extended attributes (added by some synced folders, for example) make codesign fail.
xattr -cr "$app"
codesign --force --sign - "$app"
echo "built: $(pwd)/$app"

if [ "${1:-}" = "install" ]; then
  # Opening the new copy before the old one has quit only brings the quitting one forward.
  if pkill -x BarTimer 2>/dev/null; then
    i=0
    while pgrep -x BarTimer >/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/BarTimer.app"
  ditto "$app" "$HOME/Applications/BarTimer.app"
  open "$HOME/Applications/BarTimer.app"
  echo "installed: $HOME/Applications/BarTimer.app"
fi
