import AppKit
import SuperCopyCore

/// Renders real views without ordering a window, reading the clipboard, or taking focus.
/// Glass needs the WindowServer backdrop, so fixtures use the opaque accessibility fallback.
enum OffscreenVerification {
    static func render(to directory: URL) throws {
        NSApp.setActivationPolicy(.prohibited)
        Appearance.offscreen = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferences = PreferencesWindow()
        try render(preferences.window.contentView!, to: directory.appendingPathComponent("settings.png"))
        let panel = HistoryPanel()
        let now = Date()
        let icon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.icns")
        let iconPreview = directory.appendingPathComponent("icon-preview.png")
        if let image = NSImage(contentsOf: icon), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: iconPreview)
        }
        let wide = directory.appendingPathComponent("wide-preview.png")
        let gradient = NSImage(size: NSSize(width: 320, height: 150), flipped: false) { rect in
            NSGradient(colors: [NSColor.systemIndigo, NSColor.systemTeal, NSColor.systemMint])?.draw(in: rect, angle: 20); return true
        }
        if let tiff = gradient.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: wide) }
        let samples: [(String, String, ClipKind, String, String?)] = [
            ("Ship the small things, beautifully.", "A little less friction. A little more focus.", .text, "Notes", nil),
            ("Screenshot 2026-11-15 at 09.41.png", "Screenshot", .image, "Safari", wide.path),
            ("SuperCopy icon.png", "SuperCopy icon.png", .image, "Finder", iconPreview.path),
            ("let history = await clipboard.search(query)", "let history = await clipboard.search(query)", .text, "Xcode", nil),
            ("Interview recording.m4a", "Interview recording.m4a", .audio, "Finder", nil),
            ("https://developer.apple.com/design/", "https://developer.apple.com/design/", .text, "Safari", nil),
            ("Launch checklist", "Polish the details. Test the edges.", .text, "Notes", nil)
        ]
        let items = samples.enumerated().map { index, sample in
            PanelItem(entry: HistoryEntry(id: "fixture-\(index)", title: sample.0, text: sample.1, kind: sample.2,
                                           source: sample.3, created: now, lastUsed: now.addingTimeInterval(-Double(index * index) * 400), byteCount: sample.2 == .audio ? 8_400_000 : 241_000,
                                           thumbnailPath: sample.4), current: index == 0)
        }
        panel.setItems(items)
        // Give queued thumbnail decoding a chance to complete without showing a window.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try render(panel.panel.contentView!, to: directory.appendingPathComponent("clipboard.png"))
        for _ in 0..<300 {
            weak var releasedPanel: HistoryPanel?
            weak var releasedWindow: NSWindow?
            autoreleasepool {
                let temporaryPanel = HistoryPanel()
                releasedPanel = temporaryPanel
                temporaryPanel.setItems([])
                temporaryPanel.reset()
                let temporaryPreferences = PreferencesWindow()
                releasedWindow = temporaryPreferences.window
                _ = temporaryPreferences.window.contentView
            }
            precondition(releasedPanel == nil && releasedWindow == nil, "A panel or settings window was retained after teardown")
        }
        print("Rendered actual AppKit layouts; 300 panel/settings allocation cycles completed without showing windows.")
    }
    private static func render(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw HistoryError.invalidPayload }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw HistoryError.invalidPayload }
        try data.write(to: url)
    }
}
