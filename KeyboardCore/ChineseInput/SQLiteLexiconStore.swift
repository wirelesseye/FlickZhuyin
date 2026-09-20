import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteLexiconStore: LexiconStore, @unchecked Sendable {
    static let defaultCacheCapacity = 256
    static let schemaVersion: Int64 = 4
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
    private let patternStatement: OpaquePointer
    private let inventory: [String]
    private var exactCache: BoundedCache<[SyllableConstraint], [LexiconMatch]>
    private var patternCache: BoundedCache<PatternMatchRequest, [LexiconMatch]>
    private var scanCache: BoundedCache<PatternScanRequest, [ScannedRow]>

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
                SELECT text, tone_key, source_weight, pronunciation_weight
                FROM pronunciation
                WHERE base_key = ? AND syllable_count = ?
                ORDER BY id
                """
            )
            patternStatement = try Self.prepare(
                opened,
                sql: """
                SELECT text, base_key, tone_key, source_weight, pronunciation_weight
                FROM pronunciation
                WHERE initial_key = ? AND syllable_count = ?
                ORDER BY COALESCE(source_weight, pronunciation_weight) DESC, id
                LIMIT ?
                """
            )
        } catch {
            sqlite3_close(opened)
            throw error
        }
        database = opened
        let capacity = max(1, cacheCapacity)
        exactCache = BoundedCache(capacity: capacity)
        patternCache = BoundedCache(capacity: capacity)
        scanCache = BoundedCache(capacity: max(8, capacity / 4))
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
        sqlite3_finalize(patternStatement)
        sqlite3_close(database)
    }

    func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch] {
        try queue.sync {
            if let cached = exactCache.value(for: syllables) {
                return cached
            }
            let matches = try performQuery(syllables)
            exactCache.insert(matches, for: syllables)
            return matches
        }
    }

    func patternMatches(
        for patterns: [SyllableMatchPattern],
        resultLimit: Int,
        scanLimit: Int
    ) throws -> [LexiconMatch] {
        guard !patterns.isEmpty, resultLimit > 0, scanLimit > 0 else { return [] }
        guard let initialKey = Self.initialKey(for: patterns) else { return [] }
        let request = PatternMatchRequest(
            patterns: patterns,
            resultLimit: resultLimit,
            scanLimit: scanLimit
        )
        return try queue.sync {
            if let cached = patternCache.value(for: request) {
                return cached
            }
            let rows = try scannedRows(
                initialKey: initialKey,
                syllableCount: patterns.count,
                scanLimit: scanLimit
            )
            let matches = Self.matches(from: rows, patterns: patterns, resultLimit: resultLimit)
            patternCache.insert(matches, for: request)
            return matches
        }
    }

    func syllableInventory() throws -> [String] {
        inventory
    }

    static func initialKey(for patterns: [SyllableMatchPattern]) -> String? {
        var components: [String] = []
        components.reserveCapacity(patterns.count)
        for pattern in patterns {
            guard let character = pattern.initialCharacter else { return nil }
            components.append(String(character))
        }
        return components.joined(separator: "\u{1f}")
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
            let pronunciationWeight: Double?
            if sqlite3_column_type(exactStatement, 3) == SQLITE_NULL {
                pronunciationWeight = nil
            } else {
                pronunciationWeight = sqlite3_column_double(exactStatement, 3)
            }
            matches.append(
                LexiconMatch(
                    text: String(cString: textPointer),
                    pronunciation: pronunciation,
                    sourceWeight: weight,
                    pronunciationWeight: pronunciationWeight
                )
            )
        }
        return matches
    }

    private func scannedRows(
        initialKey: String,
        syllableCount: Int,
        scanLimit: Int
    ) throws -> [ScannedRow] {
        let request = PatternScanRequest(
            initialKey: initialKey,
            syllableCount: syllableCount,
            scanLimit: scanLimit
        )
        if let cached = scanCache.value(for: request) {
            return cached
        }
        let rows = try performPatternScan(request)
        scanCache.insert(rows, for: request)
        return rows
    }

    private static func matches(
        from rows: [ScannedRow],
        patterns: [SyllableMatchPattern],
        resultLimit: Int
    ) -> [LexiconMatch] {
        var matches: [LexiconMatch] = []
        matches.reserveCapacity(min(resultLimit, rows.count))
        for row in rows {
            guard row.bases.count == patterns.count else { continue }
            var accepted = true
            for index in patterns.indices {
                guard case let .exact(constraint) = patterns[index] else { continue }
                guard row.bases[index] == constraint.base else {
                    accepted = false
                    break
                }
                if let tone = constraint.tone, tone != row.tones[index] {
                    accepted = false
                    break
                }
            }
            guard accepted else { continue }
            var pronunciation: [CanonicalSyllable] = []
            pronunciation.reserveCapacity(patterns.count)
            for index in patterns.indices {
                pronunciation.append(
                    CanonicalSyllable(base: row.bases[index], tone: row.tones[index])
                )
            }
            matches.append(
                LexiconMatch(
                    text: row.text,
                    pronunciation: pronunciation,
                    sourceWeight: row.sourceWeight,
                    pronunciationWeight: row.pronunciationWeight
                )
            )
            if matches.count == resultLimit {
                break
            }
        }
        return matches
    }

    private func performPatternScan(_ request: PatternScanRequest) throws -> [ScannedRow] {
        sqlite3_reset(patternStatement)
        sqlite3_clear_bindings(patternStatement)
        guard sqlite3_bind_text(patternStatement, 1, request.initialKey, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_bind_int(patternStatement, 2, Int32(request.syllableCount)) == SQLITE_OK,
              sqlite3_bind_int(patternStatement, 3, Int32(clamping: request.scanLimit)) == SQLITE_OK
        else {
            throw Self.queryError(database)
        }
        var rows: [ScannedRow] = []
        while true {
            let step = sqlite3_step(patternStatement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw Self.queryError(database)
            }
            guard let textPointer = sqlite3_column_text(patternStatement, 0),
                  let basePointer = sqlite3_column_text(patternStatement, 1),
                  let tonePointer = sqlite3_column_text(patternStatement, 2)
            else {
                throw LexiconStoreError.queryFailed("pattern match row contains NULL text, base_key or tone_key")
            }
            let bases = String(cString: basePointer)
                .split(separator: "\u{1f}", omittingEmptySubsequences: false)
                .map(String.init)
            let toneKey = String(cString: tonePointer)
            guard bases.count == request.syllableCount, toneKey.count == request.syllableCount else {
                throw LexiconStoreError.queryFailed("pattern match row does not match its initial key")
            }
            var tones: [MandarinTone] = []
            tones.reserveCapacity(request.syllableCount)
            var toneIndex = toneKey.startIndex
            for _ in 0..<request.syllableCount {
                guard let tone = MandarinTone(digit: toneKey[toneIndex]) else {
                    throw LexiconStoreError.queryFailed("tone_key contains a digit outside 1...5")
                }
                tones.append(tone)
                toneIndex = toneKey.index(after: toneIndex)
            }
            let weight: Double?
            if sqlite3_column_type(patternStatement, 3) == SQLITE_NULL {
                weight = nil
            } else {
                weight = sqlite3_column_double(patternStatement, 3)
            }
            let pronunciationWeight: Double?
            if sqlite3_column_type(patternStatement, 4) == SQLITE_NULL {
                pronunciationWeight = nil
            } else {
                pronunciationWeight = sqlite3_column_double(patternStatement, 4)
            }
            rows.append(
                ScannedRow(
                    text: String(cString: textPointer),
                    bases: bases,
                    tones: tones,
                    sourceWeight: weight,
                    pronunciationWeight: pronunciationWeight
                )
            )
        }
        return rows
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

private struct PatternMatchRequest: Hashable {
    let patterns: [SyllableMatchPattern]
    let resultLimit: Int
    let scanLimit: Int
}

private struct PatternScanRequest: Hashable {
    let initialKey: String
    let syllableCount: Int
    let scanLimit: Int
}

private struct ScannedRow {
    let text: String
    let bases: [String]
    let tones: [MandarinTone]
    let sourceWeight: Double?
    let pronunciationWeight: Double?
}

private struct BoundedCache<Key: Hashable, Value> {
    private final class Entry {
        let key: Key
        var value: Value
        var newer: Entry?
        var older: Entry?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    let capacity: Int
    private var storage: [Key: Entry] = [:]
    private var newest: Entry?
    private var oldest: Entry?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func value(for key: Key) -> Value? {
        guard let entry = storage[key] else { return nil }
        moveToNewest(entry)
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key) {
        if let entry = storage[key] {
            entry.value = value
            moveToNewest(entry)
            return
        }
        let entry = Entry(key: key, value: value)
        storage[key] = entry
        appendNewest(entry)
        while storage.count > capacity, let evicted = oldest {
            detach(evicted)
            storage.removeValue(forKey: evicted.key)
        }
    }

    private mutating func moveToNewest(_ entry: Entry) {
        guard newest !== entry else { return }
        detach(entry)
        appendNewest(entry)
    }

    private mutating func appendNewest(_ entry: Entry) {
        entry.newer = nil
        entry.older = newest
        newest?.newer = entry
        newest = entry
        if oldest == nil {
            oldest = entry
        }
    }

    private mutating func detach(_ entry: Entry) {
        let older = entry.older
        let newer = entry.newer
        older?.newer = newer
        newer?.older = older
        if oldest === entry {
            oldest = newer
        }
        if newest === entry {
            newest = older
        }
        entry.older = nil
        entry.newer = nil
    }
}
