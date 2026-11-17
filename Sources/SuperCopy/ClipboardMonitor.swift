import AppKit
import SuperCopyCore

// Mutable capture state is confined to queue; callbacks are configured before start
// and invoked only on the main queue.
final class ClipboardMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.supercopy.capture", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastChange = -1
    private var pendingChange = -1
    private var attempts = 0
    private var retryGeneration = 0
    private static let maximumAttempts = 8
    private var busy = false
    private var stopped = false
    private var suspended = false
    private let store: HistoryStore
    private let board: NSPasteboard
    private let preferences: UserDefaults
    var onCapture: ((String, Int) -> Void)?
    var onError: ((String) -> Void)?
    init(store: HistoryStore, board: NSPasteboard = .general, preferences: UserDefaults = .standard) {
        self.store = store; self.board = board; self.preferences = preferences
    }
    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.stopped = false; self.pendingChange = -1; self.attempts = 0
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(350), leeway: .milliseconds(80))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer; timer.resume()
        }
    }
    func stop() { queue.async { [weak self] in self?.stopped = true; self?.timer?.cancel(); self?.timer = nil } }
    /// Capture a fresh copy now rather than at the next tick.
    func pollNow(retry: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if retry { self.retryGeneration += 1; self.lastChange = -1; self.pendingChange = -1; self.attempts = 0 }
            self.poll()
        }
    }
    func setSuspended(_ value: Bool) { queue.async { [weak self] in self?.suspended = value } }
    private func poll() {
        guard !stopped, !busy, !suspended else { return }
        let change = board.changeCount
        guard change != lastChange else { return }
        if pendingChange != change { pendingChange = change; attempts = 0 }
        guard attempts < Self.maximumAttempts else { return }
        attempts += 1
        let attempt = attempts, generation = retryGeneration
        let app = NSWorkspace.shared.frontmostApplication
        let excluded = preferences.stringArray(forKey: "excludedApps") ?? []
        let skip = preferences.bool(forKey: "paused") || excluded.contains(app?.bundleIdentifier ?? "")
        do {
            let types = (board.types ?? []).map(\.rawValue)
            let captureTemporaryText = preferences.bool(forKey: "captureTemporaryText")
            let ignored = CapturePolicy.shouldIgnore(types: types, captureTemporaryText: captureTemporaryText)
            let references = (board.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
            let snapshot = skip || ignored ? nil : try autoreleasepool { try PasteboardIO.read(board, source: app?.localizedName ?? "", captureTemporaryText: captureTemporaryText) }
            guard change == board.changeCount else { return }
            // A provider can declare formats before supplying their bytes, without changing
            // ownership/changeCount again. Do not acknowledge a revision until it is readable.
            let waitingForData = !skip && !ignored && snapshot == nil
            if waitingForData && attempt == Self.maximumAttempts && !types.isEmpty {
                report("Clipboard data is unavailable after several attempts. Copy it again to retry.")
            }
            busy = true
            Task { [weak self, store] in
                do {
                    try await store.pruneClipboardFiles(referencedURLs: references)
                    let id: String?
                    if let snapshot { id = try await store.insert(snapshot, captureTemporaryText: captureTemporaryText) }
                    else { id = nil }
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        if !waitingForData && self.retryGeneration == generation { self.lastChange = change }
                        self.busy = false
                        if let id { DispatchQueue.main.async { [weak self] in self?.onCapture?(id, change) } }
                    }
                } catch {
                    let message = error.localizedDescription
                    self?.queue.async { [weak self] in
                        self?.busy = false
                        if attempt == 1 || attempt == Self.maximumAttempts { self?.report(message) }
                    }
                }
            }
        } catch {
            if attempt == 1 || attempt == Self.maximumAttempts { report(error.localizedDescription) }
        }
    }
    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
    deinit { timer?.cancel() }
}
