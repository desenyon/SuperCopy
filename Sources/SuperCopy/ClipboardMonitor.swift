import AppKit
import SuperCopyCore

// Mutable capture state is confined to queue; callbacks are configured before start
// and invoked only on the main queue.
final class ClipboardMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.supercopy.capture", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastChange = -1
    private var busy = false
    private var stopped = false
    private var suspended = false
    private let store: HistoryStore
    private let board: NSPasteboard
    var onCapture: ((String, Int) -> Void)?
    var onError: ((String) -> Void)?
    init(store: HistoryStore, board: NSPasteboard = .general) { self.store = store; self.board = board }
    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(350), leeway: .milliseconds(80))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer; timer.resume()
        }
    }
    func stop() { queue.async { [weak self] in self?.stopped = true; self?.timer?.cancel(); self?.timer = nil } }
    /// Capture a fresh copy now rather than at the next tick.
    func pollNow() { queue.async { [weak self] in self?.poll() } }
    func setSuspended(_ value: Bool) { queue.async { [weak self] in self?.suspended = value } }
    private func poll() {
        guard !stopped, !busy, !suspended else { return }
        let change = board.changeCount
        guard change != lastChange else { return }
        let app = NSWorkspace.shared.frontmostApplication
        let excluded = UserDefaults.standard.stringArray(forKey: "excludedApps") ?? []
        let skip = UserDefaults.standard.bool(forKey: "paused") || excluded.contains(app?.bundleIdentifier ?? "")
        do {
            let references = (board.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
            let snapshot = skip ? nil : try autoreleasepool { try PasteboardIO.read(board, source: app?.localizedName ?? "") }
            guard change == board.changeCount else { return }
            lastChange = change
            busy = true
            Task { [weak self, store] in
                do {
                    try await store.pruneClipboardFiles(referencedURLs: references)
                    if let snapshot, let id = try await store.insert(snapshot) {
                        DispatchQueue.main.async { [weak self] in self?.onCapture?(id, change) }
                    }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async { [weak self] in self?.onError?(message) }
                }
                self?.queue.async { [weak self] in self?.busy = false }
            }
        } catch { DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) }; lastChange = change }
    }
    deinit { timer?.cancel() }
}
