import Foundation
import Observation
import SQLite3

/// The device's copy of all synced data.
///
/// Every row is held in memory as a field map (habit data is small) and
/// saved to SQLite with the same tables as the Flutter app. Local edits
/// apply straight away and wait in an outbox until sync delivers them.
@MainActor
@Observable
public final class LocalStore {
    /// table → row id → fields. Views that read it update when it changes.
    public private(set) var tables: [String: [String: Fields]] = [:]

    @ObservationIgnored private let db: SQLiteDatabase
    @ObservationIgnored private var hlcs: [String: HLC] = [:]
    @ObservationIgnored private var clock: HLC
    @ObservationIgnored public let nodeId: String

    /// Called after every local edit, so sync can send it soon.
    @ObservationIgnored public var onLocalWrite: (() -> Void)?

    /// Bumped when device settings in `meta` change (signing in and out).
    public private(set) var metaRevision = 0

    /// Bumped whenever any synced data changes, so results worked out from
    /// it can be reused until then.
    public private(set) var revision = 0

    public init(path: String? = nil) throws {
        db = try SQLiteDatabase(path: path ?? ":memory:")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS fields (
              tbl TEXT NOT NULL,
              row_id TEXT NOT NULL,
              field TEXT NOT NULL,
              value TEXT,
              hlc TEXT NOT NULL,
              PRIMARY KEY (tbl, row_id, field)
            );
            CREATE TABLE IF NOT EXISTS outbox (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              change TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            """)
        let existing = try db.query("SELECT value FROM meta WHERE key = 'nodeId'").first?[0]
        let node = existing.flatMap { $0 } ?? Self.randomId(bytes: 8)
        nodeId = node
        if existing == nil {
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('nodeId', ?)", [node])
        }
        var latest = HLC.zero(node)
        var loaded: [String: [String: Fields]] = [:]
        for row in try db.query("SELECT tbl, row_id, field, value, hlc FROM fields") {
            guard let table = row[0], let id = row[1], let field = row[2],
                let packed = row[4], let hlc = HLC.parse(packed)
            else { continue }
            loaded[table, default: [:]][id, default: [:]][field] = JSONValue.decode(row[3] ?? "null")
            hlcs[Self.key(table, id, field)] = hlc
            if hlc > latest { latest = HLC(hlc.millis, hlc.counter, node) }
        }
        tables = loaded
        clock = latest
    }

    private static func key(_ t: String, _ r: String, _ f: String) -> String { "\(t)\u{1}\(r)\u{1}\(f)" }

    static func randomId(bytes: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }
            .joined()
    }

    /// A new globally unique row id.
    public func newId() -> String { Self.randomId(bytes: 12) }

    /// All rows in a table, including deleted ones.
    public func table(_ name: String) -> [String: Fields] { tables[name] ?? [:] }

    public func row(_ table: String, _ id: String) -> Fields? { tables[table]?[id] }

    /// Sets fields on a row, creating it if needed, and queues the change.
    public func write(_ table: String, _ rowId: String, _ fields: Fields) {
        guard !fields.isEmpty else { return }
        clock = clock.send(Self.nowMillis())
        let hlc = clock
        let encoder = JSONEncoder()
        do {
            try db.transaction {
                for (field, value) in fields {
                    let change = Change(table: table, rowId: rowId, field: field, value: value, hlc: hlc)
                    try applyAndPersist(change)
                    let json = String(decoding: try encoder.encode(change), as: UTF8.self)
                    try db.run("INSERT INTO outbox (change) VALUES (?)", [json])
                }
            }
        } catch {
            assertionFailure("Couldn't save: \(error)")
        }
        revision += 1
        onLocalWrite?()
    }

    /// Applies changes from the server and records the new cursor.
    public func applyRemote(_ changes: [Change], cursor: Int) throws {
        let now = Self.nowMillis()
        try db.transaction {
            for c in changes {
                clock = clock.receive(c.hlc, now)
                try applyAndPersist(c)
            }
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('cursor', ?)", [String(cursor)])
        }
        if !changes.isEmpty { revision += 1 }
    }

    @discardableResult
    private func applyAndPersist(_ c: Change) throws -> Bool {
        let k = Self.key(c.table, c.rowId, c.field)
        guard shouldApply(c.hlc, over: hlcs[k]) else { return false }
        tables[c.table, default: [:]][c.rowId, default: [:]][c.field] = c.value
        hlcs[k] = c.hlc
        try db.run(
            "INSERT OR REPLACE INTO fields (tbl, row_id, field, value, hlc) VALUES (?, ?, ?, ?, ?)",
            [c.table, c.rowId, c.field, c.value.encoded(), c.hlc.pack()])
        return true
    }

    /// Deletes all synced data and queued changes, e.g. when someone else
    /// signs in on this device. Device settings are kept.
    public func reset() {
        try? db.execute("DELETE FROM fields; DELETE FROM outbox;")
        setMeta("cursor", "0")
        tables = [:]
        hlcs = [:]
        revision += 1
    }

    public var cursor: Int { Int(meta("cursor") ?? "") ?? 0 }

    public var pendingCount: Int {
        Int((try? db.query("SELECT COUNT(*) FROM outbox").first?[0]).flatMap { $0 } ?? "0") ?? 0
    }

    /// The oldest queued changes, with the outbox id of the last one.
    public func pending(limit: Int = 500) -> (changes: [Change], lastId: Int) {
        let rows = (try? db.query("SELECT id, change FROM outbox ORDER BY id LIMIT ?", [String(limit)])) ?? []
        let decoder = JSONDecoder()
        let changes = rows.compactMap { row in
            row[1].flatMap { try? decoder.decode(Change.self, from: Data($0.utf8)) }
        }
        return (changes, rows.last.flatMap { $0[0] }.flatMap { Int($0) } ?? 0)
    }

    public func markSent(upTo lastId: Int) {
        try? db.run("DELETE FROM outbox WHERE id <= ?", [String(lastId)])
    }

    public func meta(_ key: String) -> String? {
        _ = metaRevision  // so views reading device settings update
        return (try? db.query("SELECT value FROM meta WHERE key = ?", [key]).first?[0]).flatMap { $0 }
    }

    public func setMeta(_ key: String, _ value: String?) {
        try? db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [key, value])
        metaRevision += 1
    }

    static func nowMillis() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}

/// A small wrapper over SQLite's C interface.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    init(path: String) throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            throw Failure(description: "Couldn't open the database at \(path).")
        }
    }

    deinit { sqlite3_close(handle) }

    private var lastError: Failure { Failure(description: String(cString: sqlite3_errmsg(handle))) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError }
    }

    private func prepare(_ sql: String, _ args: [String?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            if let arg {
                sqlite3_bind_text(statement, Int32(i + 1), arg, -1, transient)
            } else {
                sqlite3_bind_null(statement, Int32(i + 1))
            }
        }
        return statement
    }

    func run(_ sql: String, _ args: [String?] = []) throws {
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError }
    }

    /// Every row, with each column as text.
    func query(_ sql: String, _ args: [String?] = []) throws -> [[String?]] {
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw lastError }
            rows.append((0..<sqlite3_column_count(statement)).map { i in
                sqlite3_column_text(statement, i).map { String(cString: $0) }
            })
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
