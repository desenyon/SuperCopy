import AppKit

/// One small visual vocabulary shared by the list and the settings window.
enum Appearance {
    static let text = NSColor(calibratedWhite: 1, alpha: 0.92)
    static let secondary = NSColor(calibratedWhite: 1, alpha: 0.50)
    static let muted = NSColor(calibratedWhite: 1, alpha: 0.32)
    static let accent = NSColor(calibratedRed: 0.62, green: 0.76, blue: 1, alpha: 1)
    static let selection = NSColor(calibratedWhite: 1, alpha: 0.085)
    static let surface = NSColor(calibratedRed: 0.086, green: 0.088, blue: 0.098, alpha: 1)
    static var offscreen = false
    static var reduceMotion: Bool { offscreen || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = Appearance.text) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    static func symbol(_ name: String, size: CGFloat = 16, weight: NSFont.Weight = .regular, color: NSColor = Appearance.secondary) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
        view.contentTintColor = color
        return view
    }
    /// A dark, blurred, rounded backdrop. Falls back to an opaque surface when transparency is reduced.
    static func backdrop(content: NSView, radius: CGFloat) -> NSView {
        let frame = content.frame
        content.autoresizingMask = [.width, .height]
        if offscreen || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let background = NSView(frame: frame)
            background.wantsLayer = true
            background.layer?.backgroundColor = surface.cgColor
            background.layer?.cornerRadius = radius
            background.layer?.cornerCurve = .continuous
            background.layer?.masksToBounds = true
            background.addSubview(content)
            return background
        }
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = radius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.maskImage = roundedMask(radius: radius)
        // A steady tint keeps text legible over bright or busy windows.
        let tint = NSView(frame: blur.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.052, blue: 0.06, alpha: 0.55).cgColor
        blur.addSubview(tint)
        blur.addSubview(content)
        return blur
    }
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
    static func animate(_ duration: TimeInterval, _ changes: () -> Void, completion: (() -> Void)? = nil) {
        if reduceMotion {
            NSAnimationContext.runAnimationGroup { $0.duration = 0; $0.allowsImplicitAnimation = false; changes() }
            completion?(); return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion)
    }
    /// "now", "4m", "3h", "2d", then a short date.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 { return "now" }
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        return shortDate.string(from: date)
    }
    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("MMM d"); return formatter
    }()
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class QuietButton: NSButton {
    var primary = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let background = primary ? Appearance.accent.withAlphaComponent(isHighlighted ? 0.75 : (hovered ? 0.9 : 1))
                                 : NSColor.white.withAlphaComponent(hovered || isHighlighted ? 0.12 : 0.07)
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: primary ? NSColor(calibratedWhite: 0.06, alpha: 1) : Appearance.text,
            .paragraphStyle: style]
        (title as NSString).draw(in: NSRect(x: 6, y: (bounds.height - 17) / 2, width: bounds.width - 12, height: 17), withAttributes: attributes)
    }
}

final class Keycap: NSView {
    let text: String
    init(_ text: String, frame: NSRect) { self.text = text; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let size = min(18, bounds.height * 0.46)
        (text as NSString).draw(in: NSRect(x: 0, y: (bounds.height - size - 6) / 2, width: bounds.width, height: size + 6), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: Appearance.text, .paragraphStyle: style
        ])
    }
}
