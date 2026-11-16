import Foundation
import Testing
import AppKit
@testable import SuperCopyCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SuperCopyTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func textSnapshot(_ text: String, date: Date = Date()) -> ClipboardSnapshot {
    ClipboardSnapshot(items: [.init([.init(type: "public.utf8-plain-text", data: Data(text.utf8))])], source: "Tests", capturedAt: date)
}

@Suite("Durable history")
struct HistoryTests {
    @Test func nestedFileChangesCannotBeDeduplicatedAway() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("child.txt")
        try Data("before".utf8).write(to: file)
        let fixedDate = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: folder.path)
        let store = try HistoryStore(root: root.appendingPathComponent("history"), embeddings: nil)
        let snapshot = ClipboardSnapshot(items: [.init([.init(type: "public.file-url", data: Data(folder.absoluteString.utf8))])])
        let first = try await store.insert(snapshot)
        try Data("after!".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: folder.path)
        let second = try await store.insert(snapshot)
        #expect(first != second)
        #expect(try await store.statistics().count == 2)
    }
    @Test func restoredFilesSurviveHistoryDeletion() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("note.txt")
        try Data("keep this".utf8).write(to: original)
        let store = try HistoryStore(root: root.appendingPathComponent("history"), embeddings: nil)
        let id = try #require(try await store.insert(ClipboardSnapshot(items: [.init([.init(type: "public.file-url", data: Data(original.absoluteString.utf8))])])) )
        let url = try #require(try await store.restore(id: id).first?.fileURL)
        try await store.clear()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    @Test func roundTripMultipleItemsAndUnknownTypes() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = ClipboardSnapshot(items: [
            .init([.init(type: "public.utf8-plain-text", data: Data("hello".utf8)), .init(type: "com.example.binary", data: Data([0, 255, 1, 3]))]),
            .init([.init(type: "public.rtf", data: Data("{\\rtf1 second}".utf8))])
        ])
        let id: String
        do {
            let store = try HistoryStore(root: root, embeddings: nil)
            id = try #require(try await store.insert(snapshot))
            #expect(try await store.restore(id: id) == snapshot.items)
            #expect(try await store.integrityCheck() == "ok")
        }
        let reopened = try HistoryStore(root: root, embeddings: nil)
        #expect(try await reopened.restore(id: id) == snapshot.items)
        #expect(try await reopened.statistics().count == 1)
    }
    @Test func pastedEntryReturnsToTheTop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root, embeddings: nil)
        func text(_ value: String, _ offset: TimeInterval) -> ClipboardSnapshot {
            ClipboardSnapshot(items: [.init([.init(type: "public.utf8-plain-text", data: Data(value.utf8))])],
                              capturedAt: Date(timeIntervalSince1970: 1_000 + offset))
        }
        let older = try #require(try await store.insert(text("older", 0)))
        _ = try await store.insert(text("newer", 10))
        #expect(try await store.recent().first?.title == "newer")
        try await store.touch(id: older, at: Date(timeIntervalSince1970: 2_000))
        #expect(try await store.recent().map(\.title) == ["older", "newer"])
    }
    @Test func duplicatePromotesWithoutGrowingHistory() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root, embeddings: nil)
        let a = try await store.insert(textSnapshot("first", date: Date(timeIntervalSince1970: 1)))
        _ = try await store.insert(textSnapshot("second", date: Date(timeIntervalSince1970: 2)))
        let duplicate = try await store.insert(textSnapshot("first", date: Date(timeIntervalSince1970: 3)))
        #expect(a == duplicate)
        #expect(try await store.recent().map(\.title) == ["first", "second"])
        #expect(try await store.statistics().count == 2)
    }
    @Test func copiedFileSurvivesOriginalDeletion() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("sound.wav")
        let bytes = Data([82, 73, 70, 70, 0, 1, 2, 3])
        try bytes.write(to: original)
        let store = try HistoryStore(root: root.appendingPathComponent("history"), embeddings: nil)
        let snapshot = ClipboardSnapshot(items: [.init([.init(type: "public.file-url", data: Data(original.absoluteString.utf8))])])
        let id = try #require(try await store.insert(snapshot))
        try FileManager.default.removeItem(at: original)
        let restored = try await store.restore(id: id)
        let archived = try #require(restored.first?.fileURL)
        #expect(archived != original)
        #expect(try Data(contentsOf: archived) == bytes)
        #expect(try await store.entry(id: id)?.kind == .audio)
        #expect(try await store.search("sound").first?.id == id)
    }
    @Test func directoryArchiveAndInaccessibleFileAreAtomic() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("body".utf8).write(to: directory.appendingPathComponent("note.txt"))
        let store = try HistoryStore(root: root.appendingPathComponent("history"), embeddings: nil)
        let id = try #require(try await store.insert(ClipboardSnapshot(items: [.init([.init(type: "public.file-url", data: Data(directory.absoluteString.utf8))])])))
        try FileManager.default.removeItem(at: directory)
        let archived = try #require(try await store.restore(id: id).first?.fileURL)
        #expect(try String(contentsOf: archived.appendingPathComponent("note.txt"), encoding: .utf8) == "body")
        await #expect(throws: (any Error).self) {
            try await store.insert(ClipboardSnapshot(items: [.init([.init(type: "public.file-url", data: Data(directory.absoluteString.utf8))])]))
        }
        #expect(try await store.statistics().count == 1)
        let paths = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("history/objects").path)
        #expect(paths.count == 1)
    }
    @Test func sensitiveDataIsNeverPersisted() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root, embeddings: nil)
        for type in CapturePolicy.sensitiveTypes {
            let snapshot = ClipboardSnapshot(items: [.init([.init(type: "public.utf8-plain-text", data: Data("secret".utf8)), .init(type: type, data: Data())])])
            #expect(try await store.insert(snapshot) == nil)
        }
        #expect(try await store.statistics().count == 0)
    }
    @Test func paginationIsStableAndDoesNotDuplicate() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root, embeddings: nil)
        for index in 0..<103 { _ = try await store.insert(textSnapshot("entry \(index)", date: Date(timeIntervalSince1970: Double(index)))) }
        let first = try await store.recent(limit: 80)
        let second = try await store.recent(limit: 80, offset: 80)
        #expect(first.count == 80); #expect(second.count == 23)
        #expect(Set((first + second).map(\.id)).count == 103)
        #expect(first.first?.title == "entry 102")
    }
    @Test func literalSearchHandlesSyntaxAndUnicode() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root, embeddings: nil)
        _ = try await store.insert(textSnapshot("SELECT * FROM table WHERE code = 100%_\\value; 🐈 café 日本語"))
        for query in ["100%_\\value", "🐈", "café", "日本語", "SELECT", "FROM tab"] {
            #expect(try await store.search(query).count == 1, "Failed query: \(query)")
        }
        #expect(try await store.search("\" OR * - (").isEmpty)
        #expect(try await store.search("no such phrase").isEmpty)
    }
    @Test func deleteClearAndOrphanRecovery() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try HistoryStore(root: root, embeddings: nil)
            let id = try #require(try await store.insert(textSnapshot("delete me")))
            try await store.delete(id: id)
            #expect(try await store.search("delete").isEmpty)
            _ = try await store.insert(textSnapshot("clear me"))
            try await store.clear()
            #expect(try await store.statistics().count == 0)
            #expect(try await store.integrityCheck() == "ok")
        }
        let orphan = root.appendingPathComponent("objects/.staging-crash")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let store = try HistoryStore(root: root, embeddings: nil)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try await store.statistics().count == 0)
    }
    @Test func budgetEvictsOldestAndRejectsOversizeAtomically() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root, diskBudget: 1500, embeddings: nil)
        for index in 0..<5 { _ = try await store.insert(textSnapshot(String(repeating: "x", count: 400) + "\(index)", date: Date(timeIntervalSince1970: Double(index)))) }
        #expect(try await store.statistics().bytes <= 1500)
        #expect(try await store.recent().first?.text.hasSuffix("4") == true)
        let before = try await store.statistics().count
        await #expect(throws: (any Error).self) { try await store.insert(textSnapshot(String(repeating: "z", count: 2000))) }
        #expect(try await store.statistics().count == before)
        try await store.setDiskBudget(0)
        _ = try await store.insert(textSnapshot(String(repeating: "z", count: 2000)))
        #expect(try await store.statistics().count == before + 1)
    }
    @Test func symlinksAreRejectedWithoutFollowingThem() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/passwd")
        let store = try HistoryStore(root: root.appendingPathComponent("history"), embeddings: nil)
        await #expect(throws: (any Error).self) {
            try await store.insert(ClipboardSnapshot(items: [.init([.init(type: "public.file-url", data: Data(link.absoluteString.utf8))])]))
        }
        #expect(try await store.statistics().count == 0)
    }
}

