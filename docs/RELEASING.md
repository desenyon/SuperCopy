# DMG distribution

SuperCopy ships directly as a drag-to-Applications **DMG**, preserving its full global ⌘V interaction. The app remains unsandboxed and requires Accessibility permission. It does not use the Mac App Store.

## Local development images

On macOS with Swift 6 and [uv](https://docs.astral.sh/uv/) installed:

```sh
./scripts/test.sh
./scripts/package-dmg.sh --universal
```

Output:

```text
dist/SuperCopy-1.0.1-universal-development.dmg
dist/SuperCopy-1.0.1-universal-development.dmg.sha256
```

The version is read from `Resources/Info.plist`; single-architecture builds use their architecture in the filename. The package includes SuperCopy.app, an Applications shortcut, and hidden Finder layout/background assets. It needs no privileged installer, scripts running on the recipient's machine, or internet connection to install.

Packaging uses Apple's `hdiutil`, Swift/AppKit to draw the background, and pinned `ds-store`/`mac-alias` Python tooling through `uv` to write Finder metadata. These are packaging tools only, never bundled app dependencies. The script mounts images with `-nobrowse -noautoopen`; it does not drive Finder or take desktop focus.

Before reporting success, the script verifies the compressed image, mounts it read-only, verifies the app's signature, checks the Applications shortcut, and compares the packaged executable with the source bundle. It detaches temporary mounts on completion or failure, then emits a checksum. Existing output is replaced only after the new image passes these checks.

Local builds use a stable self-signed development identity. CI uses `--ad-hoc` and uploads development DMGs and checksums as workflow artifacts. Neither is an Apple-notarized public download. Do not remove quarantine as a substitute for release verification.

## Install

Open the DMG, drag SuperCopy into Applications, eject the image, then open SuperCopy from Applications. In the menu bar, open **Settings → Enable** and grant Accessibility. Do not run it directly from the mounted image. Quit an older running copy before replacing it; history and preferences remain outside the app bundle.

For a local source install without a DMG:

```sh
./scripts/build.sh --install
```

This stages the replacement first and relaunches in the background. It does not reset permissions or open Settings.

## Public downloads

Public DMGs need your own **Developer ID Application** certificate and an existing notarization keychain profile. They do not need App Store sandboxing or review. The `--notarize` option refuses ad-hoc and local self-signed identities.

```sh
SUPERCOPY_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/package-dmg.sh --universal --notarize 'supercopy-notary'
```

The script:

1. Builds and signs the app with hardened runtime.
2. Submits the app to Apple's notary service and staples/validates its ticket.
3. Assesses the stapled app with Gatekeeper.
4. Builds the DMG containing that stapled app and signs the image.
5. Submits the DMG, staples/validates its ticket, and performs package integrity checks.
6. Emits the final DMG and SHA-256 file after stapling.

Signing credentials belong in Keychain or CI secrets, never in source control. CI does not publish consumer downloads automatically. A supplied Developer ID without `--notarize` can produce a signed image, but that image has not completed the notarization release gate.

Verify both CPU slices and the final download:

```sh
lipo dist/SuperCopy.app/Contents/MacOS/SuperCopy -verify_arch arm64
lipo dist/SuperCopy.app/Contents/MacOS/SuperCopy -verify_arch x86_64
xcrun stapler validate dist/SuperCopy-1.0.1-universal.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 dist/SuperCopy-1.0.1-universal.dmg
(cd dist && shasum -a 256 -c SuperCopy-1.0.1-universal.dmg.sha256)
```

Run the [compatibility checklist](COMPATIBILITY.md), test on supported macOS releases and both architectures, and install the actual downloaded DMG on a clean machine before publishing. Live field compatibility, login launch, upgrades, offline ticket behavior, and quarantined-download Gatekeeper assessment remain release checks. A DMG is a delivery format, not evidence those checks passed.

The bundled privacy manifest covers app preferences, file timestamps, and elapsed-time timers. Review it against the actual submitted binary whenever API usage changes.
