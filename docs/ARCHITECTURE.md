# Architecture

| Component | Responsibility |
| --- | --- |
| `SuperCopyCore/HistoryStore` | Actor-isolated SQLite history, deduplication, archives, retention, restoration leases |
| `SuperCopyCore/ContentAnalysis` | Local embeddings, bounded previews, image OCR |
| `SuperCopyCore/PasteboardIO` | Multi-item clipboard representations, capture policy, generated-content markers |
| `SuperCopyCore/PasteGesture` | Pure hold/cycle/search/commit state machine |
| `SuperCopy/PasteController` | Session event tap, physical key interpretation, tagged synthetic events |
| `SuperCopy/PasteDelivery` | Focus and modifier readiness, cancellation, exactly one event burst |
| `SuperCopy/HistoryPanel` | Native floating panel, paginated table, search, bounded thumbnail cache |
| `SuperCopy/AppDelegate` | Session ownership, asynchronous search/restore, permissions, menu bar |

The event tap performs no disk IO. Capture runs on a serial utility queue. Storage uses an actor; OCR runs separately so cold Vision startup cannot stall capture. UI updates return to the main actor. Only the visible history window and a bounded thumbnail cache are held in memory.

On ⌘V, the picker preserves the source app. Each additional physical V advances one row; auto-repeat does not. Releasing Command commits unless search has latched the panel open. Commit hides the panel before delivery, waits up to one second for the original app and released shortcut modifiers, and lets focus settle for 30 ms. It cancels if another app takes focus, the clipboard changes, the destination exits, or secure input begins. There is no blind retry that could duplicate a paste.

Replacement paste is a marked Command-down / V-down / V-up / Command-up sequence posted to the normal session input stream. WindowServer routes it to the focused app, including apps with helper processes. The marker prevents re-interception. The synchronous event burst follows the final destination check; macOS still owns dispatch, and the app cannot acknowledge insertion inside another application's custom control.

Search orders exact text, word-prefix matches, then English sentence similarity. Vector scanning has linear CPU cost with bounded working memory. Audio and arbitrary binary data are searchable by available names/metadata, not their meaning.
