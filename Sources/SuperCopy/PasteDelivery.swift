import AppKit
import Carbon

/// Waits for the original app to own input before entering the normal session event stream.
/// Dependencies are replaceable so timing and app-switch races can be tested without input injection.
@MainActor final class PasteDelivery {
    enum Outcome { case sent, cancelled, permissionRequired }
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var modifiers: () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) }
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    var isRunning: (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.isTerminated == false }
    var canReactivate: () -> Bool = { NSApp.keyWindow == nil }
    var activate: (pid_t) -> Void = { NSRunningApplication(processIdentifier: $0)?.activate(options: []) }
    var post: (pid_t, CGKeyCode) -> Bool = { PasteController.postPaste(to: $0, keyCode: $1) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: () async throws -> Void = { try await Task.sleep(nanoseconds: 10_000_000) }

    func deliver(to pid: pid_t, keyCode: CGKeyCode, isCurrent: () -> Bool = { true }) async -> Outcome {
        let deadline = now() + 1
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let shortcutModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        var activated = false
        var readySince: TimeInterval?
        while now() < deadline {
            guard !Task.isCancelled, isCurrent(), isRunning(pid), !secureInput() else { return .cancelled }
            let front = frontmostPID()
            // Never refocus or paste into an app the user has switched away from.
            guard front == pid || front == ownPID else { return .cancelled }
            if front == ownPID && front != pid {
                guard canReactivate() else { return .cancelled }
                if !activated { activated = true; activate(pid) }
            }
            if front == pid && modifiers().intersection(shortcutModifiers).isEmpty {
                // Let panel orderOut, key-up and focus restoration finish a run-loop turn.
                if let readySince, now() - readySince >= 0.03 {
                    return post(pid, keyCode) ? .sent : .permissionRequired
                }
                if readySince == nil { readySince = now() }
            } else { readySince = nil }
            do { try await sleep() } catch { return .cancelled }
        }
        return .cancelled
    }
}
