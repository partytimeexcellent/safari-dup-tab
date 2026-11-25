#!/bin/zsh
# Builds build/SafariDupTab.app (universal: Apple Silicon + Intel, ad-hoc signed).
# Used by the Homebrew formula and for the GitHub release download.
set -e
cd "${0:A:h}"
APP="build/SafariDupTab.app"
BIN="$APP/Contents/MacOS/SafariDupTab"
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macos13 main.swift -o build/SafariDupTab-arm64
swiftc -O -target x86_64-apple-macos13 main.swift -o build/SafariDupTab-x86_64
lipo -create build/SafariDupTab-arm64 build/SafariDupTab-x86_64 -output "$BIN"
rm build/SafariDupTab-arm64 build/SafariDupTab-x86_64
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier io.github.partytimeexcellent.safari-dup-tab "$APP"
echo "Built $APP"
