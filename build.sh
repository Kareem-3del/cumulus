#!/bin/bash
# Builds Cumulus.app (release, stripped, ad-hoc signed).
#   ./build.sh            -> build/Cumulus.app
#   ./build.sh install    -> also copies it to /Applications
#   UNIVERSAL=1 ./build.sh -> arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch "$(uname -m)")
[[ "${UNIVERSAL:-0}" == "1" ]] && ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Cumulus"

APP=build/Cumulus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cumulus"
strip -x "$APP/Contents/MacOS/Cumulus"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Bake the SoundCloud app key into the bundle so users only click "Log in".
# Put SC_CLIENT_ID / SC_CLIENT_SECRET (optional SC_REDIRECT_URI) in secrets.env or the environment.
[[ -f secrets.env ]] && set -a && source secrets.env && set +a
PB=/usr/libexec/PlistBuddy
if [[ -n "${SC_CLIENT_ID:-}" && -n "${SC_CLIENT_SECRET:-}" ]]; then
  $PB -c "Add :SCClientID string $SC_CLIENT_ID" "$APP/Contents/Info.plist"
  $PB -c "Add :SCClientSecret string $SC_CLIENT_SECRET" "$APP/Contents/Info.plist"
  [[ -n "${SC_REDIRECT_URI:-}" ]] && $PB -c "Add :SCRedirectURI string $SC_REDIRECT_URI" "$APP/Contents/Info.plist"
  echo "Built-in SoundCloud key: yes (one-click login)"
else
  echo "Built-in SoundCloud key: NO - add secrets.env to enable one-click login"
fi

if [[ ! -f build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "install" ]]; then
  rm -rf /Applications/Cumulus.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Cumulus.app"
fi
