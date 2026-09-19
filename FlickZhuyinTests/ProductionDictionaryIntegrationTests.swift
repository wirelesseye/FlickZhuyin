import SQLite3
import XCTest

final class ProductionDictionaryIntegrationTests: XCTestCase {
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

    private var terraManifestURL: URL {
        repositoryRoot.appendingPathComponent("Vendor/rime-terra-pinyin/SOURCE.json")
    }

    private var essayManifestURL: URL {
        repositoryRoot.appendingPathComponent("Vendor/rime-essay/SOURCE.json")
    }

    func testMetadataMatchesManifestsAndReport() throws {
        let database = try RawDatabase(url: databaseURL)
        let metadata = try database.metadata()
        let terraManifest = try readJSON(terraManifestURL)
        let essayManifest = try readJSON(essayManifestURL)
        let report = try readJSON(reportURL)

        XCTAssertEqual(metadata["schema_version"], "3")
        XCTAssertEqual(metadata["compiler_version"], "3")
        XCTAssertEqual(metadata["terra_source_repository"], terraManifest["repository"] as? String)
        XCTAssertEqual(metadata["terra_source_commit"], terraManifest["commit"] as? String)
        XCTAssertEqual(metadata["terra_source_sha256"], terraManifest["sha256"] as? String)
        XCTAssertEqual(metadata["essay_source_repository"], essayManifest["repository"] as? String)
        XCTAssertEqual(metadata["essay_source_commit"], essayManifest["commit"] as? String)
        XCTAssertEqual(metadata["essay_source_sha256"], essayManifest["sha256"] as? String)
        XCTAssertEqual(metadata["essay_entry_count"], String(try XCTUnwrap(essayManifest["entryCount"] as? Int)))
        XCTAssertEqual(metadata["essay_frequency_max"], String(try XCTUnwrap(essayManifest["frequencyMax"] as? Int)))
        XCTAssertEqual(metadata["weight_normalization"], "log1p(frequency)/log1p(max_frequency)")
        XCTAssertEqual(metadata["compiler_version"], report["compilerVersion"] as? String)

        let compiledEntries = try XCTUnwrap(report["compiledEntries"] as? Int)
        XCTAssertEqual(Int(metadata["entry_count"] ?? ""), compiledEntries)
        XCTAssertEqual(Int(metadata["max_syllable_count"] ?? ""), try XCTUnwrap(report["maxSyllableCount"] as? Int))
        let count = try XCTUnwrap(database.rows("SELECT COUNT(*) FROM pronunciation").first?.first as? Int64)
        XCTAssertEqual(Int(count), compiledEntries)
        let inventoryCount = try XCTUnwrap(database.rows("SELECT COUNT(*) FROM syllable_inventory").first?.first as? Int64)
        XCTAssertEqual(Int(inventoryCount), try XCTUnwrap(report["distinctZhuyinSyllables"] as? Int))
        let initialKeys = try XCTUnwrap(
            database.rows("SELECT COUNT(DISTINCT initial_key) FROM pronunciation").first?.first as? Int64
        )
        XCTAssertEqual(Int(initialKeys), try XCTUnwrap(report["distinctInitialKeys"] as? Int))
        let integrity = try XCTUnwrap(report["initialKeyIntegrity"] as? [String: Int])
        XCTAssertEqual(integrity["checkedEntries"], compiledEntries)
        XCTAssertEqual(integrity["syllableCountMismatches"], 0)
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
        let zhuyin = try store.exactMatches(
            for: [SyllableConstraint(base: "ㄓㄨ", tone: .fourth), SyllableConstraint(base: "ㄧㄣ", tone: .first)]
        )
        XCTAssertTrue(zhuyin.contains { $0.text == "注音" && $0.sourceWeight != nil })
        let nihao = try store.exactMatches(
            for: [SyllableConstraint(base: "ㄋㄧ", tone: .third), SyllableConstraint(base: "ㄏㄠ", tone: .third)]
        )
        XCTAssertTrue(nihao.contains { $0.text == "你好" && $0.sourceWeight != nil })
    }

