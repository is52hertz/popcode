#!/bin/sh
# Builds .build/popcode.app. popcode must run from an app bundle: only then does macOS register the
# process under its bundle identifier, which WeType's voice input needs to commit long dictation.
# Extra arguments go to `swift build` (e.g. --arch arm64 --arch x86_64).
set -e
cd "$(dirname "$0")/.."
swift build -c release "$@"
bin=$(swift build -c release "$@" --show-bin-path)
app=.build/popcode.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Sources/popcode/Info.plist "$app/Contents/Info.plist"
cp "$bin/popcode" "$app/Contents/MacOS/popcode"
codesign --force --sign - "$app"
echo "$PWD/$app"
