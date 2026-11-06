#!/bin/bash
# Builds a downloadable drag-to-install DMG from build/Cumulus.app.
# Usage: ./make-dmg.sh   (run ./build.sh first, or it will)
set -euo pipefail
cd "$(dirname "$0")"

[[ -d build/Cumulus.app ]] || ./build.sh

VOL="Cumulus"
STAGE="$(mktemp -d)"
cp -R build/Cumulus.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f dist/Cumulus.dmg
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ dist/Cumulus.dmg >/dev/null
rm -rf "$STAGE"
echo "Built dist/Cumulus.dmg ($(du -sh dist/Cumulus.dmg | cut -f1))"
