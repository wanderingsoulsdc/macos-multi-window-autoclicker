#!/bin/zsh
set -eu
cd -- "${0:A:h:h}"
source_app="$PWD/dist/Mac窗口点击器.app"
[[ -d "$source_app" ]] || { print -u2 '请先运行 zsh scripts/build-app.sh'; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")
architecture=$(lipo -archs "$source_app/Contents/MacOS/MacWindowClicker" | tr ' ' '-')
mkdir -p .build dist
stage=$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
# Package a separate copy; do not change the local application's signing identity.
ditto --norsrc --noextattr "$source_app" "$stage/Mac窗口点击器.app"
/usr/bin/strip -S "$stage/Mac窗口点击器.app/Contents/MacOS/MacWindowClicker"
codesign --force --timestamp=none --sign - --identifier local.macwindowclicker.app "$stage/Mac窗口点击器.app"
codesign --verify --deep --strict "$stage/Mac窗口点击器.app"
ln -s /Applications "$stage/Applications"
cp LICENSE "$stage/LICENSE.txt"
cat > "$stage/安装说明.txt" <<'INFO'
Mac 多窗口点击器

要求：macOS 14 或更新版本；请使用与处理器匹配的安装包。
将 Mac窗口点击器.app 拖到 Applications 后，从应用程序文件夹打开。

公开版本采用临时签名，未经过 Apple Developer ID 签名或公证，macOS 可能阻止直接打开。请自行评估来源，也可以从源码构建。
首次使用需要辅助功能权限，截取预览时额外需要屏幕录制权限。
后台点击效果依目标软件而异；已发送不代表对方已响应。
关闭主窗口后程序继续运行，从菜单栏选择退出程序才退出。

源码与反馈：https://github.com/wanderingsoulsdc/macos-multi-window-autoclicker
INFO
output="$PWD/dist/MacWindowClicker-$version-$architecture.dmg"
hdiutil create -volname "Mac Window Clicker $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$output"
hdiutil verify "$output"
(cd dist && shasum -a 256 "${output:t}" > "${output:t}.sha256")
print "DMG 已生成：$output"
