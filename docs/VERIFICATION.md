# Verification · November 15, 2026

Checked on Apple Silicon, macOS 27.2, Apple Swift 6.4 / Command Line Tools. These results describe this checkout, not an App Store certification or a guarantee about every destination control.

| Check | Result |
| --- | --- |
| `./scripts/test.sh` | 23 unit tests across 5 suites passed; 61 offscreen integration assertions passed |
| Address Sanitizer | 23 unit tests passed with Address Sanitizer enabled |
| Universal release build | arm64 and x86_64 slices verified with `lipo`; both specify minimum macOS 14.0 |
| Packaged release `--self-test` | Passed using a private pasteboard and recorded event sink |
| Bundle signature and metadata | Strict signature verification and Info/privacy plist lint passed; local development identity, hardened runtime |
| UI allocation/teardown | 300 panel/settings cycles; explicit weak-reference teardown assertions passed |
| UI leak scan | Debug offscreen fixture process: 0 detected leaks / 0 leaked bytes |
| Core leak scan | Release diagnostics process with 2,000 entries: 0 detected leaks / 0 leaked bytes |
| Source actor diagnostics | Notification/timer main-actor boundary warnings fixed |

## What the regression checks cover

The integration test drives the real key handler, picker, history store, and private clipboard. It covers quick paste, cycling, reverse navigation, ignored auto-repeat, search/Return, cancellation, and pass-through shortcuts. New delivery checks inspect a balanced, marked Command-down / V-down / V-up / Command-up sequence routed to the session stream.

Timing tests simulate delayed activation, held modifiers, a destination switch, secure input, target termination, permission failure, a changed clipboard, and opening Settings. Releasing Command before V is tested to ensure held-key repeats remain consumed until key-up. A clipboard change before the commit task executes cancels automatic paste. The last two regressions were observed failing before their fixes and passing afterward.

The test pins a fake destination and replaces the event-posting sink; it never injects real keys, changes the general clipboard, or activates external apps. The layout renderer orders no windows and uses an opaque accessibility fallback. It verifies actual AppKit content/layout, **not live glass composition or animation**. Offscreen mode forces Reduce Motion; animation timing and desktop focus restoration remain live checks.

## Local storage benchmark

Fresh temporary database, release diagnostics, 2,000 short text entries, native English sentence model available, 60 page loads, 60 searches, then 250 more searches. This is a storage/search microbenchmark, not end-to-end paste latency.

| Measurement | Result |
| --- | ---: |
| 80-entry page, median / p95 | 0.11 / 0.14 ms |
| Hybrid search, median / p95 | 2.77 / 9.23 ms |
| Insert including embedding, mean | 5.86 ms |
| Warm / after 250 more searches | 53.42 / 53.42 MiB |
| Database integrity | `ok` |

These figures are one local run and do not establish behavior for millions of entries, large files, or a sustained day-long session. Leak scans cannot prove the absence of every leak.

## Remaining release gates

- Live [compatibility checks](COMPATIBILITY.md) in native, browser, Electron, terminal, full-screen, and multi-display environments. No desktop automation was performed because the user asked that their work remain uninterrupted.
- Clean-machine permission, login-launch, install/update, and FileVault/backup behavior.
- Intel runtime testing and supported older macOS versions; a cross-compiled slice is not a runtime test.
- Visible material, animation, focus, keyboard-layout, and secure-input transitions.
- Developer ID notarization/stapling and Gatekeeper verification for public binary distribution.
- Final signed/notarized DMG download checks for direct distribution. See [Releasing](RELEASING.md).

The installed Command Line Tools linker reports missing optional developer-library search paths and an Intel architecture deprecation warning for its SDK. The executable load commands were separately checked and still specify macOS 14.0. Successful local builds do not resolve the pending cross-version checks.

## Reproduce

```sh
./scripts/test.sh
./scripts/test.sh --sanitize address
./scripts/build.sh --universal
lipo dist/SuperCopy.app/Contents/MacOS/SuperCopy -verify_arch arm64
lipo dist/SuperCopy.app/Contents/MacOS/SuperCopy -verify_arch x86_64
xcrun vtool -show-build dist/SuperCopy.app/Contents/MacOS/SuperCopy
codesign --verify --strict --verbose=2 dist/SuperCopy.app
dist/SuperCopy.app/Contents/MacOS/SuperCopy --self-test
bin_dir=$(swift build -c release --show-bin-path)
leaks --atExit -- "$bin_dir/SuperCopyDiagnostics" 2000
debug_dir=$(swift build --show-bin-path)
leaks --atExit -- "$debug_dir/SuperCopy" --render-fixtures /tmp/SuperCopy-layouts
```

Use the debug executable for the UI leak scan: the hardened release's runtime can prevent the allocation instrumentation from loading. A command exiting successfully without an actual `leaks` report is not evidence of zero leaks. Workstation-specific diagnostic dumps stay local; screenshots in the README contain fixture data only.

## DMG packaging update

Direct DMG distribution replaces the proposed App Store route. `scripts/package-dmg.sh --universal` produced `SuperCopy-1.0.1-universal-development.dmg` and a matching SHA-256 file. The compressed image passed `hdiutil verify`; its read-only mount contained the signed app, correct Applications symlink, Finder layout, and background. A copy taken from the mounted image into a temporary Applications directory passed strict code-signature checks, both architecture checks, and all 61 app self-test assertions. The 23 core unit tests also passed after the diagnostics entry-point rename.

The installer background was rendered and inspected; the full Finder window was not opened, preserving the no-desktop-interruption requirement. Notarization, Developer ID signing, and quarantined clean-machine Gatekeeper checks were not performed. The optional `--notarize` path requires the distributor's credentials and remains unexercised here.

The first GitHub universal build exposed an Xcode `@main`/`main.swift` naming conflict in the diagnostics target. Renaming that entry point to `Diagnostics.swift` resolves the conflicting file convention. This is separate from app behavior; the local universal build passed after the rename.
