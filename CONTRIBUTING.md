# Contributing

SuperCopy is a native Swift/AppKit app for macOS 14 and later. Start with [the architecture](docs/ARCHITECTURE.md), then make a focused change without introducing third-party packages unless they solve a clear problem.

```sh
export EDITOR=vim VISUAL=vim GIT_EDITOR=vim
./scripts/test.sh
./scripts/build.sh --ad-hoc
```

Use `vim README.md` for documentation edits. Open `Package.swift` in Xcode if you prefer its debugger; the project also builds with the Command Line Tools.

Tests use temporary history directories and private pasteboards. Keep that isolation: never add automated tests that write to the general clipboard, inject real keys, activate apps, reset TCC, or capture someone's desktop. Put optional live checks in the compatibility checklist.

For input changes, cover cancellation, modifier release, target changes, permission loss, secure input, and exactly one paste. Explain what was tested and what still needs a live app check. CI artifacts are development builds; they are not notarized releases.

Report bugs using the issue template. Include the destination app and field type, macOS version, and exact key sequence using harmless sample content. Do not upload the history database or a private screen recording.
