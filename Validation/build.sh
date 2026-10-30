#!/bin/zsh
set -eu
cd -- "${0:A:h}"
mkdir -p build
# Prefer the Mac's existing development certificate, so normal rebuilds retain
# the same signing identity instead of a new ad-hoc code hash each time.
sign_identity="${MAC_CLICKER_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  sign_identity="$(security find-identity -v -p codesigning | sed -nE '/Apple Development:/s/^[[:space:]]*[0-9]+\) ([A-F0-9]{40}).*/\1/p' | head -n 1)"
fi
sign_identity="${sign_identity:--}"
xcrun swiftc -swift-version 5 "$PWD/BackgroundClickProbe.swift" -o build/probe -framework AppKit -framework ApplicationServices
for name in BackgroundClickProbe ProbeTarget; do
  bundle="build/$name.app"
  mkdir -p "$bundle/Contents/MacOS"
  cp build/probe "$bundle/Contents/MacOS/$name"
  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.macwindowclicker.$name</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>后台点击验证</string>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  codesign --force --timestamp=none --sign "$sign_identity" --identifier "local.macwindowclicker.$name" "$bundle"
done
