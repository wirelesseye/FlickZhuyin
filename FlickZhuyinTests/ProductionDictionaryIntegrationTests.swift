import SQLite3
import XCTest

final class ProductionDictionaryIntegrationTests: XCTestCase {
    private let pinnedCommit = "8a2c895ad7ee8e2b137d91be77f18f86b04d7fc9"

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var databaseURL: URL {
        repositoryRoot.appendingPathComponent("Generated/flickzhuyin.sqlite3")
    }

    private var reportURL: URL {
        repositoryRoot.appendingPathComponent("Generated/dictionary-report.json")
    }

    func testMetadataMatchesReport() throws {
        let database = try RawDatabase(url: databaseURL)
        let metadata = try database.metadata()
        XCTAssertEqual(metadata["source_commit"], pinnedCommit)
        XCTAssertEqual(metadata["source_repository"], "https://github.com/rime/rime-terra-pinyin")
        XCTAssertEqual(metadata["schema_version"], "1")
        let report = try readReport()
        let compiledEntries = try XCTUnwrap(report["compiledEntries"] as? Int)
        XCTAssertEqual(Int(metadata["entry_count"] ?? ""), compiledEntries)
        XCTAssertEqual(Int(metadata["max_syllable_count"] ?? ""), try XCTUnwrap(report["maxSyllableCount"] as? Int))
        let count = try XCTUnwrap(database.rows("SELECT COUNT(*) FROM pronunciation").first?.first as? Int64)
        XCTAssertEqual(Int(count), compiledEntries)
        let inventoryCount = try XCTUnwrap(database.rows("SELECT COUNT(*) FROM syllable_inventory").first?.first as? Int64)
        XCTAssertEqual(Int(inventoryCount), try XCTUnwrap(report["distinctZhuyinSyllables"] as? Int))
    }

    func testRepresentativeQueries() throws {
        let store = try SQLiteLexiconStore(url: databaseURL)
        XCTAssertTrue(
            try store.exactMatches(for: [SyllableConstraint(base: "ㄓㄨㄥ", tone: .first)])
                .contains { $0.text == "中" }
        )
        XCTAssertTrue(
            try store.exactMatches(for: [SyllableConstraint(base: "ㄓㄨㄥ", tone: .fourth)])
                .contains { $0.text == "中" }
        )
        let toned = try store.exactMatches(
            for: [SyllableConstraint(base: "ㄅㄚ", tone: .fourth), SyllableConstraint(base: "ㄅㄚ", tone: .neutral)]
        )
        XCTAssertTrue(toned.contains { $0.text == "爸爸" })
        let toneless = try store.exactMatches(
            for: [SyllableConstraint(base: "ㄅㄚ"), SyllableConstraint(base: "ㄅㄚ")]
        )
        XCTAssertTrue(toneless.contains { $0.text == "爸爸" })
    }

    func testPronunciationRowsAreWellFormed() throws {
        let database = try RawDatabase(url: databaseURL)
        let rows = try database.rows("SELECT base_key, tone_key, syllable_count FROM pronunciation")
        XCTAssertFalse(rows.isEmpty)
        var invalid: [String] = []
        for row in rows {
            guard let baseKey = row[0] as? String,
                  let toneKey = row[1] as? String,
                  let syllableCount = row[2] as? Int64
            else {
                invalid.append("row with invalid types")
                continue
            }
            let bases = baseKey.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            if bases.isEmpty || bases.contains(where: \.isEmpty) {
                invalid.append("empty base in \(baseKey)")
            }
            if bases.count != Int(syllableCount) {
                invalid.append("syllable count mismatch in \(baseKey)=\(toneKey)")
            }
            if toneKey.count != Int(syllableCount) || !toneKey.allSatisfy({ "12345".contains($0) }) {
                invalid.append("invalid tone_key \(toneKey)")
            }
            if invalid.count > 8 {
                break
            }
        }
        XCTAssertTrue(invalid.isEmpty, "\(invalid.prefix(8))")
    }

    private func readReport() throws -> [String: Any] {
        let data = try Data(contentsOf: reportURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class RawDatabase {
    private let handle: OpaquePointer

    init(url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let pointer else {
            throw LexiconStoreError.openFailed("cannot open \(url.path)")
        }
        handle = pointer
    }

    deinit {
        sqlite3_close(handle)
    }

    func metadata() throws -> [String: String] {
        var values: [String: String] = [:]
        for row in try rows("SELECT key, value FROM metadata") {
            guard let key = row[0] as? String, let value = row[1] as? String else { continue }
            values[key] = value
        }
        return values
    }

    func rows(_ sql: String) throws -> [[Any?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LexiconStoreError.queryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [[Any?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw LexiconStoreError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            var row: [Any?] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row.append(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row.append(sqlite3_column_double(statement, index))
                case SQLITE_NULL:
                    row.append(nil)
                default:
                    guard let pointer = sqlite3_column_text(statement, index) else {
                        row.append(nil)
                        continue
                    }
                    row.append(String(cString: pointer))
                }
            }
            result.append(row)
        }
        return result
    }
}
