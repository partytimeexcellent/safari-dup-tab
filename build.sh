#!/bin/zsh
# Builds build/SafariDupTab.app (ad-hoc signed). Used by the Homebrew formula.
set -e
cd "${0:A:h}"
APP="build/SafariDupTab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/SafariDupTab"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier io.github.partytimeexcellent.safari-dup-tab "$APP"
echo "Built $APP"
