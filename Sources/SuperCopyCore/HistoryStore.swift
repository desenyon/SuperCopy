import Foundation
import CSQLite
import CryptoKit
import UniformTypeIdentifiers

public actor HistoryStore {
    public let root: URL
    private let objects: URL
    private let db: Database
    private let embeddings: EmbeddingProvider?
    private var diskBudget: Int64
    private var pendingRestores = Set<String>()
    private var indexingImage = false
    private let recognizeImage: @Sendable (URL) -> String
    private let fm = FileManager.default
    private let columns = "id,title,substr(text,1,600),kind,source,created,last_used,bytes,thumbnail"

    struct Manifest: Codable {
        struct Rep: Codable { let type: String; let path: String }
        struct Item: Codable { let representations: [Rep]; let archivedFile: String? }
        let items: [Item]
    }
    public struct Statistics: Sendable { public let count: Int; public let bytes: Int64; public let semanticAvailable: Bool }

    public init(root: URL, diskBudget: Int64 = 10 * 1024 * 1024 * 1024, embeddings: EmbeddingProvider? = LocalEmbedding(),
                recognizeImage: @escaping @Sendable (URL) -> String = { ImageRecognition.recognize(at: $0) }) throws {
        self.root = root; self.objects = root.appendingPathComponent("objects", isDirectory: true)
        self.diskBudget = max(0, diskBudget); self.embeddings = embeddings
        self.recognizeImage = recognizeImage
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        db = try Database(path: root.appendingPathComponent("history.sqlite").path)
        let known = Set(try db.query("SELECT id FROM entries") { Database.string($0, 0) })
        for url in try FileManager.default.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil) where !known.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
        // A committed entry always owns a complete directory. Remove externally damaged entries.
        for id in known where !FileManager.default.fileExists(atPath: objects.appendingPathComponent(id).appendingPathComponent("manifest.json").path) {
            try db.run("DELETE FROM entries WHERE id=?", [.text(id)])
        }
    }

    @discardableResult public func insert(_ snapshot: ClipboardSnapshot) throws -> String? {
        guard !snapshot.items.isEmpty else { return nil }
        guard !snapshot.items.contains(where: { CapturePolicy.shouldIgnore(types: $0.representations.map(\.type)) }) else { return nil }
        guard snapshot.byteCount <= CapturePolicy.maxPasteboardBytes else { throw HistoryError.tooLarge }
        guard snapshot.items.allSatisfy({ !$0.representations.isEmpty }) else { throw HistoryError.invalidPayload }
        var fingerprint = snapshot.fingerprint
        let hasFiles = snapshot.items.contains { $0.fileURL != nil }
        if !hasFiles, let id = try db.query("SELECT id FROM entries WHERE fingerprint=?", [.text(fingerprint)], map: { Database.string($0, 0) }).first {
            try db.run("UPDATE entries SET last_used=? WHERE id=?", [.number(snapshot.capturedAt.timeIntervalSince1970), .text(id)])
            return id
        }
        let id = UUID().uuidString
        let staging = objects.appendingPathComponent(".staging-\(id)", isDirectory: true)
        let final = objects.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var published = false
        defer {
            try? fm.removeItem(at: staging)
            if !published { try? fm.removeItem(at: final) }
        }
        var bytes = Int64(snapshot.byteCount)
        var fileBytes: Int64 = 0
        var manifestItems: [Manifest.Item] = []
        for (i, item) in snapshot.items.enumerated() {
            var reps: [Manifest.Rep] = []
            for (j, rep) in item.representations.enumerated() {
                let path = "\(i)-\(j).data"
                try rep.data.write(to: staging.appendingPathComponent(path), options: .atomic)
                reps.append(.init(type: rep.type, path: path))
            }
            var archived: String?
            if let original = item.fileURL {
                let size = try checkedFileSize(original, remaining: CapturePolicy.maxFileBytes - fileBytes)
                fileBytes += size
                let directory = "files/\(i)"
                try fm.createDirectory(at: staging.appendingPathComponent(directory), withIntermediateDirectories: true)
                let path = "\(directory)/\(original.lastPathComponent)"
                do { try fm.copyItem(at: original, to: staging.appendingPathComponent(path)) }
                catch { throw HistoryError.inaccessibleFile(original.lastPathComponent) }
                // Recheck after copying: changing source files must not bypass the byte limit.
                let copied = try checkedFileSize(staging.appendingPathComponent(path), remaining: CapturePolicy.maxFileBytes - (fileBytes - size))
                fileBytes += copied - size
                archived = path
            }
            manifestItems.append(.init(representations: reps, archivedFile: archived))
        }
        bytes += fileBytes
        var analysisSnapshot = snapshot
        if hasFiles {
            fingerprint = try archiveFingerprint(base: fingerprint, directory: staging, items: manifestItems)
            if let existing = try db.query("SELECT id FROM entries WHERE fingerprint=?", [.text(fingerprint)], map: { Database.string($0, 0) }).first {
                try db.run("UPDATE entries SET last_used=? WHERE id=?", [.number(snapshot.capturedAt.timeIntervalSince1970), .text(existing)])
                return existing
            }
            for (index, item) in manifestItems.enumerated() {
                if let path = item.archivedFile {
                    analysisSnapshot.items[index].representations.removeAll { $0.type == "public.file-url" }
                    analysisSnapshot.items[index].representations.append(.init(type: "public.file-url", data: Data(staging.appendingPathComponent(path).absoluteString.utf8)))
                }
            }
        }
        var analysis = autoreleasepool { ContentAnalysis.analyze(analysisSnapshot) }
        let needsOCR = analysis.imageForOCR != nil
        analysis.imageForOCR = nil
        let thumbnailPath: String?
        if let thumbnail = analysis.thumbnail {
            try thumbnail.write(to: staging.appendingPathComponent("preview.png"), options: .atomic)
            bytes += Int64(thumbnail.count); thumbnailPath = "preview.png"
        } else { thumbnailPath = nil }
        let manifest = try JSONEncoder().encode(Manifest(items: manifestItems))
        try manifest.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        bytes += Int64(manifest.count)
        guard diskBudget == 0 || bytes <= diskBudget else { throw HistoryError.tooLarge }
        let vector = embeddings?.vector(for: analysis.text.isEmpty ? analysis.title : analysis.text)
        try fm.moveItem(at: staging, to: final)
        try db.transaction {
            try db.run("INSERT INTO entries(id,fingerprint,title,text,kind,source,created,last_used,bytes,thumbnail,embedding,ocr_pending) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", [
                .text(id), .text(fingerprint), .text(analysis.title), .text(analysis.text), .text(analysis.kind.rawValue),
                .text(snapshot.source), .number(snapshot.capturedAt.timeIntervalSince1970), .number(snapshot.capturedAt.timeIntervalSince1970),
                .integer(bytes), thumbnailPath.map(Database.Value.text) ?? .null,
                VectorMath.encode(vector).map(Database.Value.blob) ?? .null, .integer(needsOCR ? 1 : 0)
            ])
        }
        published = true
        try trim()
        return id
    }

    public func recent(limit: Int = 80, offset: Int = 0) throws -> [HistoryEntry] {
        try db.query("SELECT \(columns) FROM entries ORDER BY last_used DESC,id DESC LIMIT ? OFFSET ?", [.integer(Int64(max(0, limit))), .integer(Int64(max(0, offset)))], map: entry)
    }
    /// One bounded job at a time. Awaiting the detached Vision request releases this
    /// actor so clipboard writes, deletes, and searches continue during model startup.
    public func enrichNextImage() async throws -> Bool {
        guard !indexingImage else { return false }
        guard let id = try db.query("SELECT id FROM entries WHERE ocr_pending=1 ORDER BY created ASC LIMIT 1", map: { Database.string($0, 0) }).first else { return false }
        indexingImage = true
        defer { indexingImage = false }
        let folder = objects.appendingPathComponent(id)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        var imageURL: URL?
        for item in manifest.items {
            if let path = item.archivedFile {
                imageURL = try safeURL(path, in: folder); break
            }
            if let rep = item.representations.first(where: { UTType($0.type)?.conforms(to: .image) == true }) {
                imageURL = try safeURL(rep.path, in: folder); break
            }
        }
        guard let imageURL else { try db.run("UPDATE entries SET ocr_pending=0 WHERE id=?", [.text(id)]); return true }
        let recognize = recognizeImage
        let text = await Task.detached(priority: .utility) { recognize(imageURL) }.value
        try Task.checkCancellation()
        guard let old = try entry(id: id) else { return true }
        let existingText = try db.query("SELECT text FROM entries WHERE id=?", [.text(id)]) { Database.string($0, 0) }.first ?? ""
        let updated = text.isEmpty ? existingText : String((existingText + "\n" + text).prefix(64_000))
        let title = old.title == "Image" && !text.isEmpty ? String(text.split(whereSeparator: \.isNewline).first?.prefix(240) ?? "Image") : old.title
        let vector = embeddings?.vector(for: updated)
        try db.run("UPDATE entries SET title=?,text=?,embedding=?,ocr_pending=0 WHERE id=?", [
            .text(title), .text(updated), VectorMath.encode(vector).map(Database.Value.blob) ?? .null, .text(id)
        ])
        return true
    }
    public func entry(id: String) throws -> HistoryEntry? {
        try db.query("SELECT \(columns) FROM entries WHERE id=?", [.text(id)], map: entry).first
    }
    public func search(_ query: String, limit: Int = 80, offset: Int = 0) throws -> [HistoryEntry] {
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !text.isEmpty else { return try recent(limit: limit, offset: offset) }
        guard limit > 0 else { return [] }
        try Task.checkCancellation()
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let literal = "(text LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')"
        let literalValues: [Database.Value] = [.text("%\(escaped)%"), .text("%\(escaped)%")]
        let literalCount = try db.query("SELECT COUNT(*) FROM entries WHERE \(literal)", literalValues) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        var skip = max(0, offset)
        var ids: [String] = []
        if skip < literalCount {
            ids = try db.query("SELECT id FROM entries WHERE \(literal) ORDER BY last_used DESC,id DESC LIMIT ? OFFSET ?",
                               literalValues + [.integer(Int64(limit)), .integer(Int64(skip))]) { Database.string($0, 0) }
        }
        skip = max(0, skip - literalCount)
        let words = text.split { !$0.isLetter && !$0.isNumber }.prefix(20)
        let expression = words.map { "\"\($0)\"*" }.joined(separator: " AND ")
        var exclusion = "NOT \(literal)"
        var exclusionValues = literalValues
        if !expression.isEmpty {
            let prefixFilter = "id IN (SELECT id FROM entries_fts WHERE entries_fts MATCH ?) AND NOT \(literal)"
            let prefixValues: [Database.Value] = [.text(expression)] + literalValues
            let count = try db.query("SELECT COUNT(*) FROM entries WHERE \(prefixFilter)", prefixValues) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
            if ids.count < limit, skip < count {
                ids += try db.query("SELECT id FROM entries WHERE \(prefixFilter) ORDER BY last_used DESC,id DESC LIMIT ? OFFSET ?",
                                    prefixValues + [.integer(Int64(limit - ids.count)), .integer(Int64(skip))]) { Database.string($0, 0) }
            }
            skip = max(0, skip - count)
            exclusion += " AND id NOT IN (SELECT id FROM entries_fts WHERE entries_fts MATCH ?)"
            exclusionValues += [.text(expression)]
        }
        // Fixed, disjoint relevance tiers make paging stable: literal, word prefix,
        // then semantic neighbors. Increasing the page size cannot reorder old pages.
        if ids.count < limit, text.count >= 3, let vector = embeddings?.vector(for: text) {
            let capacity = skip + limit - ids.count
            var best: [(String, Float)] = []
            func before(_ a: (String, Float), _ b: (String, Float)) -> Bool { a.1 == b.1 ? a.0 > b.0 : a.1 > b.1 }
            try db.forEach("SELECT id,embedding FROM entries WHERE embedding IS NOT NULL AND \(exclusion)", exclusionValues) { row in
                try Task.checkCancellation()
                guard let data = Database.data(row, 1) else { return }
                let candidate = (Database.string(row, 0), VectorMath.similarity(vector, VectorMath.decode(data)))
                guard candidate.1 >= 0.35 else { return }
                if best.count < capacity || before(candidate, best.last!) {
                    best.append(candidate); best.sort(by: before)
                    if best.count > capacity { best.removeLast() }
                }
            }
            ids += best.dropFirst(skip).map { $0.0 }
        }
        try Task.checkCancellation()
        return try ids.compactMap { try entry(id: $0) }
    }
    public func restore(id: String) throws -> [ClipboardItem] {
        guard try entry(id: id) != nil else { throw HistoryError.invalidPayload }
        let directory = objects.appendingPathComponent(id)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        // Clipboard file URLs need a lifetime independent of retention or Clear History.
        let lease = root.appendingPathComponent("clipboard", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        if manifest.items.contains(where: { $0.archivedFile != nil }) {
            if !fm.fileExists(atPath: lease.path) {
                try fm.createDirectory(at: lease.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                do { try fm.copyItem(at: directory.appendingPathComponent("files"), to: lease) }
                catch { try? fm.removeItem(at: lease); throw error }
            }
        }
        var total = 0
        let items = try manifest.items.map { item -> ClipboardItem in
            var reps = try item.representations.map { rep -> Representation in
                let url = try safeURL(rep.path, in: directory)
                let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                total += size
                guard total <= CapturePolicy.maxPasteboardBytes else { throw HistoryError.tooLarge }
                return Representation(type: rep.type, data: try Data(contentsOf: url))
            }
            if let path = item.archivedFile {
                guard path.hasPrefix("files/") else { throw HistoryError.invalidPayload }
                let url = try safeURL(String(path.dropFirst(6)), in: lease)
                guard fm.fileExists(atPath: url.path) else { throw HistoryError.inaccessibleFile(url.lastPathComponent) }
                reps.removeAll { ["public.file-url", "NSFilenamesPboardType", "com.apple.finder.node", "com.apple.pasteboard.promised-file-url"].contains($0.type) }
                reps.append(Representation(type: "public.file-url", data: Data(url.absoluteString.utf8)))
            }
            return ClipboardItem(reps)
        }
        if manifest.items.contains(where: { $0.archivedFile != nil }) { pendingRestores.insert(id) }
        return items
    }
    public func finishRestore(id: String) { pendingRestores.remove(id) }
    /// A pasted entry is the clipboard again, so it returns to the top of history.
    public func touch(id: String, at date: Date = Date()) throws {
        try db.run("UPDATE entries SET last_used=? WHERE id=?", [.number(date.timeIntervalSince1970), .text(id)])
    }
    public func pruneClipboardFiles(referencedURLs: [URL]) throws {
        let directory = root.appendingPathComponent("clipboard", isDirectory: true)
        guard fm.fileExists(atPath: directory.path) else { return }
        for lease in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard !pendingRestores.contains(lease.lastPathComponent),
                  !referencedURLs.contains(where: { $0.standardizedFileURL.path.hasPrefix(lease.standardizedFileURL.path + "/") }) else { continue }
            try fm.removeItem(at: lease)
        }
    }
    public func delete(id: String) throws {
        guard UUID(uuidString: id) != nil else { throw HistoryError.invalidPayload }
        try db.run("DELETE FROM entries WHERE id=?", [.text(id)])
        let directory = objects.appendingPathComponent(id)
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try db.checkpoint()
    }
    public func clear() throws {
        try db.transaction { try db.execute("DELETE FROM entries") }
        for url in try fm.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil) { try fm.removeItem(at: url) }
        try db.execute("INSERT INTO entries_fts(entries_fts) VALUES('rebuild')")
        try db.checkpoint()
        try db.execute("VACUUM")
    }
    public func setDiskBudget(_ bytes: Int64) throws { diskBudget = max(0, bytes); try trim() }
    public func statistics() throws -> Statistics {
        let pair = try db.query("SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM entries") { (Int(sqlite3_column_int64($0, 0)), sqlite3_column_int64($0, 1)) }.first!
        return Statistics(count: pair.0, bytes: pair.1, semanticAvailable: embeddings?.available ?? false)
    }
    public func integrityCheck() throws -> String { try db.query("PRAGMA integrity_check") { Database.string($0, 0) }.joined(separator: "\n") }
    private func trim() throws {
        guard diskBudget > 0 else { return }
        var total = try db.query("SELECT COALESCE(SUM(bytes),0) FROM entries") { sqlite3_column_int64($0, 0) }.first ?? 0
        while total > diskBudget {
            guard let oldest = try db.query("SELECT id,bytes FROM entries ORDER BY last_used ASC,id ASC LIMIT 1", map: { (Database.string($0, 0), sqlite3_column_int64($0, 1)) }).first else { break }
            try delete(id: oldest.0); total -= oldest.1
        }
    }
    private func entry(_ s: OpaquePointer) -> HistoryEntry {
        let id = Database.string(s, 0), thumb = Database.string(s, 8)
        return HistoryEntry(id: id, title: Database.string(s, 1), text: Database.string(s, 2),
                            kind: ClipKind(rawValue: Database.string(s, 3)) ?? .other, source: Database.string(s, 4),
                            created: Date(timeIntervalSince1970: sqlite3_column_double(s, 5)),
                            lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(s, 6)),
                            byteCount: sqlite3_column_int64(s, 7), thumbnailPath: thumb.isEmpty ? nil : objects.appendingPathComponent(id).appendingPathComponent(thumb).path)
    }
    private func safeURL(_ path: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(directory.standardizedFileURL.path + "/"), !path.hasPrefix("/") else { throw HistoryError.invalidPayload }
        return url
    }
    private func checkedFileSize(_ url: URL, remaining: Int64) throws -> Int64 {
        guard remaining >= 0 else { throw HistoryError.tooLarge }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { throw HistoryError.inaccessibleFile(url.lastPathComponent) }
        if values.isDirectory != true {
            guard values.isRegularFile == true else { throw HistoryError.inaccessibleFile(url.lastPathComponent) }
            let size = Int64(values.fileSize ?? 0)
            guard size <= remaining else { throw HistoryError.tooLarge }
            return size
        }
        var failure: Error?
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in failure = error; return false }) else { throw HistoryError.inaccessibleFile(url.lastPathComponent) }
        var total: Int64 = 0, count = 0
        for case let child as URL in enumerator {
            count += 1
            guard count <= 100_000 else { throw HistoryError.tooLarge }
            let v = try child.resourceValues(forKeys: keys)
            guard v.isSymbolicLink != true, v.isDirectory == true || v.isRegularFile == true else { throw HistoryError.inaccessibleFile(child.lastPathComponent) }
            total += Int64(v.fileSize ?? 0)
            guard total <= remaining else { throw HistoryError.tooLarge }
        }
        if failure != nil { throw HistoryError.inaccessibleFile(url.lastPathComponent) }
        return total
    }
    private func archiveFingerprint(base: String, directory: URL, items: [Manifest.Item]) throws -> String {
        var hash = SHA256()
        hash.update(data: Data(base.utf8))
        for item in items {
            guard let path = item.archivedFile else { continue }
            let root = directory.appendingPathComponent(path)
            var urls = [root]
            if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
                urls += enumerator.compactMap { $0 as? URL }
            }
            for url in urls.sorted(by: { $0.path < $1.path }) {
                let relative = String(url.path.dropFirst(directory.path.count))
                hash.update(data: Data(relative.utf8)); hash.update(data: Data([0]))
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
                hash.update(data: Data([0]))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
