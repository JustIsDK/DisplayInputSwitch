#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app="$PWD/build/显示器切换.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$PWD/build/module-cache"

xcrun clang -arch arm64 -fmodules -fmodules-cache-path="$PWD/build/module-cache" \
  -mmacosx-version-min=14.0 -I vendor/m1ddc/headers \
  Sources/input-ddc.m vendor/m1ddc/sources/ioregistry.m \
  -framework Foundation -framework IOKit -framework CoreGraphics -framework CoreDisplay \
  -o "$app/Contents/Resources/input-ddc"

xcrun swiftc -parse-as-library -O -module-cache-path "$PWD/build/module-cache" \
  -target arm64-apple-macosx14.0 Sources/Configuration.swift Sources/SoftwareDimming.swift Sources/BrightnessHUD.swift Sources/BrightnessKeys.swift Sources/Hotkeys.swift Sources/DisplayInputSwitch.swift \
  -o "$app/Contents/MacOS/DisplayInputSwitch"

cp Info.plist "$app/Contents/Info.plist"
cp vendor/m1ddc/LICENSE "$app/Contents/Resources/m1ddc-LICENSE.txt"
cp vendor/MonitorControl/LICENSE "$app/Contents/Resources/MonitorControl-LICENSE.txt"
codesign --force --sign - "$app/Contents/Resources/input-ddc"
codesign --force --sign - "$app"
"$app/Contents/Resources/input-ddc" --self-test
print -r -- "$app"
