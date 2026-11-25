#!/bin/zsh
# Packages build/SafariDupTab.app into build/SafariDupTab.dmg with an Applications
# shortcut, so people can drag the app into Applications. Run ./build.sh first.
set -e
cd "${0:A:h}"
[[ -d build/SafariDupTab.app ]] || { echo "Run ./build.sh first"; exit 1; }
STAGE=$(mktemp -d)
cp -R build/SafariDupTab.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f build/SafariDupTab.dmg
hdiutil create -volname "SafariDupTab" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov build/SafariDupTab.dmg >/dev/null
rm -rf "$STAGE"
echo "Built build/SafariDupTab.dmg"