    func testInitialQueriesReturnFullPronunciations() throws {
        let store = try SQLiteLexiconStore(url: databaseURL)
        let single = try store.initialMatches(for: ["ㄅ"], limit: 64)
        XCTAssertTrue(single.contains { $0.text == "不" })
        for match in single {
            XCTAssertEqual(match.pronunciation.count, 1)
            XCTAssertEqual(match.pronunciation[0].base.first, "ㄅ")
        }
        XCTAssertLessThanOrEqual(single.count, 64)
        XCTAssertTrue(
            try store.initialMatches(for: ["ㄅ"], limit: 64).map(\.text)
                == single.map(\.text)
        )

        let double = try store.initialMatches(for: ["ㄅ", "ㄅ"], limit: 64)
        XCTAssertTrue(double.contains { $0.text == "爸爸" })
        for match in double {
            XCTAssertEqual(match.pronunciation.count, 2)
            XCTAssertTrue(match.pronunciation.allSatisfy { $0.base.first == "ㄅ" })
        }
        let limited = try store.initialMatches(for: ["ㄅ", "ㄅ"], limit: 3)
        XCTAssertEqual(limited.count, 3)
        XCTAssertEqual(limited.map(\.text), Array(double.prefix(3).map(\.text)))
    }

    func testInitialKeyRowsAreConsistent() throws {
        let database = try RawDatabase(url: databaseURL)
        let mismatches = try XCTUnwrap(
            database.rows(
                "SELECT COUNT(*) FROM pronunciation WHERE "
                    + "LENGTH(REPLACE(initial_key, char(31), '')) != syllable_count"
            ).first?.first as? Int64
        )
        XCTAssertEqual(mismatches, 0)
        let nulls = try XCTUnwrap(
            database.rows("SELECT COUNT(*) FROM pronunciation WHERE initial_key IS NULL OR initial_key = ''")
                .first?.first as? Int64
        )
        XCTAssertEqual(nulls, 0)
    }

    func testEssayRowsCarryWeightsAndProvenance() throws {
        let database = try RawDatabase(url: databaseURL)
        let essayRows = try database.rows(
            "SELECT source_weight FROM pronunciation WHERE source_kind != 'terra'"
        )
        XCTAssertFalse(essayRows.isEmpty)
        var invalid = 0
        for row in essayRows {
            guard let weight = row[0] as? Double, weight >= 0, weight <= 1 else {
                invalid += 1
                continue
            }
        }
        XCTAssertEqual(invalid, 0)
        let essayOnly = try XCTUnwrap(
            database.rows(
                "SELECT COUNT(*) FROM pronunciation WHERE source_kind = 'essay' AND "
                    + "(essay_source_line IS NULL OR raw_frequency IS NULL OR terra_source_line IS NOT NULL "
                    + "OR terra_source_lines = '[]')"
            ).first?.first as? Int64
        )
        XCTAssertEqual(essayOnly, 0)
        let merged = try XCTUnwrap(
            database.rows(
                "SELECT COUNT(*) FROM pronunciation WHERE source_kind = 'terra+essay' AND "
                    + "(terra_source_line IS NULL OR essay_source_line IS NULL OR raw_frequency IS NULL)"
            ).first?.first as? Int64
        )
        XCTAssertEqual(merged, 0)
        XCTAssertGreaterThan(
            try XCTUnwrap(
                database.rows("SELECT COUNT(*) FROM pronunciation WHERE source_kind = 'terra+essay'").first?.first as? Int64
            ),
            0
        )
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

    func testIntegrityCheckAndQueryPlan() throws {
        let database = try RawDatabase(url: databaseURL)
        let integrity = try database.rows("PRAGMA integrity_check").first?.first as? String
        XCTAssertEqual(integrity, "ok")
        let plan = try database.rows(
            "EXPLAIN QUERY PLAN SELECT text, tone_key, source_weight FROM pronunciation "
                + "WHERE base_key = 'x' AND syllable_count = 2"
        )
        let detail = plan.compactMap { $0.last as? String }.joined(separator: " ").lowercased()
        XCTAssertTrue(detail.contains("pronunciation_base_key"), detail)
        XCTAssertTrue(detail.contains("search"), detail)

        let initialPlan = try database.rows(
            "EXPLAIN QUERY PLAN SELECT text, base_key, tone_key, source_weight FROM pronunciation "
                + "WHERE initial_key = 'x' AND syllable_count = 2 ORDER BY source_weight DESC, id LIMIT 64"
        )
        let initialDetail = initialPlan.compactMap { $0.last as? String }.joined(separator: " ").lowercased()
        XCTAssertTrue(initialDetail.contains("pronunciation_initial_key"), initialDetail)
        XCTAssertTrue(initialDetail.contains("search"), initialDetail)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
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