@Suite("Paste gesture")
struct GestureTests {
    @Test func quickPasteCommitsOnce() {
        var gesture = PasteGesture()
        #expect(gesture.handle(.paste(repeated: false)) == [.begin])
        #expect(gesture.handle(.releaseCommand) == [.commit])
        #expect(gesture.handle(.releaseCommand).isEmpty)
        #expect(!gesture.active)
    }
    @Test func repeatedPhysicalTapsCycleButAutorepeatDoesNot() {
        var gesture = PasteGesture()
        _ = gesture.handle(.paste(repeated: false))
        #expect(gesture.handle(.paste(repeated: true)).isEmpty)
        #expect(gesture.handle(.paste(repeated: false)) == [.move(1)])
        #expect(gesture.handle(.previous) == [.move(-1)])
        #expect(gesture.handle(.releaseCommand) == [.commit])
    }
    @Test func escapeNeverPastes() {
        var gesture = PasteGesture()
        _ = gesture.handle(.paste(repeated: false))
        #expect(gesture.handle(.cancel) == [.dismiss])
        #expect(gesture.handle(.releaseCommand).isEmpty)
    }
    @Test func latchedSearchSurvivesCommandRelease() {
        var gesture = PasteGesture()
        #expect(gesture.handle(.latch) == [.begin, .latch])
        #expect(gesture.handle(.releaseCommand).isEmpty)
        #expect(gesture.active && gesture.latched)
        gesture.reset()
        #expect(!gesture.active && !gesture.latched)
    }
}

