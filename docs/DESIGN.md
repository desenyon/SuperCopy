# Design

SuperCopy is a menu-bar clipboard manager for macOS 14 and later. The picker contains search and clipboard rows on a compact dark material surface. It has no visible scrollbar, extra toolbar, or decorative dividers. Native scrolling, pagination, keyboard selection, image previews, and Reduce Motion/Transparency support remain available.

Hold Command and press V to show history with the current clipboard selected. Each additional physical V advances one entry; Shift-V moves back. Releasing Command commits once. Typing latches search open; Return commits and Escape cancels. Modified paste shortcuts outside the gesture pass through. See the complete [interaction table](../README.md#the-gesture).

Focus preservation is part of the design: the panel is nonactivating, disappears before delivery, and the selected content is sent only after the original app is ready. App switching, a new clipboard, secure input, or delivery timeout cancels automatic paste. The selected entry remains on the clipboard when restoration succeeded.

The release hardening work is recorded in [the implementation plan](superpowers/plans/2026-11-15-release-hardening.md). For module boundaries, see [Architecture](ARCHITECTURE.md); for the distribution constraint, see [Releasing](RELEASING.md).
