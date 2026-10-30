#!/bin/zsh
set -eu
cd -- "${0:A:h:h}"
swift build
zsh Validation/build.sh
object_dir="$PWD/Validation/build/IntegrationCore"
mkdir -p "$object_dir"
xcrun swiftc -parse-as-library -swift-version 5 -whole-module-optimization \
  -emit-module -emit-object -module-name ClickerCore Sources/ClickerCore/*.swift \
  -emit-module-path "$object_dir/ClickerCore.swiftmodule" -o "$object_dir/ClickerCore.o"
xcrun swiftc -parse-as-library -swift-version 5 -I "$object_dir" \
  "$object_dir/ClickerCore.o" \
  Sources/MacWindowClicker/Services/ClickEmitter.swift \
  Sources/MacWindowClicker/Services/WindowCatalog.swift \
  Sources/MacWindowClicker/Services/RunEngine.swift \
  "$PWD/Validation/ProductionIntegration.swift" \
  -framework AppKit -framework ApplicationServices -o Validation/build/production-integration
bundle="Validation/build/BackgroundClickProbe.app"
cp Validation/build/production-integration "$bundle/Contents/MacOS/.new"
mv -f "$bundle/Contents/MacOS/.new" "$bundle/Contents/MacOS/BackgroundClickProbe"
sign_identity="$(security find-identity -v -p codesigning | sed -nE '/Apple Development:/s/^[[:space:]]*[0-9]+\) ([A-F0-9]{40}).*/\1/p' | head -n 1)"
codesign --force --timestamp=none --sign "${sign_identity:--}" --identifier local.macwindowclicker.BackgroundClickProbe "$bundle"
