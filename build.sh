#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

app="build/MacDisplay.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp Resources/Info.plist "$app/Contents/Info.plist"

arch="$(uname -m)"
if [[ "$arch" == arm64 ]]; then
    xcrun --sdk macosx clang -target arm64-apple-macos14.0 \
        -fmodules -fmodules-cache-path="$PWD/build/ModuleCache" \
        -I Vendor/m1ddc/headers Vendor/m1ddc/sources/*.m -framework CoreDisplay \
        -o "$app/Contents/Helpers/m1ddc"
    codesign --force --sign - "$app/Contents/Helpers/m1ddc"
    cp Vendor/m1ddc/LICENSE "$app/Contents/Resources/m1ddc-LICENSE"
fi
xcrun --sdk macosx swiftc -target "$arch-apple-macosx14.0" \
    -module-cache-path "$PWD/build/ModuleCache" -swift-version 6 -O Sources/*.swift -o "$app/Contents/MacOS/MacDisplay"
codesign --force --sign - "$app"
printf '%s\n' "$PWD/$app"
