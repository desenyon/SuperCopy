import AppKit
import SuperCopyCore

struct PanelItem {
    let entry: HistoryEntry?
    /// The row that stands for whatever is on the clipboard right now.
    let current: Bool
    /// Shown for the current clipboard before (or without) a saved entry.
    var fallbackTitle: String? = nil
    var id: String { current ? "current-clipboard" : entry?.id ?? "" }
}

final class FloatingPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onShortcut: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class SearchField: NSTextField {
    var onFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
}

final class ClipRow: NSTableCellView {
    static let textHeight: CGFloat = 50
    static let imageHeight: CGFloat = 74
    private static let previewBox = NSSize(width: 112, height: 58)
    let preview = NSImageView()
    let title = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")
    var representedID = ""
    var hasPreview = false { didSet { needsLayout = true } }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        preview.imageScaling = .scaleAxesIndependently
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6; preview.layer?.cornerCurve = .continuous; preview.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 13.5, weight: .regular)
        title.textColor = Appearance.text
        title.lineBreakMode = .byTruncatingTail
        meta.font = .systemFont(ofSize: 11, weight: .regular)
        meta.textColor = Appearance.secondary
        meta.lineBreakMode = .byTruncatingTail
        [preview, title, meta].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setPreview(_ image: NSImage?, animated: Bool) {
        preview.image = image
        needsLayout = true
        guard animated, image != nil, !Appearance.reduceMotion else { preview.alphaValue = 1; return }
        preview.alphaValue = 0
        Appearance.animate(0.18) { preview.animator().alphaValue = 1 }
    }
    override func layout() {
        super.layout()
        var trailing: CGFloat = 14
        if hasPreview {
            let box = Self.previewBox
            var size = box
            if let image = preview.image, image.size.width > 0, image.size.height > 0 {
                let scale = min(box.width / image.size.width, box.height / image.size.height)
                size = NSSize(width: max(24, (image.size.width * scale).rounded()), height: max(24, (image.size.height * scale).rounded()))
            }
            preview.frame = NSRect(x: bounds.width - 10 - size.width, y: ((bounds.height - size.height) / 2).rounded(),
                                   width: size.width, height: size.height)
            trailing = box.width + 24
        }
        let top = ((bounds.height - 35) / 2).rounded()
        let width = max(0, bounds.width - 14 - trailing)
        title.frame = NSRect(x: 14, y: top, width: width, height: 18)
        meta.frame = NSRect(x: 14, y: top + 20, width: width, height: 15)
    }
}

private final class ClearRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

