import Foundation
import SQLite3

private let learningTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct UserWordKey: Hashable, Sendable {
    let text: String
    let baseKey: String
    let toneKey: String

    var syllableCount: Int { toneKey.count }

    var initialKey: String {
        baseKey.split(separator: "\u{1f}").map { String($0.prefix(1)) }.joined(separator: "\u{1f}")
    }

    var isValid: Bool {
        let bases = baseKey.split(separator: "\u{1f}")
        return !text.isEmpty && text.count == bases.count && bases.count == toneKey.count
            && (1...8).contains(bases.count)
            && toneKey.allSatisfy { "12345".contains($0) }
            && text.unicodeScalars.allSatisfy(Self.isHan)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }
}

struct UserWordRecord: Equatable, Sendable {
    let key: UserWordKey
    let count: Int
    let isLearned: Bool
}

enum UserLearningError: Error {
    case database(String)
    case unsupportedSchema(Int)
}

/// A separate database in the App Group. The bundled dictionary is never opened for writing.
final class UserLearningStore: @unchecked Sendable {
    static let fileName = "user-learning.sqlite3"
    static let schemaVersion = 1

    private let queue = DispatchQueue(label: "com.wirelesseye.FlickZhuyin.UserLearningStore")
    private let database: OpaquePointer
    private let writable: Bool
    private var cachedCounts: [UserWordKey: Int] = [:]
    private var lastDataVersion: Int?

