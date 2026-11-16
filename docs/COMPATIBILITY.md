# Paste compatibility

SuperCopy uses the normal session event stream rather than injecting directly into one process ID. This lets macOS route paste through apps that use helper processes. It sends a balanced Command/V sequence after the panel is hidden, the original app owns focus, and physical shortcut modifiers are released.

This broadens compatibility; it is not proof that every control in every application accepts paste. Secure keyboard input deliberately bypasses interception. Read-only fields, blocked clipboard permissions, remote desktops, custom shortcuts, and controls that reject synthetic input or particular formats may behave differently.

## Repeatable live checks

Open [paste-fixture.html](paste-fixture.html) directly in Safari and a Chromium browser. The fixture is self-contained: no server, libraries, telemetry, or network requests. It includes inputs, textareas, editable rich content, shadow DOM, and an iframe. Use sample text only.

For each field:

1. Copy `alpha`, then `bravo`, then `charlie`.
2. Quick ⌘V should insert `charlie` exactly once.
3. Hold ⌘, press V twice, then release ⌘. It should insert `bravo` exactly once.
4. Open the picker, type a query, release ⌘, and press Return. Focus should return to the original field and paste once.
5. Click a result. It should paste into the original field, not the picker.
6. Escape and outside-click cancellation should leave the field untouched.
7. Switch applications while a paste is pending. No paste should land in the new app.
8. Try ⌘⇧V independently; it should retain the destination's existing behavior.

Also check TextEdit plain/rich text, an Electron editor and chat composer, a terminal with Secure Keyboard Entry both off and on, a Finder rename field, non-US keyboard layouts, full-screen Spaces, multiple displays, Accessibility revocation/regrant, and login launch.

For secure input and read-only controls, the expected result is no SuperCopy interception, or the destination's normal rejection. No password should be used as a fixture.

## Evidence boundary

The automated self-test exercises the real event handler, panel, store, and private clipboard, plus the synthetic-event construction and focus/modifier delivery policy. Its event sink is replaced, so no keys are sent to other apps. It cannot establish that a particular external browser, Electron control, terminal, or OS privacy configuration accepts injected input. Those live checks remain manual to avoid interrupting the user's desktop.
