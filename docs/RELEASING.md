# Release preparation

## Current status

The full SuperCopy interaction is an **unsandboxed, direct-distribution app**. The repository includes source builds, a privacy manifest, CI packaging, and local verification. This is not a Mac App Store submission archive or an approved store release.

[Apple's review rule 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility) requires Mac App Store apps to be sandboxed. Apple's [accessibility documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Accessibility/cocoaAXIntro/cocoaAXintro.html) states that an app controlling another app cannot be sandboxed. SuperCopy's active global event tap and injected paste therefore need a different distribution route, or a separate product interaction. Adding an entitlement file would not resolve this conflict.

A store edition would need an explicit redesign: a sandboxed picker that copies the chosen item, followed by the user's own paste. It would also need file-access validation inside the sandbox, an Xcode application archive, distribution provisioning, App Store Connect metadata, a hosted privacy-policy URL, screenshots, age-rating/export-compliance answers, TestFlight/clean-install testing, and App Review. None of that is represented as completed here. Only Command Line Tools, rather than full Xcode, were available on the development Mac.

## Local use

```sh
./scripts/test.sh
./scripts/build.sh --install
```

Local builds use a stable self-signed identity to avoid resetting Accessibility on each build. The identity is not an Apple distribution certificate. Installation stages the replacement before stopping the old app, and relaunches in the background. It does not reset permissions or open Settings. If permission is missing, open SuperCopy's Settings yourself and enable Accessibility.

## Direct distribution

1. Run tests and the [compatibility checklist](COMPATIBILITY.md) on supported macOS versions, both CPU architectures, and a clean user account.
2. Build a universal binary with the distributor's own Developer ID:

   ```sh
   SUPERCOPY_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build.sh --universal
   lipo dist/SuperCopy.app/Contents/MacOS/SuperCopy -verify_arch arm64
   lipo dist/SuperCopy.app/Contents/MacOS/SuperCopy -verify_arch x86_64
   codesign --verify --strict --verbose=2 dist/SuperCopy.app
   ```

3. Notarize using an already configured keychain profile, then staple and package:

   ```sh
   ditto -c -k --keepParent dist/SuperCopy.app dist/SuperCopy-submission.zip
   xcrun notarytool submit dist/SuperCopy-submission.zip --keychain-profile 'supercopy-notary' --wait
   xcrun stapler staple dist/SuperCopy.app
   xcrun stapler validate dist/SuperCopy.app
   spctl --assess --type execute --verbose=2 dist/SuperCopy.app
   ditto -c -k --keepParent dist/SuperCopy.app dist/SuperCopy.zip
   shasum -a 256 dist/SuperCopy.zip
   ```

4. Verify the final downloaded archive on a clean machine before attaching it to a release. Do not remove quarantine as a substitute for Gatekeeper verification.

The build script enables hardened runtime and verifies the signature. Signing/notarization credentials belong in the macOS keychain or a CI secret store, never the repository. CI uses `--ad-hoc` and uploads clearly named development artifacts; it does not publish a consumer release automatically.

The privacy manifest includes app preferences (`CA92.1`), app/copied-file timestamps (`C617.1`, `3B52.1`), and elapsed-time timers (`35F9.1`). Review these against the exact release's API usage and [Apple's current required-reason definitions](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) before submitting any future store variant.
