# Make SuperCopy yours

Open the menu-bar icon → **Settings…**. These controls are already available in the app; no configuration file is required.

| Control | What you can change |
| --- | --- |
| Launch at login | Start SuperCopy when you sign in, or leave launch manual. Off until you enable it. |
| History size | Choose 1, 5, 10, or 50 GiB, or Unlimited. The default is 10 GiB. The app labels these options GB. |
| Ignore copies from | Enter source-app bundle IDs, separated by commas. Excluded copies are not saved. |
| Accessibility | Enable global ⌘V history and automatic paste in macOS System Settings. |

## Keep private apps out of history

In **Ignore copies from**, enter bundle IDs, for example:

```text
com.apple.keychainaccess
```

For multiple apps, separate IDs with commas. Use the actual installed application's ID, not its display name. You can look up a bundle ID without opening the app:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '/Applications/Your App.app/Contents/Info.plist'
```

Finish editing the field by pressing Tab or clicking another control. Exclusions use the frontmost app at capture time. They are not a retroactive history filter, and background/automated copies may have a different apparent source. Delete existing entries or clear history separately if needed.

Clipboard content marked sensitive or concealed is skipped automatically. Unmarked passwords can still be captured, so exclude private apps or pause history when appropriate.

## Set a storage budget

History defaults to 10 GiB. When saved payloads exceed the selected budget, the oldest content is removed. **Unlimited** removes this budget, so disk usage can keep growing. SQLite metadata, its write-ahead log, and a restored-file clipboard lease add overhead beyond the payload budget.

There is no entry-count setting. The picker fetches older entries as you scroll; a smaller budget controls disk usage rather than the number of visible rows. See [Storage](STORAGE.md) for per-copy and cache limits.

## Pause or clear history

Use **Pause history** in the menu bar to stop saving new copies, then **Resume history** when ready. Existing history remains available. **Clear history…** asks before deleting saved entries and archived files; it keeps the current clipboard intact. See [Privacy](PRIVACY.md) for restored-file leases and backups.

## Accessibility and appearance

SuperCopy follows macOS **Reduce Motion** and **Reduce Transparency** under System Settings → Accessibility → Display. Reduce Motion skips animations; Reduce Transparency uses an opaque dark surface. The picker already supports native trackpad/mouse scrolling without a visible scrollbar.

The dark palette, panel size, and ⌘V gesture are fixed in this version. There is no theme editor or configurable hotkey in Settings.

## Packaging choices

For maintainers, `scripts/package-dmg.sh` accepts `--universal`, `--ad-hoc`, and `--notarize KEYCHAIN_PROFILE`. The app's version comes from `Resources/Info.plist`. Public signing uses `SUPERCOPY_SIGNING_IDENTITY`. These are build options, not settings end users need to edit. See [Releasing](RELEASING.md).
