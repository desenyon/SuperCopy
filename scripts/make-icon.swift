import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 190, yRadius: 190).fill()
    NSColor(calibratedRed: 0.66, green: 0.78, blue: 1, alpha: 1).setStroke()
    let back = NSBezierPath(roundedRect: NSRect(x: 250, y: 340, width: 370, height: 420), xRadius: 54, yRadius: 54)
    back.lineWidth = 32; back.stroke()
    NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
    let front = NSBezierPath(roundedRect: NSRect(x: 385, y: 220, width: 370, height: 420), xRadius: 54, yRadius: 54)
    front.fill(); NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.94, alpha: 1).setStroke()
    front.lineWidth = 32; front.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
