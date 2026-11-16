# Capture, search, and resource limits

Multiple clipboard items retain their materialized representations, including original image bytes, rich/plain text, audio data, file URLs, and unknown binary formats. macOS only exposes formats the source app actually publishes. Lazy file promises that never materialize cannot be saved.

Copied regular files and folders are archived locally. Changed folder contents create new entries. Symlinks and nonregular filesystem objects are rejected. Restoring files creates a clipboard lease separate from history, so clearing history does not invalidate the current clipboard. Leases are pruned after the clipboard changes, including on a later launch if necessary.

Identical content is deduplicated and promoted to the top. There is no entry-count limit. Storage defaults to 10 GiB, configurable in Settings. Oldest content is evicted over budget. The budget counts saved representations, archives, and thumbnails; SQLite/WAL and active file leases add overhead.

A single capture is limited to 128 MiB of clipboard representations plus 1 GiB of archived files, with at most 100,000 traversed directory entries. Oversized or unreadable captures are skipped atomically and reported in menu status. Capture polls every 350 ms, with timer tolerance, and pauses during inactive login sessions. Values overwritten between polls cannot be observed.

The panel retains at most 640 history records and caches at most 120 thumbnails within a 24 MiB cost limit. Thumbnails are downsampled to at most 320 pixels. Forward/backward pagination retains access to older records without loading all history at once.

Search ranks literal matches, word-prefix matches, then English sentence similarity using Apple's on-device embeddings when available. Missing models retain lexical search. Images get local OCR in a persistent background queue; cold Vision initialization can take time. Audio and arbitrary binary formats are searchable by names/metadata, not their contents. Source-app metadata is sampled from the frontmost app during capture.

Vector search scans stored vectors using Accelerate. Memory is bounded, but CPU time is linear in history size. Large-file capture/restore depends on disk and file size. Desktop operations do not have nanosecond latency guarantees; benchmark claims must refer to the actual measured workload.
