import AppKit
import Carbon
import SuperCopyCore

/// Owns the ⌘V gesture.
///
///   ⌘V            the list appears; release ⌘ and the selected entry is pasted
///   V again       moves down one entry (⇧V moves back up), ⌘ still held
///   ↑ ↓           move, Return pastes now, Esc cancels
///   typing        any other character starts a search; the list then stays open
///                 until Return or Esc
final class PasteController {
    static let eventMarker: Int64 = 0x5355504552434F50
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = PasteGesture()
    private var swallowedKeys = Set<Int64>()
    private var watchdog: Timer?
    /// True while the ⌘ press that opened the list is still down.
    private var openingCommandHeld = false
    private(set) var pasteKeyCode: CGKeyCode = 9
    var onBegin: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onLatch: (() -> Void)?
    /// Characters typed while ⌘ is still held; they belong in the search field.
    var onType: ((String) -> Void)?
    /// A key event to hand to the list while ⌘ is still held after search began.
    var onForward: ((NSEvent) -> Void)?
    var onAvailability: ((Bool) -> Void)?
    var shouldIntercept: (() -> Bool)?
    var forceAvailable = false
    var available: Bool { forceAvailable || (tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false) }
    var active: Bool { gesture.active }
    var latched: Bool { gesture.latched }

    func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { onAvailability?(false); return }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<PasteController>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { onAvailability?(false); return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        onAvailability?(true)
    }
    func stop() {
        cancel()
        stopWatchdog()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil; swallowedKeys.removeAll()
    }
    func openSearch() { openingCommandHeld = false; apply(gesture.handle(.latch)) }
    func latch() { apply(gesture.handle(.latch)) }
    func cancel() { apply(gesture.handle(.cancel)) }
    func finish() { gesture.reset(); openingCommandHeld = false; stopWatchdog() }

    private func apply(_ effects: [PasteGesture.Effect]) {
        for effect in effects {
            switch effect {
            case .begin: startWatchdog(); onBegin?()
            case .move(let delta): onMove?(delta)
            case .commit: stopWatchdog(); onCommit?()
            case .dismiss: stopWatchdog(); openingCommandHeld = false; onDismiss?()
            case .latch: onLatch?()
            }
        }
    }
    /// Runs only while the list is open. A missed key-up (secure input, a disabled tap)
    /// must cancel rather than leave a paste armed.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.gesture.active else { self.stopWatchdog(); return }
            let commandDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
            if !commandDown { self.openingCommandHeld = false }
            if !self.gesture.latched && !commandDown { self.cancel() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
    private func stopWatchdog() { watchdog?.invalidate(); watchdog = nil }

    private func pass(_ event: CGEvent) -> Unmanaged<CGEvent>? { Unmanaged.passUnretained(event) }
    private func swallow(_ key: Int64) -> Unmanaged<CGEvent>? { swallowedKeys.insert(key); return nil }

    /// Decides one keyboard event. Returns nil when the event is consumed.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel(); swallowedKeys.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker { return pass(event) }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowedKeys.remove(key) != nil ? nil : pass(event) }
        let command = event.flags.contains(.maskCommand)
        if type == .flagsChanged {
            if !command { openingCommandHeld = false; apply(gesture.handle(.releaseCommand)) }
            return pass(event)
        }
        guard type == .keyDown else { return pass(event) }

        // Ordinary typing leaves here without any allocation or lookup.
        if !gesture.active {
            // Command can be released before V. Own its repeats until the physical key-up.
            if swallowedKeys.contains(key), event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            guard command, event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]) == .maskCommand,
                  shouldIntercept?() != false, !IsSecureEventInputEnabled(), isPasteKey(event, key) else { return pass(event) }
            pasteKeyCode = CGKeyCode(key)
            openingCommandHeld = true
            apply(gesture.handle(.paste(repeated: false)))
            return swallow(key)
        }
        if IsSecureEventInputEnabled() { cancel(); return pass(event) }

        if gesture.latched {
            // Search owns the keyboard. While the opening ⌘ is still down, keys are text, not shortcuts.
            guard openingCommandHeld, command else { return pass(event) }
            event.flags.remove(.maskCommand)
            if let forwarded = NSEvent(cgEvent: event) { onForward?(forwarded) }
            return swallow(key)
        }

        // The list is open and ⌘ is held: every key belongs to the gesture.
        let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if modifiers == .maskCommand || modifiers == [.maskCommand, .maskShift] {
            let shift = modifiers.contains(.maskShift)
            if isPasteKey(event, key) {
                if shift { if !repeated { apply(gesture.handle(.previous)) } }
                else { apply(gesture.handle(.paste(repeated: repeated))) }
                return swallow(key)
            }
            switch key {
            case 53: cancel(); return swallow(key)
            case 125: apply(gesture.handle(.next)); return swallow(key)
            case 126: apply(gesture.handle(.previous)); return swallow(key)
            case 36, 76: apply(gesture.handle(.releaseCommand)); return swallow(key)
            case 48, 49: apply(gesture.handle(.latch)); return swallow(key)
            default: break
            }
            if !repeated, let text = searchText(event) {
                apply(gesture.handle(.latch))
                onType?(text)
                return swallow(key)
            }
        }
        // An unrelated shortcut: stand down and let it through untouched.
        cancel()
        return pass(event)
    }
    private func isPasteKey(_ event: CGEvent, _ key: Int64) -> Bool {
        let character = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased()
        return character == "v" || (character?.isEmpty != false && key == 9)
    }
    /// The printable character a key would type without ⌘, if any.
    private func searchText(_ event: CGEvent) -> String? {
        guard let text = NSEvent(cgEvent: event)?.charactersIgnoringModifiers, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        return text
    }
    /// The destination is checked by PasteDelivery immediately before this synchronous burst.
    /// Session routing lets WindowServer dispatch to browser/Electron helper processes too.
    static func postPaste(to _: pid_t, keyCode: CGKeyCode = 9,
                          trusted: () -> Bool = { AXIsProcessTrusted() },
                          post: (CGEvent, CGEventTapLocation) -> Void = { $0.post(tap: $1) }) -> Bool {
        guard trusted(), let source = CGEventSource(stateID: .privateState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else { return false }
        source.localEventsSuppressionInterval = 0
        commandDown.type = .flagsChanged; commandUp.type = .flagsChanged
        for event in [commandDown, down, up, commandUp] {
            event.flags = event === commandUp ? [] : .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            post(event, .cgSessionEventTap)
        }
        return true
    }
    deinit {
        watchdog?.invalidate()
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
