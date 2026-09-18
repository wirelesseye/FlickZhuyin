import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteLexiconStore: LexiconStore, @unchecked Sendable {
    static let defaultCacheCapacity = 256
    static let schemaVersion: Int64 = 2
    static let requiredMetadataKeys = [
        "schema_version",
        "terra_source_repository",
        "terra_source_commit",
        "terra_source_sha256",
        "essay_source_repository",
        "essay_source_commit",
        "essay_source_sha256",
        "dictionary_name",
        "dictionary_version",
        "compiler_version",
        "entry_count",
        "max_syllable_count",
        "essay_entry_count",
        "essay_annotated_entry_count",
        "essay_frequency_max",
        "weight_normalization",
    ]

    private let queue = DispatchQueue(label: "com.wirelesseye.FlickZhuyin.SQLiteLexiconStore")
    private let database: OpaquePointer
    private let exactStatement: OpaquePointer
    private let cacheCapacity: Int
    private let inventory: [String]
    private var cache: [[SyllableConstraint]: [LexiconMatch]] = [:]
    private var cacheOrder: [[SyllableConstraint]] = []

    init(url: URL, cacheCapacity: Int = SQLiteLexiconStore.defaultCacheCapacity) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LexiconStoreError.databaseMissing(url)
        }
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let opened = handle else {
            if let handle {
                sqlite3_close(handle)
            }
            throw LexiconStoreError.openFailed(Self.message(for: status))
        }
        do {
            try Self.validateSchema(opened)
            inventory = try Self.readInventory(opened)
            exactStatement = try Self.prepare(
                opened,
                sql: """
                SELECT text, tone_key, source_weight
                FROM pronunciation
                WHERE base_key = ? AND syllable_count = ?
                ORDER BY id
                """
            )
        } catch {
            sqlite3_close(opened)
            throw error
        }
        database = opened
        self.cacheCapacity = max(1, cacheCapacity)
    }

    convenience init(
        bundle: Bundle,
        resourceName: String = "flickzhuyin",
        resourceExtension: String = "sqlite3",
        cacheCapacity: Int = SQLiteLexiconStore.defaultCacheCapacity
    ) throws {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw LexiconStoreError.resourceNotFound("\(resourceName).\(resourceExtension)")
        }
        try self.init(url: url, cacheCapacity: cacheCapacity)
    }

    deinit {
        sqlite3_finalize(exactStatement)
        sqlite3_close(database)
    }

    func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch] {
        try queue.sync {
            if let cached = cache[syllables] {
                touch(syllables)
                return cached
            }
            let matches = try performQuery(syllables)
            store(matches, for: syllables)
            return matches
        }
    }

    func syllableInventory() throws -> [String] {
        inventory
    }

    private func performQuery(_ constraints: [SyllableConstraint]) throws -> [LexiconMatch] {
        sqlite3_reset(exactStatement)
        sqlite3_clear_bindings(exactStatement)
        let baseKey = constraints.map(\.base).joined(separator: "\u{1f}")
        guard sqlite3_bind_text(exactStatement, 1, baseKey, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_bind_int(exactStatement, 2, Int32(constraints.count)) == SQLITE_OK
        else {
            throw Self.queryError(database)
        }
        var matches: [LexiconMatch] = []
        while true {
            let step = sqlite3_step(exactStatement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw Self.queryError(database)
            }
            guard let textPointer = sqlite3_column_text(exactStatement, 0),
                  let tonePointer = sqlite3_column_text(exactStatement, 1)
            else {
                throw LexiconStoreError.queryFailed("pronunciation row contains NULL text or tone_key")
            }
            let toneKey = String(cString: tonePointer)
            guard toneKey.count == constraints.count else {
                throw LexiconStoreError.queryFailed("tone_key length does not match syllable count")
            }
            var pronunciation: [CanonicalSyllable] = []
            var accepted = true
            var toneIndex = toneKey.startIndex
            for constraint in constraints {
                guard let tone = MandarinTone(digit: toneKey[toneIndex]) else {
                    throw LexiconStoreError.queryFailed("tone_key contains a digit outside 1...5")
                }
                if let expected = constraint.tone, expected != tone {
                    accepted = false
                    break
                }
                pronunciation.append(CanonicalSyllable(base: constraint.base, tone: tone))
                toneIndex = toneKey.index(after: toneIndex)
            }
            guard accepted else { continue }
            let weight: Double?
            if sqlite3_column_type(exactStatement, 2) == SQLITE_NULL {
                weight = nil
            } else {
                weight = sqlite3_column_double(exactStatement, 2)
            }
            matches.append(
                LexiconMatch(
                    text: String(cString: textPointer),
                    pronunciation: pronunciation,
                    sourceWeight: weight
                )
            )
        }
        return matches
    }

    private func touch(_ key: [SyllableConstraint]) {
        if let index = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: index)
        }
        cacheOrder.append(key)
    }

    private func store(_ matches: [LexiconMatch], for key: [SyllableConstraint]) {
        cache[key] = matches
        touch(key)
        while cacheOrder.count > cacheCapacity {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private static func validateSchema(_ database: OpaquePointer) throws {
        let version = try scalarInt(database, sql: "PRAGMA user_version")
        guard version == schemaVersion else {
            throw LexiconStoreError.schemaMismatch("unsupported user_version \(version)")
        }
        let tables = Set(try columnStrings(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        let expected: Set<String> = ["metadata", "syllable_inventory", "pronunciation"]
        let missingTables = expected.subtracting(tables)
        guard missingTables.isEmpty else {
            throw LexiconStoreError.schemaMismatch("missing tables: \(missingTables.sorted().joined(separator: ", "))")
        }
        for key in requiredMetadataKeys {
            guard let value = try scalarString(
                database,
                sql: "SELECT value FROM metadata WHERE key = ?",
                binding: key
            ) else {
                throw LexiconStoreError.schemaMismatch("missing metadata key \(key)")
            }
            if key == "schema_version", value != String(schemaVersion) {
                throw LexiconStoreError.schemaMismatch("schema_version metadata is \(value)")
            }
        }
    }

    private static func readInventory(_ database: OpaquePointer) throws -> [String] {
        try columnStrings(database, sql: "SELECT base FROM syllable_inventory ORDER BY base")
    }

    private static func columnStrings(_ database: OpaquePointer, sql: String) throws -> [String] {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw queryError(database)
            }
            guard let pointer = sqlite3_column_text(statement, 0) else {
                throw LexiconStoreError.queryFailed("unexpected NULL column value")
            }
            values.append(String(cString: pointer))
        }
        return values
    }

    private static func scalarString(
        _ database: OpaquePointer,
        sql: String,
        binding: String? = nil
    ) throws -> String? {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        if let binding {
            guard sqlite3_bind_text(statement, 1, binding, -1, sqliteTransient) == SQLITE_OK else {
                throw queryError(database)
            }
        }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE {
            return nil
        }
        guard step == SQLITE_ROW else {
            throw queryError(database)
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return String(cString: pointer)
    }

    private static func scalarInt(_ database: OpaquePointer, sql: String) throws -> Int64 {
        let statement = try prepare(database, sql: sql)
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            throw queryError(database)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func prepare(_ database: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw queryError(database)
        }
        return statement
    }

    private static func queryError(_ database: OpaquePointer) -> LexiconStoreError {
        let code = sqlite3_errcode(database)
        let message = String(cString: sqlite3_errmsg(database))
        if code == SQLITE_NOTADB || code == SQLITE_CORRUPT {
            return .corruptDatabase(message)
        }
        return .queryFailed(message)
    }

    private static func message(for status: Int32) -> String {
        String(cString: sqlite3_errstr(status))
    }
}
