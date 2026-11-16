import AppKit
import SuperCopyCore
import os

let log = Logger(subsystem: "app.supercopy.SuperCopy", category: "app")

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: HistoryStore?
    private var monitor: ClipboardMonitor?
    let paste = PasteController()
    let delivery = PasteDelivery()
    let history = HistoryPanel()
    /// Replaceable so the self-test never touches the real clipboard or sends real keystrokes.
    var board = NSPasteboard.general
    var postPaste: (pid_t, CGKeyCode) -> Bool = { PasteController.postPaste(to: $0, keyCode: $1) }
    var frontmostApp: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    private let preferences = PreferencesWindow()
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var pauseMenuItem: NSMenuItem?
    private var permissionTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private(set) var recent: [HistoryEntry] = []
    private var capturedID: String?
    private var capturedChange = -1
    private var currentEntry: HistoryEntry?
    private var target: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var queryTask: Task<Void, Never>?
    private var imageIndexTask: Task<Void, Never>?
    private var generation = 0
    private var pageOffset = 0
    private var windowOffset = 0
    private var loadedEntries: [HistoryEntry] = []
    private var loadedQuery = ""
    private var loadingPage = false
    private var hasMore = true
    private var session = false
    private(set) var committing = false
    private var currentFallback: String?
    private var commitWhenLoaded: Bool?
    private var selectAfterLoad: Int?
    private var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        UserDefaults.standard.register(defaults: ["diskBudgetGiB": 10, "paused": false])
        lastExternalApp = frontmostApp()
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let budget = Int64(UserDefaults.standard.integer(forKey: "diskBudgetGiB")) * 1024 * 1024 * 1024
            store = try HistoryStore(root: support.appendingPathComponent("SuperCopy", isDirectory: true), diskBudget: budget)
        } catch { lastError = error.localizedDescription }
        configureMenu()
        configureCallbacks()
        startMonitor()
        paste.start()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.lastExternalApp = app
                if self?.session == true, self?.target?.processIdentifier != app.processIdentifier { self?.paste.cancel(); self?.dismiss() }
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.paste.cancel(); self?.dismiss() }
        }
        for (name, suspended) in [(NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            sessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.monitor?.setSuspended(suspended)
                    if suspended { self?.paste.cancel(); self?.dismiss() }
                }
            })
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AXIsProcessTrusted() && !self.paste.available { self.paste.stop(); self.paste.start() }
                if !AXIsProcessTrusted() && self.paste.available { self.paste.stop() }
            }
        }
        // Without Accessibility the shortcut cannot work, so say so up front instead of failing silently.
        if !CommandLine.arguments.contains("--background"),
           !UserDefaults.standard.bool(forKey: "hasLaunched") || !AXIsProcessTrusted() {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showPreferences()
        }
    }
    private func startMonitor() {
        guard let store else { return }
        let monitor = ClipboardMonitor(store: store, board: board)
        monitor.onCapture = { [weak self] id, change in
            self?.capturedID = id; self?.capturedChange = change; self?.lastError = nil
            self?.refreshRecent(syncSession: true)
            self?.startImageIndexing()
        }
        monitor.onError = { [weak self] error in self?.report(error) }
        self.monitor = monitor; monitor.start(); refreshRecent()
        startImageIndexing()
    }
    /// The whole app minus the menu bar, the system key tap, and anything visible on screen.
    func startHeadless(root: URL, board: NSPasteboard) throws {
        self.board = board
        lastExternalApp = frontmostApp()
        store = try HistoryStore(root: root, diskBudget: 0)
        history.headless = true; paste.forceAvailable = true
        configureCallbacks(); startMonitor()
    }
    func stopHeadless() { monitor?.stop(); queryTask?.cancel(); imageIndexTask?.cancel() }
    private func configureCallbacks() {
        delivery.canReactivate = { NSApp.keyWindow == nil }
        delivery.frontmostPID = { [weak self] in self?.frontmostApp()?.processIdentifier }
        delivery.post = { [weak self] pid, key in self?.postPaste(pid, key) ?? false }
        paste.shouldIntercept = { [weak self] in self?.committing == false }
        paste.onBegin = { [weak self] in self?.begin() }
        paste.onMove = { [weak self] delta in self?.history.move(delta) }
        paste.onType = { [weak self] text in self?.history.type(text) }
        paste.onForward = { [weak self] event in self?.history.forward(event) }
        paste.onCommit = { [weak self] in guard let self else { return }; self.commit(self.history.selected, copyOnly: false) }
        paste.onDismiss = { [weak self] in self?.dismiss() }
        paste.onLatch = { [weak self] in self?.history.show(focusSearch: true) }
        paste.onAvailability = { [weak self] on in log.notice("Command-V interception \(on ? "on" : "off", privacy: .public)"); self?.updateMenuStatus() }
        history.onQuery = { [weak self] query in self?.load(query: query, reset: true) }
        history.onLatch = { [weak self] in self?.paste.latch() }
        history.onCommit = { [weak self] item, copyOnly in self?.commit(item, copyOnly: copyOnly) }
        history.onCancel = { [weak self] in self?.paste.cancel(); self?.dismiss() }
        history.onLoadMore = { [weak self] in guard let self else { return }; self.load(query: self.history.query, reset: false) }
        history.onLoadPrevious = { [weak self] in self?.loadPrevious() }
        history.onDelete = { [weak self] entry in
            guard let self, let store = self.store else { return }
            let index = self.history.selectedIndex
            Task { @MainActor [weak self] in
                do {
                    try await store.delete(id: entry.id)
                    guard let self else { return }
                    if self.capturedID == entry.id { self.capturedID = nil; self.capturedChange = -1 }
                    if self.currentEntry?.id == entry.id { self.currentEntry = nil; self.currentFallback = self.clipboardSummary() }
                    self.refreshRecent()
                    self.selectAfterLoad = index
                    self.load(query: self.history.query, reset: true)
                } catch { self?.report(error.localizedDescription) }
            }
        }
        preferences.onPermission = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        preferences.onBudget = { [weak self] bytes in
            guard let store = self?.store else { return }
            Task { @MainActor [weak self] in
                do { try await store.setDiskBudget(bytes); self?.refreshRecent() }
                catch { self?.report(error.localizedDescription) }
            }
        }
    }
    private func configureMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "SuperCopy")
        item.button?.toolTip = "SuperCopy"
        let menu = NSMenu(); menu.delegate = self
        func add(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let result = NSMenuItem(title: title, action: action, keyEquivalent: key); result.target = self
            menu.addItem(result); return result
        }
        _ = add("Open clipboard", #selector(openHistory))
        statusMenuItem = add("", nil)
        menu.addItem(.separator())
        pauseMenuItem = add("Pause history", #selector(togglePause))
        _ = add("Settings…", #selector(showPreferences), key: ",")
        _ = add("Clear history…", #selector(clearHistory))
        menu.addItem(.separator())
        _ = add("Quit SuperCopy", #selector(quit), key: "q")
        item.menu = menu; statusItem = item
    }
    func menuWillOpen(_ menu: NSMenu) { updateMenuStatus() }
    private var permissionStatus: String {
        if let lastError { return lastError }
        if store == nil { return "History unavailable" }
        if UserDefaults.standard.bool(forKey: "paused") { return "History paused" }
        return paste.available ? "History is local · Command-V enabled" : "History is local · Enable Command-V in Settings"
    }
    private func updateMenuStatus() {
        statusMenuItem?.title = permissionStatus
        pauseMenuItem?.title = UserDefaults.standard.bool(forKey: "paused") ? "Resume history" : "Pause history"
        preferences.updateStatus(permissionStatus)
        statusItem?.button?.toolTip = "SuperCopy — " + permissionStatus
    }
    private func report(_ message: String) { log.error("\(message, privacy: .public)"); lastError = message; updateMenuStatus() }
    private func refreshRecent(syncSession: Bool = false) {
        guard let store else { return }
        Task { @MainActor [weak self] in
            do {
                let entries = try await store.recent()
                guard let self else { return }
                self.recent = entries; self.updateMenuStatus()
                if syncSession { self.adoptCapturedEntry() }
            } catch { self?.report(error.localizedDescription) }
        }
    }
    /// A copy made moments before ⌘V is saved while the list is already open; swap the
    /// placeholder row for the real entry without disturbing the selection.
    private func adoptCapturedEntry() {
        guard session, currentEntry == nil, history.query.isEmpty, loadedQuery.isEmpty, windowOffset == 0,
              board.changeCount == capturedChange,
              let entry = recent.first(where: { $0.id == capturedID }) else { return }
        currentEntry = entry; currentFallback = nil
        if !loadedEntries.contains(where: { $0.id == entry.id }) { loadedEntries.insert(entry, at: 0); pageOffset += 1 }
        renderLoaded(query: "", preserveSelection: true)
    }
    /// A short description of the live clipboard, for the brief moment before it is saved
    /// (or for content that is deliberately never saved).
    private func clipboardSummary() -> String? {
        guard let items = board.pasteboardItems, !items.isEmpty else { return nil }
        let types = items.flatMap { $0.types }
        if CapturePolicy.shouldIgnore(types: types.map(\.rawValue)) && !types.contains(.init("org.nspasteboard.AutoGeneratedType")) { return "Hidden content" }
        if let name = items.first?.string(forType: .fileURL).flatMap(URL.init(string:))?.lastPathComponent, !name.isEmpty { return name }
        if let line = board.string(forType: .string)?.split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }), !line.isEmpty {
            return String(line.prefix(240))
        }
        if types.contains(where: { [.png, .tiff].contains($0) }) { return "Image" }
        return "Clipboard"
    }
    private var currentItems: [PanelItem] {
        if let currentEntry { return [PanelItem(entry: currentEntry, current: true)] }
        if let currentFallback { return [PanelItem(entry: nil, current: true, fallbackTitle: currentFallback)] }
        return []
    }
    private func startImageIndexing() {
        guard imageIndexTask == nil, let store else { return }
        imageIndexTask = Task { @MainActor [weak self] in
            defer { self?.imageIndexTask = nil }
            do {
                while !Task.isCancelled, try await store.enrichNextImage() { self?.refreshRecent() }
            } catch is CancellationError { }
            catch { self?.report(error.localizedDescription) }
        }
    }
    private func begin() {
        guard !committing else { paste.finish(); return }
        session = true
        target = frontmostApp()
        if target?.processIdentifier == ProcessInfo.processInfo.processIdentifier { target = lastExternalApp }
        history.reset()
        commitWhenLoaded = nil; selectAfterLoad = nil
        let captured = board.changeCount == capturedChange
        currentEntry = captured ? recent.first { $0.id == capturedID } : nil
        currentFallback = currentEntry == nil ? clipboardSummary() : nil
        if !captured { monitor?.pollNow() }
        loadedEntries = recent; windowOffset = 0; loadedQuery = ""
        pageOffset = recent.count; hasMore = recent.count == 80; loadingPage = false
        renderLoaded(query: "", preserveSelection: false)
        history.show()
    }
    private func dismiss(animated: Bool = true) {
        session = false; generation += 1
        queryTask?.cancel(); queryTask = nil
        commitWhenLoaded = nil; selectAfterLoad = nil
        history.hide(animated: animated); loadingPage = false
    }
    private func load(query: String, reset: Bool) {
        guard session, let store else { return }
        if !reset && (loadingPage || !hasMore) { return }
        if reset { generation += 1; queryTask?.cancel(); pageOffset = 0; windowOffset = 0; hasMore = true }
        let expected = generation, offset = pageOffset
        loadingPage = true
        queryTask = Task { @MainActor [weak self] in
            do {
                if reset && !query.isEmpty { try await Task.sleep(nanoseconds: 90_000_000) }
                let entries = try await store.search(query, limit: 80, offset: offset)
                guard !Task.isCancelled, let self, self.session, self.generation == expected else { return }
                self.loadedEntries = reset ? entries : self.loadedEntries + entries
                self.loadedQuery = query
                if self.loadedEntries.count > 640 {
                    let excess = self.loadedEntries.count - 640
                    self.loadedEntries.removeFirst(excess); self.windowOffset += excess
                }
                self.renderLoaded(query: query, preserveSelection: !reset)
                self.pageOffset = offset + entries.count; self.hasMore = entries.count == 80; self.loadingPage = false
                if let copyOnly = self.commitWhenLoaded, self.history.query == query {
                    self.commitWhenLoaded = nil
                    self.commit(self.history.selected, copyOnly: copyOnly)
                }
            } catch is CancellationError { }
            catch { guard let self, self.generation == expected else { return }; self.loadingPage = false; self.report(error.localizedDescription) }
        }
    }
    private func renderLoaded(query: String, preserveSelection: Bool) {
        let current = query.isEmpty && windowOffset == 0 ? currentItems : []
        var seen = Set<String>()
        let mapped = loadedEntries.filter { (current.isEmpty || $0.id != currentEntry?.id) && seen.insert($0.id).inserted }.map { PanelItem(entry: $0, current: false) }
        history.setItems(current + mapped, preserveSelection: preserveSelection, selectIndex: selectAfterLoad)
        selectAfterLoad = nil
    }
    private func loadPrevious() {
        guard session, !loadingPage, windowOffset > 0, let store else { return }
        loadingPage = true
        let expected = generation, query = history.query, offset = max(0, windowOffset - 80)
        let count = windowOffset - offset
        queryTask = Task { @MainActor [weak self] in
            do {
                let entries = try await store.search(query, limit: count, offset: offset)
                guard !Task.isCancelled, let self, self.session, self.generation == expected else { return }
                self.loadedEntries = entries + self.loadedEntries
                if self.loadedEntries.count > 640 { self.loadedEntries.removeLast(self.loadedEntries.count - 640); self.hasMore = true }
                self.windowOffset = offset; self.pageOffset = offset + self.loadedEntries.count
                self.renderLoaded(query: query, preserveSelection: true)
                self.loadingPage = false
            } catch is CancellationError { }
            catch { guard let self, self.generation == expected else { return }; self.loadingPage = false; self.report(error.localizedDescription) }
        }
    }
    private func commit(_ item: PanelItem?, copyOnly: Bool) {
        guard session, !committing else { return }
        // Return pressed before the search caught up: paste as soon as the results are in.
        guard history.query == loadedQuery else { commitWhenLoaded = copyOnly; return }
        let destination = target
        paste.finish()
        // A clicked row can own keyboard focus too. Remove the panel before delivering any paste.
        dismiss(animated: false)
        guard let item else { return }
        committing = true
        let initialChange = board.changeCount
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.committing = false }
            do {
                var expectedChange = initialChange
                guard self.board.changeCount == expectedChange else { return }
                if !item.current, let entry = item.entry, let store = self.store {
                    let representations = try await store.restore(id: entry.id)
                    guard self.board.changeCount == initialChange else {
                        await store.finishRestore(id: entry.id)
                        self.report("Paste cancelled because the clipboard changed.")
                        return
                    }
                    let written = PasteboardIO.write(representations, to: self.board)
                    expectedChange = self.board.changeCount
                    await store.finishRestore(id: entry.id)
                    guard written else { throw HistoryError.invalidPayload }
                    // It is the clipboard again: move it to the top and treat it as the current entry.
                    try await store.touch(id: entry.id)
                    guard self.board.changeCount == expectedChange else { return }
                    self.capturedID = entry.id; self.capturedChange = expectedChange
                    self.refreshRecent()
                }
                guard !copyOnly, self.paste.available, let destination, !destination.isTerminated else { return }
                switch await self.delivery.deliver(to: destination.processIdentifier, keyCode: self.paste.pasteKeyCode,
                                                  isCurrent: { self.board.changeCount == expectedChange }) {
                case .sent: break
                case .cancelled: self.report("Copied. Paste cancelled because focus or keyboard state changed; use ⌘V to paste.")
                case .permissionRequired: self.report("Copied. Enable Accessibility to paste automatically.")
                }
            } catch { self.report(error.localizedDescription) }
        }
    }
    @objc private func openHistory() { paste.openSearch() }
    @objc private func togglePause() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "paused"), forKey: "paused"); updateMenuStatus()
    }
    @objc private func showPreferences() { preferences.show(status: permissionStatus) }
    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "All saved entries and archived files will be removed from this Mac. The current clipboard is kept."
        alert.addButton(withTitle: "Clear History"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let store else { return }
        paste.cancel(); dismiss()
        Task { @MainActor [weak self] in
            do { try await store.clear(); self?.recent = []; self?.capturedID = nil; self?.capturedChange = -1; self?.lastError = nil; self?.updateMenuStatus() }
            catch { self?.report(error.localizedDescription) }
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop(); paste.stop(); queryTask?.cancel(); imageIndexTask?.cancel(); permissionTimer?.invalidate()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        for observer in sessionObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
