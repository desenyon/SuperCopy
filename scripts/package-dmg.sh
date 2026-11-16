#!/bin/zsh
# Creates a compressed drag-to-Applications disk image without opening Finder.
set -euo pipefail
export EDITOR=vim VISUAL=vim GIT_EDITOR=vim
cd "${0:A:h:h}"
build_args=()
notary_profile=""
while (( $# )); do
  case "$1" in
    --universal|--ad-hoc) build_args+=("$1") ;;
    --notarize)
      if (( $# < 2 )) || [[ -z "$2" ]]; then print -u2 "--notarize requires a keychain profile"; exit 2; fi
      notary_profile="$2"; shift ;;
    *) print -u2 "Usage: $0 [--universal] [--ad-hoc] [--notarize KEYCHAIN_PROFILE]"; exit 2 ;;
  esac
  shift
done
if ! command -v uv >/dev/null; then print -u2 "DMG layout generation needs uv. Install it with: brew install uv"; exit 1; fi
identity="${SUPERCOPY_SIGNING_IDENTITY:-}"
if [[ -n "$notary_profile" ]]; then
  if [[ "$identity" != 'Developer ID Application:'* ]] || (( ${build_args[(Ie)--ad-hoc]} )); then
    print -u2 "Notarization requires SUPERCOPY_SIGNING_IDENTITY='Developer ID Application: …' and no --ad-hoc flag."; exit 2
  fi
fi
if (( ${build_args[(Ie)--ad-hoc]} )); then identity=""; fi
./scripts/build.sh "${build_args[@]}"
app="$PWD/dist/SuperCopy.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
# Version metadata is part of the output filename, never a shell command or path.
if [[ "$version" != <->.<->.<-> ]]; then print -u2 "Invalid bundle version: $version"; exit 1; fi
architectures=$(lipo -archs "$app/Contents/MacOS/SuperCopy")
if [[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]]; then
  flavor=universal
else
  flavor="${architectures// /-}"
fi
if [[ "$identity" == 'Developer ID Application:'* ]]; then channel=""; else channel="-development"; fi
output="$PWD/dist/SuperCopy-${version}-${flavor}${channel}.dmg"
work=$(mktemp -d "${TMPDIR:-/tmp}/SuperCopy-dmg.XXXXXX")
mounted=false
cleanup() {
  if $mounted; then
    if ! hdiutil detach "$work/mount" -quiet; then
      print -u2 "Could not detach $work/mount; temporary files kept at $work"; return
    fi
  fi
  rm -rf "$work"
}
trap cleanup EXIT
if [[ -n "$notary_profile" ]]; then
  ditto -c -k --keepParent "$app" "$work/notarization.zip"
  xcrun notarytool submit "$work/notarization.zip" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi
mkdir -p "$work/stage" "$work/mount"
ditto "$app" "$work/stage/SuperCopy.app"
ln -s /Applications "$work/stage/Applications"
hdiutil create -quiet -fs HFS+ -format UDRW -volname SuperCopy -srcfolder "$work/stage" "$work/writable.dmg"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$work/mount" "$work/writable.dmg"
mounted=true
mkdir -p "$work/mount/.background"
swift scripts/make-dmg-background.swift "$work/mount/.background/installer.png"
uv run --script scripts/dmg-layout.py "$work/mount"
cp Resources/AppIcon.icns "$work/mount/.VolumeIcon.icns"
if setfile=$(xcrun --find SetFile 2>/dev/null); then "$setfile" -a C "$work/mount"; fi
hdiutil detach -quiet "$work/mount"
mounted=false
hdiutil convert -quiet "$work/writable.dmg" -format UDZO -imagekey zlib-level=9 -o "$work/finished.dmg"
if [[ "$identity" == 'Developer ID Application:'* ]]; then
  codesign --force --timestamp --sign "$identity" "$work/finished.dmg"
fi
if [[ -n "$notary_profile" ]]; then
  xcrun notarytool submit "$work/finished.dmg" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$work/finished.dmg"
  xcrun stapler validate "$work/finished.dmg"
fi
hdiutil verify "$work/finished.dmg"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$work/mount" "$work/finished.dmg"
mounted=true
codesign --verify --strict --verbose=2 "$work/mount/SuperCopy.app"
[[ "$(readlink "$work/mount/Applications")" == /Applications ]]
cmp "$app/Contents/MacOS/SuperCopy" "$work/mount/SuperCopy.app/Contents/MacOS/SuperCopy"
[[ -s "$work/mount/.DS_Store" && -s "$work/mount/.background/installer.png" ]]
hdiutil detach -quiet "$work/mount"
mounted=false
mv "$work/finished.dmg" "$output"
(cd dist && shasum -a 256 "${output:t}" > "${output:t}.sha256")
print "Created $output"
print "Checksum $output.sha256"
if [[ -z "$notary_profile" ]]; then print "Not notarized. This image has not passed the public-download Gatekeeper release checks."; fi
