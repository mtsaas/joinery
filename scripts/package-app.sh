#!/bin/sh
# Builds a release of Joinery for GitHub: signed with a Developer ID, notarized, in a disk image, and added to
# Sparkle's update feed. The release workflow runs it; everything it needs comes from the environment.
#
#   VERSION            the release, such as 1.2.0
#   TEAM_ID            the Apple developer team that signs it
#   NOTARY_KEY_PATH    an App Store Connect API key (.p8), with NOTARY_KEY_ID and NOTARY_ISSUER, to notarize
#   SPARKLE_KEY_PATH   Sparkle's private EdDSA key (generate_keys -x), to sign the update
#   FEED_URL           where released copies look for updates
#   DOWNLOAD_URL       where this release's disk image will be downloaded from, without the file name
#
# It needs dmgbuild (pipx install dmgbuild).
#
# Writes build/release/Joinery-$VERSION.dmg and build/release/appcast.xml, which starts from build/release/appcast.xml
# if it's there: the feed as last published.
set -eu
cd "$(dirname "$0")/.."
: "${VERSION:?}" "${TEAM_ID:?}" "${NOTARY_KEY_PATH:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER:?}"
: "${SPARKLE_KEY_PATH:?}" "${FEED_URL:?}" "${DOWNLOAD_URL:?}"
out="$PWD/build/release"
derived="$PWD/build/derived"
mkdir -p "$out/updates"
packages="-packageCachePath $derived/package-cache"

xcodebuild -resolvePackageDependencies -project Joinery.xcodeproj -scheme Joinery -derivedDataPath "$derived" $packages -quiet
# One build number per commit, so each release's is higher than the last, as Sparkle needs.
xcodebuild -project Joinery.xcodeproj -scheme Joinery -configuration Release -derivedDataPath "$derived" \
  -archivePath "$out/Joinery.xcarchive" $packages -quiet archive \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS=--timestamp MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  SPARKLE_FEED_URL="$FEED_URL"
app="$out/Joinery.app"
rm -rf "$app"
ditto "$out/Joinery.xcarchive/Products/Applications/Joinery.app" "$app"
# Sparkle's helpers come signed by Sparkle, and the archive doesn't re-sign them; notarization needs every one signed
# with the Developer ID, the hardened runtime and a timestamp. Inside out, as Sparkle's documentation does it, then the
# app again, keeping its entitlements.
sign() { codesign --force --sign "Developer ID Application" --options runtime --timestamp "$@"; }
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for xpc in "$sparkle"/Versions/B/XPCServices/*.xpc; do [ -e "$xpc" ] && sign --preserve-metadata=entitlements "$xpc"; done
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign --preserve-metadata=entitlements "$app"
codesign --verify --deep --strict "$app"

# Notarizes and staples; if Apple turns it down, prints why.
notarize() {
  set -- "$1" "$2" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
  result=$(xcrun notarytool submit "$1" "$3" "$4" "$5" "$6" "$7" "$8" --wait --output-format json)
  echo "$result"
  field() { echo "$result" | python3 -c "import json, sys; print(json.load(sys.stdin)['$1'])"; }
  if [ "$(field status)" != Accepted ]; then
    xcrun notarytool log "$(field id)" "$3" "$4" "$5" "$6" "$7" "$8"
    exit 1
  fi
  xcrun stapler staple "$2"
}
ditto -c -k --keepParent "$app" "$out/Joinery.zip"
notarize "$out/Joinery.zip" "$app"

# The disk image: the app, a link to Applications, and the background, laid out by dmgbuild (scripts/dmg.py), which
# writes the window's layout itself rather than asking Finder to.
swift scripts/make_dmg_background.swift "$out/background.png" 1
swift scripts/make_dmg_background.swift "$out/background@2x.png" 2
dmg="$out/updates/Joinery-$VERSION.dmg"
dmgbuild -s scripts/dmg.py -D app="$app" -D background="$out/background.png" Joinery "$dmg"
codesign --sign "Developer ID Application" --timestamp "$dmg"
notarize "$dmg" "$dmg"

# Sparkle's feed: this release added to those already published.
[ -f "$out/appcast.xml" ] && cp "$out/appcast.xml" "$out/updates/appcast.xml"
"$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" --ed-key-file "$SPARKLE_KEY_PATH" \
  --download-url-prefix "$DOWNLOAD_URL/" "$out/updates"
cp "$out/updates/appcast.xml" "$out/appcast.xml"
cp "$dmg" "$out/Joinery-$VERSION.dmg"
echo "Built Joinery $VERSION: $out/Joinery-$VERSION.dmg"
