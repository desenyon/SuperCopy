#!/bin/zsh
set -euo pipefail
export EDITOR=vim VISUAL=vim GIT_EDITOR=vim
cd "${0:A:h:h}"
build_args=(-c release)
install=false
ad_hoc=false
for arg in "$@"; do
  case "$arg" in
    --universal) build_args+=(--arch arm64 --arch x86_64) ;;
    --install) install=true ;;
    --ad-hoc) ad_hoc=true ;;
    *) print -u2 "Usage: $0 [--universal] [--ad-hoc] [--install]"; exit 2 ;;
  esac
done
swift build "${build_args[@]}"
binary_dir=$(swift build "${build_args[@]}" --show-bin-path)
bundle="$PWD/dist/SuperCopy.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/SuperCopy" "$bundle/Contents/MacOS/SuperCopy"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/PrivacyInfo.xcprivacy "$bundle/Contents/Resources/"
plutil -lint "$bundle/Contents/Info.plist" "$bundle/Contents/Resources/PrivacyInfo.xcprivacy"
identity="${SUPERCOPY_SIGNING_IDENTITY:-}"
if $ad_hoc; then
  codesign --force --options runtime --sign - "$bundle"
elif [[ -n "$identity" ]]; then
  codesign --force --options runtime --timestamp --sign "$identity" "$bundle"
else
  # A stable identity keeps local Accessibility permission across rebuilds.
  identity=$(./scripts/signing-identity.sh 2>/dev/null || true)
  if [[ -z "$identity" ]] || ! codesign --force --options runtime --sign "$identity" "$bundle" 2>/dev/null; then
    print "Local identity unavailable; using ad-hoc signing. Accessibility may need re-enabling."
    codesign --force --options runtime --sign - "$bundle"
  fi
fi
codesign --verify --strict --verbose=2 "$bundle"
print "Built $bundle"
if $install; then
  # Stage first; preserve the existing app if copying or replacement fails.
  replacement="/Applications/.SuperCopy-install-$$.app"
  backup="/Applications/.SuperCopy-previous-$$.app"
  ditto "$bundle" "$replacement"
  pkill -x SuperCopy 2>/dev/null || true
  for _ in {1..30}; do pgrep -x SuperCopy >/dev/null || break; sleep 0.1; done
  if pgrep -x SuperCopy >/dev/null; then
    print -u2 "SuperCopy is still running; staged build remains at $replacement"; exit 1
  fi
  if [[ -e /Applications/SuperCopy.app ]]; then mv /Applications/SuperCopy.app "$backup"; fi
  if ! mv "$replacement" /Applications/SuperCopy.app; then
    if [[ -e "$backup" ]]; then mv "$backup" /Applications/SuperCopy.app; fi
    exit 1
  fi
  if [[ -e "$backup" ]]; then rm -rf "$backup"; fi
  open -g /Applications/SuperCopy.app --args --background
  print "Installed and launched /Applications/SuperCopy.app in the background"
fi
