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
codesign --verify --deep --strict "$app"

notarize() {
  xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$2"
}
ditto -c -k --keepParent "$app" "$out/Joinery.zip"
notarize "$out/Joinery.zip" "$app"

# ponytail: a plain disk image, the app and a link to Applications. scripts/make_dmg_background.swift's layout needs
# Finder, which a CI runner can't be relied on to drive.
stage="$out/stage"
rm -rf "$stage"
mkdir -p "$stage"
ditto "$app" "$stage/Joinery.app"
ln -s /Applications "$stage/Applications"
dmg="$out/updates/Joinery-$VERSION.dmg"
hdiutil create -volname Joinery -srcfolder "$stage" -fs HFS+ -format ULFO -ov "$dmg" -quiet
codesign --sign "Developer ID Application" --timestamp "$dmg"
notarize "$dmg" "$dmg"

# Sparkle's feed: this release added to those already published.
[ -f "$out/appcast.xml" ] && cp "$out/appcast.xml" "$out/updates/appcast.xml"
"$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" --ed-key-file "$SPARKLE_KEY_PATH" \
  --download-url-prefix "$DOWNLOAD_URL/" "$out/updates"
cp "$out/updates/appcast.xml" "$out/appcast.xml"
cp "$dmg" "$out/Joinery-$VERSION.dmg"
echo "Built Joinery $VERSION: $out/Joinery-$VERSION.dmg"
