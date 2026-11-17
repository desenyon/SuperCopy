import AppKit
import Carbon
import SuperCopyCore

/// Drives the real app — key handling, list, history store, clipboard writes — with the
/// same keyboard events the system would deliver, but against a private pasteboard, a
/// temporary history, no window on screen, and a recorded (not sent) paste keystroke.
@MainActor enum SelfTest {
    private static var failures = 0
    private static var pastes = 0
    private static var app: AppDelegate!
    private static var board: NSPasteboard!

    static func run() async -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        NSApp.setActivationPolicy(.prohibited)
        Appearance.offscreen = true
        if IsSecureEventInputEnabled() {
            print("SKIPPED: a password field currently has secure keyboard input; SuperCopy deliberately stands down. Re-run later.")
            return 2
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SuperCopySelfTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        board = NSPasteboard(name: .init("app.supercopy.selftest.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        app = AppDelegate()
        app.postPaste = { _, _ in pastes += 1; return true }
        // You keep working while this runs; pin the "app being pasted into" so your app switching cannot affect it.
        let destination = NSRunningApplication.current
        app.frontmostApp = { destination }
        app.delivery.modifiers = { [] }
        let suite = "app.supercopy.selftest.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "paused"); preferences.set([], forKey: "excludedApps")
        do { try app.startHeadless(root: root, board: board, preferences: preferences) } catch { print("FAILED to start: \(error)"); return 1 }
        defer { app.stopHeadless() }

        await testDelivery()
        await testCaptureRecovery()

        // Three copies, oldest first.
        for text in ["alpha one", "bravo two", "charlie three"] {
            let before = app.recent.count
            board.clearContents(); board.setString(text, forType: .string)
            check("copy \"\(text)\" is captured", await wait { app.recent.count == before + 1 })
        }
        check("history is newest first", app.recent.map(\.title) == ["charlie three", "bravo two", "alpha one"])

        section("⌘V once, release → pastes the last copy")
        check("⌘V is consumed", key(9, [.maskCommand]) == nil)
        check("list opens immediately", app.history.isVisible)
        check("last copy is selected", title() == "charlie three" && app.history.selectedIndex == 0)
        check("list shows all three", app.history.items.count == 3)
        keyUp(9); releaseCommand(); await settle()
        check("exactly one paste is sent", pastes == 1)
        check("clipboard is still the last copy", board.string(forType: .string) == "charlie three")
        check("list closes", !app.history.isVisible)

        section("⌘V, V, V → cycles down, release pastes that entry")
        _ = key(9, [.maskCommand]); keyUp(9)
        check("holding V (auto-repeat) does not move", key(9, [.maskCommand], repeated: true) == nil && app.history.selectedIndex == 0)
        check("second V is consumed", key(9, [.maskCommand]) == nil); keyUp(9)
        check("second V moves to entry 2", app.history.selectedIndex == 1 && title() == "bravo two")
        _ = key(9, [.maskCommand]); keyUp(9)
        check("third V moves to entry 3", app.history.selectedIndex == 2 && title() == "alpha one")
        _ = key(9, [.maskCommand]); keyUp(9)
        check("V at the end stays on the last entry", app.history.selectedIndex == 2)
        _ = key(9, [.maskCommand, .maskShift]); keyUp(9)
        check("⇧V moves back up", app.history.selectedIndex == 1)
        _ = key(125, [.maskCommand]); keyUp(125)
        check("↓ moves down", app.history.selectedIndex == 2)
        releaseCommand(); await settle()
        check("one more paste is sent", pastes == 2)
        check("clipboard now holds the chosen entry", board.string(forType: .string) == "alpha one")
        check("chosen entry moved to the top of history", await wait { app.recent.first?.title == "alpha one" })

        section("next ⌘V shows the re-pasted entry first")
        _ = key(9, [.maskCommand]); keyUp(9)
        check("order is alpha, charlie, bravo", app.history.items.map { HistoryPanel.title(for: $0) } == ["alpha one", "charlie three", "bravo two"])

        section("Esc cancels without pasting")
        check("Esc is consumed", key(53, [.maskCommand]) == nil); keyUp(53)
        releaseCommand(); await settle()
        check("list closes", !app.history.isVisible)
        check("nothing is pasted", pastes == 2)
        check("clipboard is unchanged", board.string(forType: .string) == "alpha one")

        section("typing while ⌘ is held searches")
        _ = key(9, [.maskCommand]); keyUp(9)
        check("first letter is consumed", key(11, [.maskCommand]) == nil); keyUp(11)   // b
        check("second letter, ⌘ still down, is consumed", key(15, [.maskCommand]) == nil); keyUp(15)   // r
        check("both letters are in the search field", app.history.query == "br")
        check("⌘V while searching types a v instead of pasting", key(9, [.maskCommand]) == nil && app.history.query == "brv" && pastes == 2); keyUp(9)
        check("delete removes it again", key(51, [.maskCommand]) == nil && app.history.query == "br"); keyUp(51)
        check("⌘ release no longer pastes (search is open)", { releaseCommand(); return app.history.isVisible && pastes == 2 }())
                check("results narrow to the match", await wait { app.history.items.count == 1 && title() == "bravo two" })
        app.history.type("avo")
        check("more typing keeps matching", await wait { app.history.query == "bravo" && title() == "bravo two" })
        // Return lands before the debounced search finishes; the paste must follow on its own.
        _ = app.history.panel.onKey?(event(36, [])!)
        check("Return pastes the match", await wait { pastes == 3 })
        await settle()
        check("clipboard holds the match", board.string(forType: .string) == "bravo two")
        check("list closes", !app.history.isVisible)

        section("everything else is left alone")
        check("plain typing passes through", key(9, []) != nil); keyUp(9)
        check("⌘C passes through", key(8, [.maskCommand]) != nil); keyUp(8)
        check("⌘⇧V (Paste and Match Style) passes through", key(9, [.maskCommand, .maskShift]) != nil); keyUp(9)
        check("⌘⌥V passes through", key(9, [.maskCommand, .maskAlternate]) != nil); keyUp(9)
        check("no list opened", !app.history.isVisible)

        section("an unrelated shortcut mid-gesture stands down")
        _ = key(9, [.maskCommand]); keyUp(9)
        check("⌘Tab-style key passes through", key(48, [.maskCommand, .maskControl]) != nil)
        check("list closes without pasting", !app.history.isVisible && pastes == 3)
        releaseCommand(); await settle()

        section("release ordering cannot leak an intercepted key or paste a new copy")
        let before = pastes
        _ = key(9, [.maskCommand])
        releaseCommand()
        check("held V repeats stay consumed after Command is released", key(9, [], repeated: true) == nil)
        keyUp(9)
        await settle()
        check("the held key still commits only once", pastes == before + 1)
        _ = key(9, [.maskCommand]); keyUp(9)
        releaseCommand()
        board.clearContents(); board.setString("a new copy during commit", forType: .string)
        await settle()
        check("a copy before commit runs cancels automatic paste", pastes == before + 1)

        preferences.set(true, forKey: "captureTemporaryText")
        section("privacy markers override generated-content labels")
        let privateItem = ClipboardItem([
            .init(type: "public.utf8-plain-text", data: Data("private fixture should stay hidden".utf8)),
            .init(type: "org.nspasteboard.AutoGeneratedType", data: Data()),
            .init(type: "org.nspasteboard.ConcealedType", data: Data())
        ])
        _ = PasteboardIO.write([privateItem], to: board, markGenerated: false)
        _ = key(9, [.maskCommand]); keyUp(9)
        check("concealed generated text never appears in the picker", title() == "Hidden content")
        _ = key(53, [.maskCommand]); keyUp(53); releaseCommand()

        section("third-party generated dictation can be saved and found")
        let dictated = ClipboardItem([
            .init(type: "public.utf8-plain-text", data: Data("dictation integration fixture".utf8)),
            .init(type: "org.nspasteboard.AutoGeneratedType", data: Data())
        ])
        _ = PasteboardIO.write([dictated], to: board, markGenerated: false)
        check("dictation is captured into history", await wait { app.recent.contains { $0.title == "dictation integration fixture" } })
        app.paste.openSearch(); app.history.type("dictation")
        check("dictation can be found in the picker", await wait { app.history.items.contains { $0.entry?.title == "dictation integration fixture" } })
        app.paste.cancel()

        print(failures == 0 ? "\nPASSED: every step behaved as specified." : "\nFAILED: \(failures) step(s).")
        return failures == 0 ? 0 : 1
    }

    private static func testCaptureRecovery() async {
        section("dictation capture recovers from delayed data and save failures")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SuperCopyCaptureTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let captureBoard = NSPasteboard.withUniqueName()
        defer { captureBoard.releaseGlobally() }
        let suite = "app.supercopy.capture-test.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "paused"); preferences.set([], forKey: "excludedApps")
        do {
            let store = try HistoryStore(root: root, embeddings: nil)
            let monitor = ClipboardMonitor(store: store, board: captureBoard, preferences: preferences)
            defer { monitor.stop() }
            var captures = 0, errors = 0
            monitor.onCapture = { _, _ in captures += 1 }
            monitor.onError = { _ in errors += 1 }
            let generated = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
            captureBoard.declareTypes([.string, generated], owner: nil)
            captureBoard.setData(Data(), forType: generated)
            let declaredChange = captureBoard.changeCount
            monitor.start()
            await pause(0.55)
            check("metadata alone is not saved as an empty dictation", captures == 0)
            captureBoard.setString("delayed dictation fixture", forType: .string)
            check("lazy data can arrive without a new clipboard revision", captureBoard.changeCount == declaredChange)
            check("the same revision is captured once data arrives", await wait { captures == 1 })
            check("captured history contains the actual late text", try await store.recent().first?.title == "delayed dictation fixture")

            let beforeEmpty = captures
            captureBoard.clearContents()
            let emptyChange = captureBoard.changeCount
            await pause(0.55)
            captureBoard.setString("text after initially empty clipboard", forType: .string)
            check("a writer can supply text after an empty revision", captureBoard.changeCount == emptyChange)
            check("an initially empty revision is retried", await wait { captures == beforeEmpty + 1 })

            let objects = root.appendingPathComponent("objects"), saved = root.appendingPathComponent("saved-objects")
            try FileManager.default.moveItem(at: objects, to: saved)
            try Data("simulate unavailable storage".utf8).write(to: objects)
            let beforeError = captures
            captureBoard.clearContents(); captureBoard.setString("retry after save failure", forType: .string)
            monitor.pollNow()
            check("a failed save is reported", await wait { errors > 0 })
            try FileManager.default.removeItem(at: objects)
            try FileManager.default.moveItem(at: saved, to: objects)
            check("the same copy is retried after storage recovers", await wait { captures == beforeError + 1 })

            let beforeTemporary = captures
            let temporary = ClipboardItem([
                .init(type: "public.utf8-plain-text", data: Data("temporary dictation capture fixture".utf8)),
                .init(type: "org.nspasteboard.TransientType", data: Data())
            ])
            _ = PasteboardIO.write([temporary], to: captureBoard, markGenerated: false)
            await pause(0.55)
            check("temporary dictation is skipped by default", captures == beforeTemporary)
            preferences.set(true, forKey: "captureTemporaryText")
            monitor.pollNow(retry: true)
            check("enabling temporary text captures the existing clipboard", await wait { captures == beforeTemporary + 1 })

            let beforeLazyTemporary = captures
            let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            captureBoard.declareTypes([.string, transient], owner: nil)
            captureBoard.setData(Data(), forType: transient)
            let temporaryRevision = captureBoard.changeCount
            await pause(0.55)
            check("a ready temporary marker does not complete capture", captures == beforeLazyTemporary)
            captureBoard.setString("late temporary dictation fixture", forType: .string)
            check("temporary dictation may arrive at the same revision", captureBoard.changeCount == temporaryRevision)
            check("late temporary dictation is captured after opt-in", await wait { captures == beforeLazyTemporary + 1 })

            let beforeRestart = captures
            monitor.stop(); await pause(0.05); monitor.start()
            captureBoard.clearContents(); captureBoard.setString("capture after restart", forType: .string)
            check("a stopped monitor can restart", await wait { captures == beforeRestart + 1 })
        } catch { check("capture recovery fixture completed: \(error.localizedDescription)", false) }
    }

    private static func testDelivery() async {
        section("replacement paste uses the normal session input route")
        var emitted: [CGEvent] = []
        var route: CGEventTapLocation?
        let sent = PasteController.postPaste(to: 123, keyCode: 9, trusted: { true }, post: { event, tap in
            emitted.append(event); route = tap
        })
        check("events enter the session stream instead of one PID", sent && route == .cgSessionEventTap)
        check("Command press, V down/up, Command release are balanced", emitted.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        check("only the final event releases Command", emitted.count == 4 && emitted.prefix(3).allSatisfy { $0.flags.contains(.maskCommand) } && emitted.last?.flags.isEmpty == true)
        check("all synthetic events bypass our interceptor", emitted.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == PasteController.eventMarker })
        check("V events are not marked as auto-repeat", emitted.filter { $0.type == .keyDown || $0.type == .keyUp }.allSatisfy { $0.getIntegerValueField(.keyboardEventAutorepeat) == 0 })
        emitted.removeAll()
        check("revoked permission emits nothing", !PasteController.postPaste(to: 123, trusted: { false }, post: { event, _ in emitted.append(event) }) && emitted.isEmpty)

        section("delivery waits for focus and modifiers without stealing another app")
        let delivery = PasteDelivery()
        var time: TimeInterval = 0
        var front = ProcessInfo.processInfo.processIdentifier
        var physical: CGEventFlags = .maskCommand
        var count = 0
        var activations = 0
        delivery.now = { time }
        delivery.frontmostPID = { front }
        delivery.modifiers = { physical }
        delivery.secureInput = { false }
        delivery.isRunning = { _ in true }
        delivery.canReactivate = { true }
        delivery.activate = { _ in activations += 1 }
        delivery.post = { _, _ in count += 1; return true }
        delivery.sleep = {
            time += 0.01
            if time >= 0.12 { front = 123 }
            if time >= 0.18 { physical = [] }
        }
        let result = await delivery.deliver(to: 123, keyCode: 9)
        check("slow activation and modifier release still produce one paste", result == .sent && count == 1 && activations == 1 && time >= 0.21)
        front = ProcessInfo.processInfo.processIdentifier; count = 0
        delivery.canReactivate = { false }
        check("opening Settings cancels focus restoration", await delivery.deliver(to: 123, keyCode: 9) == .cancelled && count == 0)
        delivery.canReactivate = { true }
        time = 0; front = 123; physical = .maskShift; count = 0
        delivery.sleep = { time += 0.01 }
        check("held modifiers time out without pasting", await delivery.deliver(to: 123, keyCode: 9) == .cancelled && count == 0)
        time = 0; front = 123; physical = []; count = 0
        delivery.sleep = { time += 0.01; front = 456 }
        check("switching apps cancels before any event is sent", await delivery.deliver(to: 123, keyCode: 9) == .cancelled && count == 0)
        front = 123; delivery.secureInput = { true }
        check("secure input cancels delivery", await delivery.deliver(to: 123, keyCode: 9) == .cancelled && count == 0)
        delivery.secureInput = { false }
        check("a new clipboard cancels a pending paste", await delivery.deliver(to: 123, keyCode: 9, isCurrent: { false }) == .cancelled && count == 0)
        delivery.isRunning = { _ in false }
        check("terminated target cancels delivery", await delivery.deliver(to: 123, keyCode: 9) == .cancelled && count == 0)
        delivery.sleep = { time += 0.01 }
        delivery.isRunning = { _ in true }; delivery.post = { _, _ in false }
        check("posting failure is reported", await delivery.deliver(to: 123, keyCode: 9) == .permissionRequired)
    }

    private static func title() -> String { app.history.selected.map { HistoryPanel.title(for: $0) } ?? "" }
    private static func section(_ name: String) { print("\n" + name) }
    private static func check(_ name: String, _ passed: Bool) {
        print((passed ? "  ✔ " : "  ✘ ") + name + (passed ? "" : "   [pastes=\(pastes) visible=\(app.history.isVisible) committing=\(app.committing) query=\(app.history.query)]"))
        if !passed { failures += 1 }
    }
    private static func pause(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private static func wait(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { await pause(0.01) }
        return condition()
    }
    /// Lets queued work (clipboard restore, the paste) finish.
    private static func settle() async {
        await pause(0.05)
        _ = await wait { !app.committing }
        await pause(0.05)
    }
    private static func event(_ code: CGKeyCode, _ flags: CGEventFlags, down: Bool = true) -> NSEvent? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return nil }
        event.flags = flags
        return NSEvent(cgEvent: event)
    }
    private static func key(_ code: CGKeyCode, _ flags: CGEventFlags, repeated: Bool = false) -> Unmanaged<CGEvent>? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return nil }
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
        return app.paste.handle(.keyDown, event)
    }
    private static func keyUp(_ code: CGKeyCode) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        _ = app.paste.handle(.keyUp, event)
    }
    private static func releaseCommand() {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false) else { return }
        event.type = .flagsChanged; event.flags = []
        _ = app.paste.handle(.flagsChanged, event)
    }
}