private final class TestEmbedding: EmbeddingProvider {
    var available: Bool { true }
    func vector(for text: String) -> [Float]? {
        if text.contains("automobile") || text.contains("car") { return [1, 0, 0] }
        if text.contains("cake") { return [0, 1, 0] }
        return [0, 0, 1]
    }
}
@Suite("Local semantic search")
struct SearchTests {
    @Test func resultPagesRemainDisjointAcrossMatchTypes() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root, embeddings: TestEmbedding())
        for index in 0..<175 {
            _ = try await store.insert(textSnapshot("car \(index)", date: Date(timeIntervalSince1970: Double(index))))
        }
        for index in 0..<25 { _ = try await store.insert(textSnapshot("automobile \(index)")) }
        var ids: [String] = []
        for offset in stride(from: 0, to: 240, by: 40) { ids += try await store.search("car", limit: 40, offset: offset).map(\.id) }
        #expect(ids.count == 200)
        #expect(Set(ids).count == 200)
        #expect(try await store.search("car", limit: 200).map(\.id) == ids)
    }
    @Test func meaningFindsEntriesWithoutSharedWords() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root, embeddings: TestEmbedding())
        _ = try await store.insert(textSnapshot("automobile maintenance"))
        _ = try await store.insert(textSnapshot("cake recipe"))
        let result = try await store.search("car repairs")
        #expect(result.map(\.title) == ["automobile maintenance"])
    }
    @Test func malformedVectorsCannotCrashSearch() {
        #expect(VectorMath.normalized([]) == nil)
        #expect(VectorMath.normalized([.nan, 1]) == nil)
        #expect(VectorMath.normalized([0, 0]) == nil)
        #expect(VectorMath.similarity([1], [1, 2]) == -1)
        #expect(VectorMath.decode(Data([1, 2, 3])).isEmpty)
    }
    @Test func nativeModelCanFindRelatedLanguage() {
        let model = LocalEmbedding()
        guard model.available else { print("Native sentence model unavailable; lexical fallback remains active."); return }
        let car = model.vector(for: "I need to repair my car")!
        let related = model.vector(for: "automobile maintenance and vehicle repairs")!
        let other = model.vector(for: "baking a delicious chocolate cake")!
        #expect(VectorMath.similarity(car, related) > VectorMath.similarity(car, other))
        print("Native semantic similarity: related=\(VectorMath.similarity(car, related)), unrelated=\(VectorMath.similarity(car, other))")
    }
}

@Suite("Pasteboard integration", .serialized)
struct PasteboardTests {
    @Test func namedPasteboardRoundTripDoesNotTouchUserClipboard() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let items = [ClipboardItem([.init(type: "public.utf8-plain-text", data: Data("hello".utf8)), .init(type: "com.example.bytes", data: Data([0, 1, 255]))])]
        #expect(PasteboardIO.write(items, to: board, markGenerated: false))
        let snapshot = try #require(try PasteboardIO.read(board, source: "Tests"))
        #expect(Set(snapshot.items[0].representations.map(\.type)) == Set(items[0].representations.map(\.type)))
        for rep in items[0].representations { #expect(snapshot.items[0].data(for: rep.type) == rep.data) }
        #expect(PasteboardIO.write(items, to: board))
        #expect(try PasteboardIO.read(board, source: "Tests") == nil)
    }
}
