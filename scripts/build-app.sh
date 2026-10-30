#!/bin/zsh
set -eu
cd -- "${0:A:h:h}"
configuration="${1:-release}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
bundle="$PWD/dist/Mac多窗口连点器.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" .build/Clicker.iconset
cp "$binary_dir/MacWindowClicker" "$bundle/Contents/MacOS/.MacWindowClicker.new"
mv -f "$bundle/Contents/MacOS/.MacWindowClicker.new" "$bundle/Contents/MacOS/MacWindowClicker"
xcrun swift scripts/AppIcon.swift "$PWD/.build/Clicker.iconset"
iconutil -c icns .build/Clicker.iconset -o "$bundle/Contents/Resources/AppIcon.icns"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.macwindowclicker.app</string>
<key>CFBundleName</key><string>MultiClick for macOS</string>
<key>CFBundleDisplayName</key><string>MultiClick for macOS</string>
<key>CFBundleExecutable</key><string>MacWindowClicker</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
mkdir -p "$bundle/Contents/Resources/en.lproj" "$bundle/Contents/Resources/zh-Hans.lproj"
cat > "$bundle/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "MultiClick for macOS";
"CFBundleDisplayName" = "MultiClick for macOS";
STRINGS
cat > "$bundle/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "Mac多窗口连点器";
"CFBundleDisplayName" = "Mac多窗口连点器";
STRINGS
sign_identity="${MAC_CLICKER_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  sign_identity="$(security find-identity -v -p codesigning | sed -nE '/Apple Development:/s/^[[:space:]]*[0-9]+\) ([A-F0-9]{40}).*/\1/p' | head -n 1)"
fi
codesign --force --timestamp=none --sign "${sign_identity:--}" --identifier local.macwindowclicker.app "$bundle"
codesign --verify --deep --strict "$bundle"
print "应用已生成：$bundle"
