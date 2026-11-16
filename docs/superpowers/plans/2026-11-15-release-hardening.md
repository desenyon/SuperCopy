# Paste compatibility and release preparation

Goal: preserve the requested hold-Command/V gesture, improve delivery across app architectures, hide scrollbars without disabling scrolling, and publish a polished repository.

1. Add failing self-test regressions for session event routing, balanced modifier events, slow focus restoration, held modifiers, and app switching. Keep tests offscreen and use private pasteboards.
2. Replace PID-only injection with tagged session events. Hide the panel before sending, wait for destination focus and physical modifier release, and cancel on app switches, secure input, or timeout. Never retry a paste blindly.
3. Disable both scroll indicators; retain native scrolling, elasticity, and paginated loading.
4. Run unit and integration checks, release build, layout rendering, and leak checks. Install the verified local build without opening Settings or taking focus.
5. Add README artwork based on real offscreen fixtures, privacy/security/contribution docs, compatibility fixtures, CI, and release instructions. Audit tracked content before creating and pushing GitHub.

Distribution decision: the user selected direct DMG distribution. Preserve the global interception/automatic-paste interaction, package a universal drag-to-Applications installer, and require Developer ID signing/notarization for public downloads. Full Xcode is not installed on this Mac.