    init(url: URL, writable: Bool) throws {
        self.writable = writable
        var handle: OpaquePointer?
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw UserLearningError.database("open: \(status)")
        }
        database = handle
        do {
            sqlite3_busy_timeout(handle, 1000)
            let version = try Self.scalar(handle, sql: "PRAGMA user_version")
            if writable && version == 0 {
                try Self.execute(handle, sql: """
                    CREATE TABLE IF NOT EXISTS user_entry (
                        text TEXT NOT NULL,
                        base_key TEXT NOT NULL,
                        tone_key TEXT NOT NULL,
                        initial_key TEXT NOT NULL,
                        syllable_count INTEGER NOT NULL,
                        selection_count INTEGER NOT NULL,
                        is_learned INTEGER NOT NULL,
                        PRIMARY KEY (text, base_key, tone_key)
                    ) WITHOUT ROWID;
                    CREATE INDEX IF NOT EXISTS user_entry_base
                    ON user_entry(base_key, syllable_count);
                    CREATE INDEX IF NOT EXISTS user_entry_initial
                    ON user_entry(initial_key, syllable_count, selection_count DESC);
                    PRAGMA user_version = 1;
                    """)
            } else if version != Self.schemaVersion {
                throw UserLearningError.unsupportedSchema(version)
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    func countSnapshot() throws -> [UserWordKey: Int] {
        try queue.sync {
            let version = try Self.scalar(database, sql: "PRAGMA data_version")
            if lastDataVersion == version { return cachedCounts }
            var counts: [UserWordKey: Int] = [:]
            try query(
                "SELECT text, base_key, tone_key, selection_count, is_learned FROM user_entry"
            ) { statement in
                let entry = try Self.record(statement)
                counts[entry.key] = entry.count
            }
            cachedCounts = counts
            lastDataVersion = version
            return counts
        }
    }

    func exactRecords(baseKey: String, syllableCount: Int) throws -> [UserWordRecord] {
        try records(
            sql: """
                SELECT text, base_key, tone_key, selection_count, is_learned
                FROM user_entry WHERE base_key = ? AND syllable_count = ? AND is_learned = 1
                ORDER BY selection_count DESC LIMIT 256
                """,
            key: baseKey,
            syllableCount: syllableCount
        )
    }

    func patternRecords(initialKey: String, syllableCount: Int, scanLimit: Int) throws -> [UserWordRecord] {
        try records(
            sql: """
                SELECT text, base_key, tone_key, selection_count, is_learned
                FROM user_entry WHERE initial_key = ? AND syllable_count = ? AND is_learned = 1
                ORDER BY selection_count DESC LIMIT ?
                """,
            key: initialKey,
            syllableCount: syllableCount,
            limit: scanLimit
        )
    }

    func record(_ entries: [(key: UserWordKey, isLearned: Bool)]) throws {
        guard writable, !entries.isEmpty else { return }
        try queue.sync {
            try Self.execute(database, sql: "BEGIN IMMEDIATE")
            do {
                let sql = """
                    INSERT INTO user_entry
                    (text, base_key, tone_key, initial_key, syllable_count, selection_count, is_learned)
                    VALUES (?, ?, ?, ?, ?, 1, ?)
                    ON CONFLICT(text, base_key, tone_key) DO UPDATE SET
                    selection_count = selection_count + 1,
                    is_learned = MAX(is_learned, excluded.is_learned)
                    """
                let statement = try Self.prepare(database, sql: sql)
                defer { sqlite3_finalize(statement) }
                for entry in entries where entry.key.isValid {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try Self.bind(entry.key.text, at: 1, to: statement)
                    try Self.bind(entry.key.baseKey, at: 2, to: statement)
                    try Self.bind(entry.key.toneKey, at: 3, to: statement)
                    try Self.bind(entry.key.initialKey, at: 4, to: statement)
                    sqlite3_bind_int(statement, 5, Int32(entry.key.syllableCount))
                    sqlite3_bind_int(statement, 6, entry.isLearned ? 1 : 0)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
                }
                try Self.execute(database, sql: "COMMIT")
                lastDataVersion = nil
            } catch {
                try? Self.execute(database, sql: "ROLLBACK")
                throw error
            }
        }
    }

    func clear() throws {
        guard writable else { return }
        try queue.sync {
            try Self.execute(database, sql: "DELETE FROM user_entry")
            cachedCounts = [:]
            lastDataVersion = nil
        }
    }

    private func records(sql: String, key: String, syllableCount: Int, limit: Int? = nil) throws -> [UserWordRecord] {
        try queue.sync {
            var result: [UserWordRecord] = []
            try query(sql) { statement in
                try Self.bind(key, at: 1, to: statement)
                sqlite3_bind_int(statement, 2, Int32(syllableCount))
                if let limit { sqlite3_bind_int(statement, 3, Int32(limit)) }
            } row: { statement in
                result.append(try Self.record(statement))
            }
            return result
        }
    }

    private func query(_ sql: String, row: (OpaquePointer) throws -> Void) throws {
        try query(sql, bind: { _ in }, row: row)
    }

    private func query(
        _ sql: String,
        bind: (OpaquePointer) throws -> Void,
        row: (OpaquePointer) throws -> Void
    ) throws {
        let statement = try Self.prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw error() }
            try row(statement)
        }
    }

    private static func record(_ statement: OpaquePointer) throws -> UserWordRecord {
        guard let text = sqlite3_column_text(statement, 0),
              let base = sqlite3_column_text(statement, 1),
              let tone = sqlite3_column_text(statement, 2)
        else { throw UserLearningError.database("null word") }
        return UserWordRecord(
            key: UserWordKey(
                text: String(cString: text),
                baseKey: String(cString: base),
                toneKey: String(cString: tone)
            ),
            count: Int(sqlite3_column_int(statement, 3)),
            isLearned: sqlite3_column_int(statement, 4) != 0
        )
    }

    private static func prepare(_ database: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw UserLearningError.database(String(cString: sqlite3_errmsg(database))) }
        return statement
    }

    private static func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, learningTransient) == SQLITE_OK else {
            throw UserLearningError.database("bind failed")
        }
    }

    private static func scalar(_ database: OpaquePointer, sql: String) throws -> Int {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UserLearningError.database(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw UserLearningError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func error() -> UserLearningError {
        .database(String(cString: sqlite3_errmsg(database)))
    }
}
