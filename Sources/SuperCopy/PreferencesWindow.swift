import AppKit
import ServiceManagement

final class PreferencesWindow: NSObject, NSTextFieldDelegate {
    let window: NSWindow
    private let status = Appearance.label("Needed so ⌘V can open your history", size: 12, color: Appearance.secondary)
    private let excluded = NSTextField(string: "")
    private let storage = NSPopUpButton()
    private let launch = NSSwitch()
    private let temporaryText = NSSwitch()
    private let permission = QuietButton(title: "Enable", target: nil, action: nil)
    var onPermission: (() -> Void)?
    var onCapturePolicyChange: (() -> Void)?
    var onBudget: ((Int64) -> Void)?
    override init() {
        let size = NSSize(width: 460, height: 588)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "SuperCopy"; window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear; window.isOpaque = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let content = FlippedView(frame: NSRect(origin: .zero, size: size))
        window.contentView = Appearance.backdrop(content: content, radius: 14)
        let margin: CGFloat = 32, inner = size.width - margin * 2
        @discardableResult func label(_ text: String, x: CGFloat = margin, y: CGFloat, width: CGFloat = inner, size: CGFloat = 13,
                                      weight: NSFont.Weight = .regular, color: NSColor = Appearance.text) -> NSTextField {
            let field = Appearance.label(text, size: size, weight: weight, color: color)
            field.frame = NSRect(x: x, y: y, width: width, height: size + 6)
            content.addSubview(field)
            return field
        }
        // The gesture, stated once.
        content.addSubview(Keycap("⌘", frame: NSRect(x: margin, y: 56, width: 40, height: 40)))
        content.addSubview(Keycap("V", frame: NSRect(x: margin + 46, y: 56, width: 40, height: 40)))
        label("Hold ⌘, press V", x: margin + 104, y: 55, width: inner - 104, size: 17, weight: .semibold)
        label("Release ⌘ to paste what is selected.", x: margin + 104, y: 79, width: inner - 104, size: 12, color: Appearance.secondary)
        let hints: [(String, String)] = [("V", "Next entry"), ("⇧V", "Previous entry"), ("abc", "Type to search"), ("esc", "Cancel")]
        for (index, hint) in hints.enumerated() {
            let x = margin + CGFloat(index % 2) * (inner / 2), y = 124 + CGFloat(index / 2) * 30
            content.addSubview(Keycap(hint.0, frame: NSRect(x: x, y: y, width: 38, height: 22)))
            label(hint.1, x: x + 48, y: y + 2, width: inner / 2 - 52, size: 12, color: Appearance.secondary)
        }

        let card = NSView(frame: NSRect(x: margin - 12, y: 204, width: inner + 24, height: 68))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
        card.layer?.cornerRadius = 12; card.layer?.cornerCurve = .continuous
        content.addSubview(card)
        label("Accessibility", y: 217, width: 240, size: 13, weight: .medium)
        status.frame = NSRect(x: margin, y: 238, width: inner - 104, height: 17)
        content.addSubview(status)
        permission.primary = true; permission.isBordered = false
        permission.target = self; permission.action = #selector(permissionClicked)
        permission.frame = NSRect(x: size.width - margin - 88, y: 224, width: 88, height: 28)
        content.addSubview(permission)

        label("Launch at login", y: 302)
        launch.target = self; launch.action = #selector(loginChanged)
        launch.controlSize = .small
        launch.frame = NSRect(x: size.width - margin - 38, y: 300, width: 38, height: 22)
        launch.setAccessibilityLabel("Launch SuperCopy at login")
        content.addSubview(launch)
        label("History size", y: 344)
        storage.addItems(withTitles: ["1 GB", "5 GB", "10 GB", "50 GB", "Unlimited"])
        storage.selectItem(at: 2)
        storage.frame = NSRect(x: size.width - margin - 118, y: 340, width: 122, height: 26)
        storage.font = .systemFont(ofSize: 12); storage.isBordered = false
        storage.alignment = .right
        storage.target = self; storage.action = #selector(storageChanged)
        storage.setAccessibilityLabel("History size")
        content.addSubview(storage)
        label("Save temporary text", y: 386)
        temporaryText.target = self; temporaryText.action = #selector(temporaryTextChanged)
        temporaryText.controlSize = .small
        temporaryText.frame = NSRect(x: size.width - margin - 38, y: 384, width: 38, height: 22)
        temporaryText.setAccessibilityLabel("Save temporary clipboard text, including dictation")
        content.addSubview(temporaryText)
        label("For dictation apps that mark copies as temporary.", y: 410, size: 11.5, color: Appearance.muted)
        label("Ignore copies from", y: 452)
        let well = NSView(frame: NSRect(x: margin, y: 480, width: inner, height: 30))
        well.wantsLayer = true
        well.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
        well.layer?.cornerRadius = 8; well.layer?.cornerCurve = .continuous
        content.addSubview(well)
        excluded.frame = NSRect(x: margin + 10, y: 486, width: inner - 20, height: 18)
        excluded.placeholderAttributedString = NSAttributedString(string: "Bundle IDs, comma separated — e.g. com.apple.keychainaccess", attributes: [
            .foregroundColor: Appearance.muted, .font: NSFont.systemFont(ofSize: 11.5)])
        excluded.font = .systemFont(ofSize: 11.5)
        excluded.textColor = Appearance.text
        excluded.isBordered = false; excluded.isBezeled = false; excluded.drawsBackground = false
        excluded.focusRingType = .none
        excluded.cell?.isScrollable = true; excluded.cell?.wraps = false
        excluded.delegate = self
        excluded.setAccessibilityLabel("Apps to ignore, as comma separated bundle IDs")
        content.addSubview(excluded)
        label("Everything stays on this Mac.", y: 544, width: 230, size: 11.5, color: Appearance.muted)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let versionText = version.map { "Version " + $0 + (build.map { " (" + $0 + ")" } ?? "") } ?? "Development build"
        let versionLabel = label(versionText, x: margin + 230, y: 544, width: inner - 230, size: 11.5, color: Appearance.muted)
        versionLabel.alignment = .right
        versionLabel.setAccessibilityIdentifier("app-version")
        versionLabel.setAccessibilityLabel("SuperCopy " + versionText)
        window.initialFirstResponder = permission
    }
    func show(status message: String) {
        updateStatus(message)
        temporaryText.state = UserDefaults.standard.bool(forKey: "captureTemporaryText") ? .on : .off
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let budget = UserDefaults.standard.object(forKey: "diskBudgetGiB") as? Int ?? 10
        storage.selectItem(at: [1, 5, 10, 50, 0].firstIndex(of: budget) ?? 2)
        excluded.stringValue = (UserDefaults.standard.stringArray(forKey: "excludedApps") ?? []).joined(separator: ", ")
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func updateStatus(_ message: String) {
        let enabled = AXIsProcessTrusted()
        permission.title = enabled ? "Enabled" : "Enable"; permission.isEnabled = !enabled
        permission.primary = !enabled
        permission.needsDisplay = true
        status.stringValue = enabled ? "On — ⌘V opens clipboard history" : "Needed so ⌘V can open your history"
        // Preserve actionable errors without repeating an implementation status in the main layout.
        if !message.hasPrefix("History is local") { status.stringValue = message }
        status.toolTip = message
    }
    @objc private func permissionClicked() { onPermission?() }
    @objc private func temporaryTextChanged() {
        UserDefaults.standard.set(temporaryText.state == .on, forKey: "captureTemporaryText")
        onCapturePolicyChange?()
    }
    @objc private func storageChanged() {
        let value = [1, 5, 10, 50, 0][storage.indexOfSelectedItem]
        UserDefaults.standard.set(value, forKey: "diskBudgetGiB")
        onBudget?(Int64(value) * 1024 * 1024 * 1024)
    }
    @objc private func loginChanged() {
        do {
            if launch.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { status.stringValue = error.localizedDescription; launch.state = .off }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        let apps = excluded.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        UserDefaults.standard.set(apps, forKey: "excludedApps")
    }
}
