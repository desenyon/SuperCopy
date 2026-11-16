import AppKit

// Finder draws the actual draggable app and Applications icons over this background.
let width: CGFloat = 660, height: CGFloat = 440
let image = NSImage(size: NSSize(width: width * 2, height: height * 2), flipped: true) { _ in
    let scale = NSAffineTransform(); scale.scale(by: 2); scale.concat()
    NSColor.black.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
    func text(_ string: String, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                        .foregroundColor: color, .paragraphStyle: style]
        (string as NSString).draw(in: NSRect(x: 32, y: y, width: width - 64, height: 42), withAttributes: attributes)
    }
    let foreground = NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.94, alpha: 1)
    let secondary = NSColor(calibratedWhite: 0.58, alpha: 1)
    let accent = NSColor(calibratedRed: 0.66, green: 0.78, blue: 1, alpha: 1)
    text("SuperCopy", y: 39, size: 32, color: foreground, weight: .semibold)
    text("Drag SuperCopy to Applications.", y: 88, size: 15, color: secondary)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 301, y: 220)); arrow.line(to: NSPoint(x: 359, y: 220))
    arrow.move(to: NSPoint(x: 348, y: 210)); arrow.line(to: NSPoint(x: 359, y: 220)); arrow.line(to: NSPoint(x: 348, y: 230))
    arrow.lineWidth = 2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    accent.setStroke(); arrow.stroke()
    text("Then open it from Applications to get started.", y: 337, size: 13, color: secondary)
    text("Your clipboard, remembered. Everything stays on your Mac.", y: 370, size: 12, color: secondary)
    return true
}
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
    fputs("Could not render installer background\n", stderr); exit(1)
}
// Keep a 2x raster while reporting Finder's logical window dimensions.
bitmap.size = NSSize(width: width, height: height)
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode installer background\n", stderr); exit(1)
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
