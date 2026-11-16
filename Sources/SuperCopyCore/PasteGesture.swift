/// Pure state machine: the event tap never performs storage or rendering work.
public struct PasteGesture: Sendable {
    public enum Input: Equatable, Sendable {
        case paste(repeated: Bool), releaseCommand, next, previous, cancel, latch
    }
    public enum Effect: Equatable, Sendable { case begin, move(Int), commit, dismiss, latch }
    public private(set) var active = false
    public private(set) var latched = false
    public init() {}
    public mutating func handle(_ input: Input) -> [Effect] {
        switch input {
        case .paste(let repeated):
            if !active { active = true; latched = false; return [.begin] }
            return repeated ? [] : [.move(1)]
        case .releaseCommand:
            guard active, !latched else { return [] }
            active = false; return [.commit]
        case .next: return active ? [.move(1)] : []
        case .previous: return active ? [.move(-1)] : []
        case .cancel:
            guard active else { return [] }
            active = false; latched = false; return [.dismiss]
        case .latch:
            let wasActive = active
            active = true; latched = true
            return wasActive ? [.latch] : [.begin, .latch]
        }
    }
    public mutating func reset() { active = false; latched = false }
}