final class HistoryPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let width: CGFloat = 580
    private static let header: CGFloat = 52
    private static let pad: CGFloat = 8
    private static let maxList: CGFloat = 398
    private static let emptyHeight: CGFloat = 56

    let panel: FloatingPanel
    private let search = SearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let highlight = NSView()
    private let empty = Appearance.label("", size: 13, color: Appearance.secondary)
    private let searchIcon = Appearance.symbol("magnifyingglass", size: 14, weight: .medium, color: Appearance.muted)
    private let content = FlippedView()
    private let cache = NSCache<NSString, NSImage>()
    private let imageQueue = DispatchQueue(label: "app.supercopy.thumbnails", qos: .userInitiated)
    private var scrollObserver: NSObjectProtocol?
    private var outsideMonitor: Any?
    private var visible = false
    /// Runs every code path without putting a window on screen.
    var headless = false
    var isVisible: Bool { visible }
    private var visibility = 0
    private var top: CGFloat = 0
    private var left: CGFloat = 0
    private var lastQuery = ""
    private var selection = 0
    private(set) var items: [PanelItem] = []
    var onQuery: ((String) -> Void)?
    var onLatch: (() -> Void)?
    var onCommit: ((PanelItem?, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onLoadMore: (() -> Void)?
    var onLoadPrevious: (() -> Void)?
    var onDelete: ((HistoryEntry) -> Void)?
    var selected: PanelItem? { items.indices.contains(selection) ? items[selection] : nil }
    var selectedIndex: Int { selection }
    var query: String { search.stringValue }

    override init() {
        let height = Self.header + Self.emptyHeight
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: height),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        content.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        panel.contentView = Appearance.backdrop(content: content, radius: 16)

        searchIcon.frame = NSRect(x: 20, y: 18, width: 16, height: 16)
        content.addSubview(searchIcon)
        search.frame = NSRect(x: 46, y: 15, width: Self.width - 46 - 20, height: 22)
        search.autoresizingMask = [.width]
        search.font = .systemFont(ofSize: 15)
        search.focusRingType = .none
        search.isBordered = false; search.isBezeled = false
        search.drawsBackground = false
        search.textColor = Appearance.text
        search.placeholderAttributedString = NSAttributedString(string: "Type to search", attributes: [
            .foregroundColor: Appearance.muted, .font: NSFont.systemFont(ofSize: 15)])
        search.cell?.isScrollable = true; search.cell?.wraps = false
        search.delegate = self
        search.onFocus = { [weak self] in self?.onLatch?() }
        search.setAccessibilityLabel("Search clipboard history")
        content.addSubview(search)

        let column = NSTableColumn(identifier: .init("clip"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none; table.focusRingType = .none
        table.allowsEmptySelection = true
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(clicked)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Clipboard history")
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor = Appearance.selection.cgColor
        highlight.layer?.cornerRadius = 10; highlight.layer?.cornerCurve = .continuous
        table.addSubview(highlight, positioned: .below, relativeTo: nil)
        scroll.frame = NSRect(x: Self.pad, y: Self.header, width: Self.width - Self.pad * 2, height: height - Self.header - Self.pad)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed
        scroll.documentView = table
        scroll.contentView.postsBoundsChangedNotifications = true
        content.addSubview(scroll)
        empty.alignment = .center
        empty.frame = NSRect(x: 20, y: Self.header + 8, width: Self.width - 40, height: 20)
        empty.autoresizingMask = [.width]
        content.addSubview(empty)
        cache.countLimit = 120; cache.totalCostLimit = 24 * 1024 * 1024
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onShortcut = { [weak self] event in self?.handleShortcut(event) ?? false }
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            guard let self, !self.items.isEmpty else { return }
            let bounds = self.scroll.contentView.bounds
            let rows = self.table.rows(in: bounds)
            if bounds.minY < ClipRow.imageHeight { self.onLoadPrevious?() }
            if rows.location != NSNotFound && rows.location + rows.length >= self.items.count - 10 { self.onLoadMore?() }
        }
        setItems([])
    }

    // MARK: Content

    func reset() {
        search.stringValue = ""; lastQuery = ""
        items = []; selection = 0; table.reloadData(); cache.removeAllObjects()
        panel.makeFirstResponder(table)
    }
    /// - Parameter selectIndex: row to select when the previous selection no longer exists.
    func setItems(_ items: [PanelItem], preserveSelection: Bool = false, selectIndex: Int? = nil) {
        let oldID = preserveSelection ? selected?.id : nil
        let clip = scroll.contentView.bounds
        let topRow = preserveSelection ? table.row(at: NSPoint(x: 1, y: clip.minY + 1)) : -1
        let topID = self.items.indices.contains(topRow) ? self.items[topRow].id : nil
        let topInset = topID == nil ? 0 : clip.minY - table.rect(ofRow: topRow).minY
        self.items = items
        table.reloadData()
        if highlight.superview !== table { table.addSubview(highlight, positioned: .below, relativeTo: nil) }
        empty.isHidden = !items.isEmpty
        empty.stringValue = query.isEmpty ? "Nothing copied yet" : "No matches"
        let fallback = min(max(0, selectIndex ?? 0), max(0, items.count - 1))
        selection = oldID.flatMap { id in items.firstIndex { $0.id == id } } ?? fallback
        resize()
        if let topID, let index = items.firstIndex(where: { $0.id == topID }) {
            scrollTo(table.rect(ofRow: index).minY + topInset, animated: false)
        } else {
            scrollTo(0, animated: false)
            if selectIndex != nil { reveal(selection, animated: false) }
        }
        placeHighlight(animated: false)
    }
    /// Appends typed characters to the search, as if they had been typed into it.
    func type(_ text: String) {
        focusSearch()
        if let editor = search.currentEditor() as? NSTextView {
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else { search.stringValue += text }
        queryChanged()
    }
    /// A key pressed while ⌘ is still held after search began. Handled here directly so it
    /// never depends on which window the system currently routes the keyboard to.
    func forward(_ event: NSEvent) {
        guard visible else { return }
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onCommit?(selected, false)
        case 125: move(1)
        case 126: move(-1)
        case 51, 117:
            focusSearch()
            if let editor = search.currentEditor() as? NSTextView { editor.deleteBackward(nil) }
            else if !search.stringValue.isEmpty { search.stringValue.removeLast() }
            queryChanged()
        default:
            guard let text = event.charactersIgnoringModifiers, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) else { return }
            type(text)
        }
    }

    // MARK: Visibility

    func show(focusSearch focus: Bool = false) {
        if !visible {
            visible = true; visibility += 1
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
            if let area = screen?.visibleFrame {
                // Anchor the top edge so the list grows downward and never jumps.
                let tallest = Self.header + Self.maxList + Self.pad
                left = (area.midX - Self.width / 2).rounded()
                top = min(area.maxY - 24, (area.midY + tallest / 2 + area.height * 0.06).rounded())
            }
            var frame = targetFrame
            if Appearance.reduceMotion {
                panel.alphaValue = 1; panel.setFrame(frame, display: !headless)
                if !headless { panel.orderFrontRegardless() }
            } else {
                let destination = frame
                frame.origin.y -= 10
                panel.alphaValue = 0
                panel.setFrame(frame, display: true)
                panel.orderFrontRegardless()
                Appearance.animate(0.16) {
                    panel.animator().alphaValue = 1
                    panel.animator().setFrame(destination, display: true)
                }
            }
            panel.invalidateShadow()
            if !headless { outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.onCancel?() } }
        }
        if focus { focusSearch() }
    }
    /// - Parameter animated: pass false when focus must return to another app immediately.
    func hide(animated: Bool = true) {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        guard visible else { return }
        visible = false; visibility += 1
        let token = visibility
        guard animated, !Appearance.reduceMotion else { panel.orderOut(nil); panel.alphaValue = 1; return }
        Appearance.animate(0.11, { panel.animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.visibility == token else { return }
            self.panel.orderOut(nil); self.panel.alphaValue = 1
        }
    }
    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(0, selection + delta), items.count - 1)
        guard row != selection else { return }
        selection = row
        placeHighlight(animated: true)
        reveal(row, animated: true)
        if row >= items.count - 10 { onLoadMore?() }
        if row < 10 { onLoadPrevious?() }
    }

    // MARK: Layout

    private var listHeight: CGFloat {
        items.isEmpty ? Self.emptyHeight - Self.pad : min(Self.maxList, table.rect(ofRow: items.count - 1).maxY)
    }
    private var targetFrame: NSRect {
        let height = Self.header + listHeight + Self.pad
        return NSRect(x: left, y: top - height, width: Self.width, height: height)
    }
    private func resize() {
        table.sizeLastColumnToFit()
        let frame = targetFrame
        guard frame != panel.frame else { return }
        if visible && !Appearance.reduceMotion {
            Appearance.animate(0.14) { panel.animator().setFrame(frame, display: true) }
        } else {
            panel.setFrame(frame, display: visible)
        }
    }
    private func placeHighlight(animated: Bool) {
        guard items.indices.contains(selection) else { highlight.isHidden = true; return }
        let frame = table.rect(ofRow: selection).insetBy(dx: 0, dy: 1)
        if highlight.isHidden || !animated || !visible {
            highlight.isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0; highlight.frame = frame }
        } else {
            Appearance.animate(0.13) { highlight.animator().frame = frame }
        }
    }
    private func reveal(_ row: Int, animated: Bool) {
        // The window may still be animating to its new size, so measure against the target.
        let rect = table.rect(ofRow: row), offset = scroll.contentView.bounds.minY
        if rect.minY < offset { scrollTo(rect.minY, animated: animated) }
        else if rect.maxY > offset + listHeight { scrollTo(rect.maxY - listHeight, animated: animated) }
    }
    private func scrollTo(_ offset: CGFloat, animated: Bool) {
        let clip = scroll.contentView
        let limit = items.isEmpty ? 0 : max(0, table.rect(ofRow: items.count - 1).maxY - listHeight)
        let origin = NSPoint(x: 0, y: min(max(0, offset), limit))
        if animated && visible && !Appearance.reduceMotion {
            Appearance.animate(0.13) { clip.animator().setBoundsOrigin(origin) }
        } else {
            clip.setBoundsOrigin(origin)
        }
        scroll.reflectScrolledClipView(clip)
    }
    private func focusSearch() {
        if !headless { panel.makeKey() }
        if search.currentEditor() == nil {
            panel.makeFirstResponder(search)
            if let editor = search.currentEditor() { editor.selectedRange = NSRange(location: search.stringValue.count, length: 0) }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        items[row].entry?.thumbnailPath == nil ? ClipRow.textHeight : ClipRow.imageHeight
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ClearRow() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ClipRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? ClipRow ?? ClipRow()
        view.identifier = identifier
        let item = items[row]
        view.representedID = item.id
        view.title.stringValue = Self.title(for: item)
        view.meta.stringValue = Self.meta(for: item)
        view.hasPreview = item.entry?.thumbnailPath != nil
        view.preview.isHidden = !view.hasPreview
        view.setPreview(nil, animated: false)
        if let path = item.entry?.thumbnailPath {
            if let image = cache.object(forKey: path as NSString) { view.setPreview(image, animated: false) }
            else {
                let id = item.id
                imageQueue.async { [weak self, weak view] in
                    guard let image = NSImage(contentsOfFile: path) else { return }
                    let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 320 * 320 * 4
                    DispatchQueue.main.async { [weak self, weak view] in
                        self?.cache.setObject(image, forKey: path as NSString, cost: pixels)
                        if view?.representedID == id { view?.setPreview(image, animated: true) }
                    }
                }
            }
        }
        view.setAccessibilityLabel(view.title.stringValue + ", " + view.meta.stringValue)
        return view
    }
    static func title(for item: PanelItem) -> String {
        guard let entry = item.entry else { return item.fallbackTitle ?? "Clipboard" }
        let title = entry.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? entry.kind.rawValue.capitalized : title
    }
    static func meta(for item: PanelItem) -> String {
        guard let entry = item.entry else { return "On the clipboard" }
        var parts: [String] = []
        switch entry.kind {
        case .text: break
        case .image: parts.append("Image")
        case .audio: parts.append("Audio")
        case .file: parts.append("File")
        case .other: parts.append("Data")
        }
        if !entry.source.isEmpty { parts.append(entry.source) }
        if entry.kind != .text { parts.append(ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file)) }
        parts.append(Appearance.age(entry.lastUsed))
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Input

    func controlTextDidChange(_ obj: Notification) { queryChanged() }
    private func queryChanged() {
        guard search.stringValue != lastQuery else { return }
        lastQuery = search.stringValue
        onQuery?(lastQuery)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): onCommit?(selected, false); return true
        case #selector(NSResponder.cancelOperation(_:)): onCancel?(); return true
        default: return false
        }
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: onCancel?(); return true
        case 36, 76: onCommit?(selected, false); return true
        case 125: move(1); return true
        case 126: move(-1); return true
        default: return false
        }
    }
    /// ⌘⌫ removes the selected entry; ⌘C copies it without pasting (unless search text is selected).
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command else { return false }
        switch event.keyCode {
        case 51:
            if let entry = selected?.entry { onDelete?(entry) }
            return true
        case 8:
            if let editor = search.currentEditor(), editor.selectedRange.length > 0 { return false }
            onCommit?(selected, true); return true
        default: return false
        }
    }
    @objc private func clicked() {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        selection = row
        placeHighlight(animated: false)
        onCommit?(selected, false)
    }
    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    }
}
