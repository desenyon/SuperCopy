import Foundation
import CSQLite

final class Database {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let db { sqlite3_close(db) }; db = nil
            throw HistoryError.database(message)
        }
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA secure_delete=ON")
        let version = try query("PRAGMA user_version") { sqlite3_column_int($0, 0) }.first ?? 0
        guard version <= 2 else { throw HistoryError.unsupportedVersion }
        try execute("""
        CREATE TABLE IF NOT EXISTS entries (
          id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
          text TEXT NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL,
          created REAL NOT NULL, last_used REAL NOT NULL, bytes INTEGER NOT NULL,
          thumbnail TEXT, embedding BLOB
        );
        CREATE INDEX IF NOT EXISTS entries_recent ON entries(last_used DESC, id DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(id UNINDEXED, title, text, source, tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS entries_insert AFTER INSERT ON entries BEGIN
          INSERT INTO entries_fts(id,title,text,source) VALUES(new.id,new.title,new.text,new.source);
        END;
        CREATE TRIGGER IF NOT EXISTS entries_delete AFTER DELETE ON entries BEGIN
          DELETE FROM entries_fts WHERE id=old.id;
        END;
        CREATE TRIGGER IF NOT EXISTS entries_update AFTER UPDATE OF title,text,source ON entries BEGIN
          DELETE FROM entries_fts WHERE id=old.id;
          INSERT INTO entries_fts(id,title,text,source) VALUES(new.id,new.title,new.text,new.source);
        END;
        """)
        if version < 2 {
            try transaction {
                try execute("ALTER TABLE entries ADD COLUMN ocr_pending INTEGER NOT NULL DEFAULT 0")
                try execute("PRAGMA user_version=2")
            }
        }
        try execute("CREATE INDEX IF NOT EXISTS entries_pending_ocr ON entries(ocr_pending,created)")
    }
    deinit { if let db { sqlite3_close_v2(db) } }
    enum Value { case text(String), number(Double), integer(Int64), blob(Data), null }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    func query<T>(_ sql: String, _ values: [Value] = [], map: (OpaquePointer) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw error() }
            result.append(try map(statement))
        }
    }
    func forEach(_ sql: String, _ values: [Value] = [], body: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw error() }
            try body(statement)
        }
    }
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try operation(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func checkpoint() throws { try execute("PRAGMA wal_checkpoint(TRUNCATE)") }
    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let status: Int32
            switch value {
            case .text(let string): status = sqlite3_bind_text(statement, position, string, -1, Self.transient)
            case .number(let number): status = sqlite3_bind_double(statement, position, number)
            case .integer(let number): status = sqlite3_bind_int64(statement, position, number)
            case .blob(let data):
                status = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), Self.transient) }
            case .null: status = sqlite3_bind_null(statement, position)
            }
            guard status == SQLITE_OK else { sqlite3_finalize(statement); throw error() }
        }
        return statement
    }
    private func error() -> HistoryError { .database(String(cString: sqlite3_errmsg(db))) }
    static func string(_ s: OpaquePointer, _ index: Int32) -> String {
        guard let p = sqlite3_column_text(s, index) else { return "" }
        return String(cString: p)
    }
    static func data(_ s: OpaquePointer, _ index: Int32) -> Data? {
        guard let p = sqlite3_column_blob(s, index) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, index)))
    }
}
