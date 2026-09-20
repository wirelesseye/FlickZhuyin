import SQLite3
import XCTest

class ChineseInputTestCase: XCTestCase {
    func fixtureURL() throws -> URL {
        guard let url = Bundle(for: type(of: self)).url(
            forResource: "flickzhuyin-tests",
            withExtension: "sqlite3"
        ) else {
            throw LexiconStoreError.resourceNotFound("flickzhuyin-tests.sqlite3")
        }
        return url
    }

    func makeFixtureStore() throws -> SQLiteLexiconStore {
        try SQLiteLexiconStore(url: try fixtureURL())
    }

    func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
    }

    func copyFixture(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: try fixtureURL(), to: url)
    }

    func execute(_ sql: String, at url: URL) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        guard let handle else {
            return XCTFail("could not open \(url.path)")
        }
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    func tokens(_ symbols: String) -> [ZhuyinInputToken] {
        symbols.map { .symbol($0) }
    }
}

final class MandarinToneTests: XCTestCase {
    func testDigitsMapToTones() {
        XCTAssertEqual(MandarinTone(digit: "1"), .first)
        XCTAssertEqual(MandarinTone(digit: "2"), .second)
        XCTAssertEqual(MandarinTone(digit: "3"), .third)
        XCTAssertEqual(MandarinTone(digit: "4"), .fourth)
        XCTAssertEqual(MandarinTone(digit: "5"), .neutral)
        XCTAssertNil(MandarinTone(digit: "0"))
        XCTAssertNil(MandarinTone(digit: "a"))
    }

    func testSymbols() {
        XCTAssertEqual(MandarinTone.first.symbol, "ˉ")
        XCTAssertEqual(MandarinTone.neutral.symbol, "˙")
        XCTAssertEqual(MandarinTone.fourth.digit, "4")
    }
}

final class SQLiteLexiconStoreTests: ChineseInputTestCase {
    func testInventoryIsLoadedFromFixture() throws {
        let store = try makeFixtureStore()
        XCTAssertEqual(
            try store.syllableInventory(),
            ["ㄅㄚ", "ㄅㄟ", "ㄅㄠ", "ㄅㄢ", "ㄅㄣ", "ㄅㄨ",
             "ㄉㄜ", "ㄋㄧ", "ㄋㄩ", "ㄌㄩ", "ㄍㄨㄛ", "ㄏㄠ", "ㄐㄧㄝ", "ㄓ", "ㄓㄨ", "ㄓㄨㄥ",
             "ㄔ", "ㄕ", "ㄖ", "ㄧ", "ㄧㄣ", "ㄨㄛ", "ㄨㄣ", "ㄩ"]
        )
    }

    func testExactToneMatch() throws {
        let store = try makeFixtureStore()
        let matches = try store.exactMatches(for: [SyllableConstraint(base: "ㄓㄨㄥ", tone: .first)])
        XCTAssertEqual(matches.map(\.text), ["中"])
        for match in matches {
            XCTAssertEqual(match.pronunciation, [CanonicalSyllable(base: "ㄓㄨㄥ", tone: .first)])
        }
    }

    func testTonelessWildcardMatchesEveryTone() throws {
        let store = try makeFixtureStore()
        let matches = try store.exactMatches(for: [SyllableConstraint(base: "ㄓㄨㄥ")])
        XCTAssertEqual(matches.filter { $0.text == "中" }.count, 2)
        XCTAssertEqual(
            Set(matches.filter { $0.text == "中" }.map { $0.pronunciation[0].tone }),
            [.first, .fourth]
        )
    }

    func testMixedToneConstraints() throws {
        let store = try makeFixtureStore()
        let match = try store.exactMatches(
            for: [SyllableConstraint(base: "ㄓㄨㄥ", tone: .first), SyllableConstraint(base: "ㄨㄣ")]
        )
        XCTAssertEqual(match.map(\.text), ["中文"])
        XCTAssertTrue(
            try store.exactMatches(
                for: [SyllableConstraint(base: "ㄓㄨㄥ", tone: .fourth), SyllableConstraint(base: "ㄨㄣ")]
            ).isEmpty
        )
    }

    func testFirstToneIsNotAWildcard() throws {
        let store = try makeFixtureStore()
        XCTAssertTrue(try store.exactMatches(for: [SyllableConstraint(base: "ㄏㄠ", tone: .first)]).isEmpty)
        XCTAssertEqual(
            try store.exactMatches(for: [SyllableConstraint(base: "ㄏㄠ")]).count,
            2
        )
    }

    func testNeutralToneMatchesOnlyToneFive() throws {
        let store = try makeFixtureStore()
        XCTAssertEqual(
            try store.exactMatches(for: [SyllableConstraint(base: "ㄉㄜ", tone: .neutral)]).map(\.text),
            ["的"]
        )
        XCTAssertTrue(try store.exactMatches(for: [SyllableConstraint(base: "ㄉㄜ", tone: .first)]).isEmpty)
    }

    func testPolyphoneReturnsMultiplePronunciations() throws {
        let store = try makeFixtureStore()
        let matches = try store.exactMatches(for: [SyllableConstraint(base: "ㄏㄠ")])
        XCTAssertEqual(matches.map(\.text), ["好", "好"])
        XCTAssertEqual(matches.map { $0.pronunciation[0].tone }, [.third, .fourth])
    }

    func testSourceWeightsArePreserved() throws {
        let store = try makeFixtureStore()
        let weighted = try store.exactMatches(
            for: [SyllableConstraint(base: "ㄓㄨㄥ", tone: .first), SyllableConstraint(base: "ㄨㄣ", tone: .second)]
        )
        XCTAssertEqual(weighted.first?.sourceWeight, 0.97)
        let unweighted = try store.exactMatches(for: [SyllableConstraint(base: "ㄋㄧ", tone: .third)])
        XCTAssertEqual(unweighted.map(\.text), ["你"])
        XCTAssertNil(unweighted.first?.sourceWeight)
    }

    func testMissingDatabaseThrows() {
        let url = temporaryURL("missing.sqlite3")
        XCTAssertThrowsError(try SQLiteLexiconStore(url: url)) { error in
            XCTAssertEqual(error as? LexiconStoreError, .databaseMissing(url))
        }
    }

    func testSchemaMismatchThrows() throws {
        let userVersion = temporaryURL("user-version.sqlite3")
        try copyFixture(to: userVersion)
        execute("PRAGMA user_version = 1", at: userVersion)
        XCTAssertThrowsError(try SQLiteLexiconStore(url: userVersion)) { error in
            guard case .schemaMismatch = error as? LexiconStoreError else {
                return XCTFail("expected schemaMismatch, got \(error)")
            }
        }

        let missingTables = temporaryURL("missing-tables.sqlite3")
        try FileManager.default.createDirectory(at: missingTables.deletingLastPathComponent(), withIntermediateDirectories: true)
        execute("CREATE TABLE unrelated (id INTEGER)", at: missingTables)
        XCTAssertThrowsError(try SQLiteLexiconStore(url: missingTables)) { error in
            guard case .schemaMismatch = error as? LexiconStoreError else {
                return XCTFail("expected schemaMismatch, got \(error)")
            }
        }
    }

    func testCorruptDatabaseThrows() throws {
        let url = temporaryURL("corrupt.sqlite3")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not a sqlite database".utf8).write(to: url)
        XCTAssertThrowsError(try SQLiteLexiconStore(url: url))
    }

    func testRepeatedQueriesReturnStableResults() throws {
        let store = try makeFixtureStore()
        let constraint = [SyllableConstraint(base: "ㄕ", tone: .fourth)]
        let first = try store.exactMatches(for: constraint)
        let second = try store.exactMatches(for: constraint)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.text), ["是"])
    }

    func testPatternMatchForSingleInitial() throws {
        let store = try makeFixtureStore()
        let matches = try store.patternMatches(for: [.initial("ㄅ")], resultLimit: 64, scanLimit: 64)
        XCTAssertEqual(matches.map(\.text), ["不", "把", "被", "本"])
        XCTAssertEqual(
            matches.map(\.pronunciation[0].base),
            ["ㄅㄨ", "ㄅㄚ", "ㄅㄟ", "ㄅㄣ"]
        )
        XCTAssertEqual(matches.map(\.pronunciation[0].tone), [.fourth, .third, .fourth, .third])
    }

    func testPatternMatchForConsecutiveInitials() throws {
        let store = try makeFixtureStore()
        let matches = try store.patternMatches(
            for: [.initial("ㄅ"), .initial("ㄅ")],
            resultLimit: 64,
            scanLimit: 64
        )
        XCTAssertEqual(matches.map(\.text), ["爸爸", "寶寶", "北部", "版本"])
        XCTAssertEqual(
            matches[0].pronunciation,
            [
                CanonicalSyllable(base: "ㄅㄚ", tone: .fourth),
                CanonicalSyllable(base: "ㄅㄚ", tone: .neutral),
            ]
        )
        XCTAssertEqual(matches[0].sourceWeight, 0.95)
    }

    func testPatternMatchMixesExactAndInitialConstraints() throws {
        let store = try makeFixtureStore()
        let patterns: [SyllableMatchPattern] = [
            .exact(SyllableConstraint(base: "ㄅㄟ")),
            .initial("ㄅ"),
        ]
        let matches = try store.patternMatches(for: patterns, resultLimit: 64, scanLimit: 2048)
        XCTAssertEqual(matches.map(\.text), ["北部"])
        XCTAssertEqual(
            matches[0].pronunciation,
            [
                CanonicalSyllable(base: "ㄅㄟ", tone: .third),
                CanonicalSyllable(base: "ㄅㄨ", tone: .fourth),
            ]
        )
    }

    func testPatternMatchLeavesUnsatisfiedExactConstraintsOut() throws {
        let store = try makeFixtureStore()
        let matches = try store.patternMatches(
            for: [.exact(SyllableConstraint(base: "ㄅㄚ", tone: .fourth)), .initial("ㄅ")],
            resultLimit: 64,
            scanLimit: 2048
        )
        XCTAssertEqual(matches.map(\.text), ["爸爸"])
    }

    func testPatternMatchExplicitToneMustMatch() throws {
        let store = try makeFixtureStore()
        let matches = try store.patternMatches(
            for: [.exact(SyllableConstraint(base: "ㄅㄟ", tone: .first)), .initial("ㄅ")],
            resultLimit: 64,
            scanLimit: 2048
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testPatternMatchResultLimitCountsAcceptedRows() throws {
        let store = try makeFixtureStore()
        let patterns: [SyllableMatchPattern] = [
            .exact(SyllableConstraint(base: "ㄅㄟ")),
            .initial("ㄅ"),
        ]
        let matches = try store.patternMatches(for: patterns, resultLimit: 1, scanLimit: 2048)
        XCTAssertEqual(matches.map(\.text), ["北部"])
    }

    func testPatternMatchScanLimitStopsBeforeLateMatches() throws {
        let store = try makeFixtureStore()
        let patterns: [SyllableMatchPattern] = [
            .exact(SyllableConstraint(base: "ㄅㄟ")),
            .initial("ㄅ"),
        ]
        // 爸爸 (0.95) and 寶寶 (0.55) come first and are rejected, so the scan
        // limit must be reached before 北部 (0.4) is found.
        XCTAssertTrue(try store.patternMatches(for: patterns, resultLimit: 64, scanLimit: 1).isEmpty)
        XCTAssertTrue(try store.patternMatches(for: patterns, resultLimit: 64, scanLimit: 2).isEmpty)
        XCTAssertEqual(
            try store.patternMatches(for: patterns, resultLimit: 64, scanLimit: 3).map(\.text),
            ["北部"]
        )
    }

    func testPatternMatchLimitAndOrderingAreDeterministic() throws {
        let store = try makeFixtureStore()
        let patterns: [SyllableMatchPattern] = [.initial("ㄅ")]
        let limited = try store.patternMatches(for: patterns, resultLimit: 2, scanLimit: 64)
        XCTAssertEqual(limited.map(\.text), ["不", "把"])
        XCTAssertEqual(try store.patternMatches(for: patterns, resultLimit: 2, scanLimit: 64), limited)
        XCTAssertTrue(try store.patternMatches(for: patterns, resultLimit: 0, scanLimit: 64).isEmpty)
        XCTAssertTrue(try store.patternMatches(for: [], resultLimit: 64, scanLimit: 64).isEmpty)
    }

    func testPatternQueryUsesIndex() throws {
        let url = temporaryURL("query-plan.sqlite3")
        try copyFixture(to: url)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        guard let handle else {
            return XCTFail("could not open \(url.path)")
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "EXPLAIN QUERY PLAN SELECT text, base_key, tone_key, source_weight "
            + "FROM pronunciation WHERE initial_key = 'x' AND syllable_count = 2 "
            + "ORDER BY source_weight DESC, id LIMIT 64"
        XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else {
            return XCTFail("could not prepare query plan")
        }
        defer { sqlite3_finalize(statement) }
        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            for index in 0..<sqlite3_column_count(statement) {
                if let pointer = sqlite3_column_text(statement, index) {
                    details.append(String(cString: pointer))
                }
            }
        }
        let detail = details.joined(separator: " ").lowercased()
        XCTAssertTrue(detail.contains("pronunciation_initial_key"), detail)
        XCTAssertTrue(detail.contains("search"), detail)
    }

    func testSchemaVersionTwoDatabaseIsRejected() throws {
        let url = temporaryURL("schema-two.sqlite3")
        try copyFixture(to: url)
        execute("PRAGMA user_version = 2", at: url)
        XCTAssertThrowsError(try SQLiteLexiconStore(url: url)) { error in
            guard case .schemaMismatch = error as? LexiconStoreError else {
                return XCTFail("expected schemaMismatch, got \(error)")
            }
        }
    }
}

final class SyllableParserTests: XCTestCase {
    private let parser = SyllableParser(
        syllableBases: ["ㄓ", "ㄓㄨ", "ㄓㄨㄥ", "ㄨ", "ㄨㄥ", "ㄧ", "ㄧㄣ", "ㄅ", "ㄅㄨ", "ㄏㄠ", "ㄋㄧ"]
    )

    private func tokens(_ symbols: String, tone: MandarinTone? = nil) -> [ZhuyinInputToken] {
        var result: [ZhuyinInputToken] = symbols.map { .symbol($0) }
        if let tone {
            result.append(.tone(tone))
        }
        return result
    }

    func testEveryLegalSegmentationIsKept() {
        let lattice = parser.lattice(for: tokens("ㄓㄨㄥ"))
        let complete = lattice.outgoingEdges[0].filter { $0.completeness == .complete }
        XCTAssertEqual(Set(complete.map(\.constraint.base)), ["ㄓ", "ㄓㄨ", "ㄓㄨㄥ"])
        XCTAssertTrue(complete.allSatisfy { $0.parserCost == 0 })
    }

    func testInitialAbbreviationEdgesAreEligible() {
        let lattice = parser.lattice(for: tokens("ㄅㄅ"))
        XCTAssertEqual(lattice.tokenCount, 2)
        for position in 0..<2 {
            let abbreviations = lattice.outgoingEdges[position].filter(\.isInitialAbbreviation)
            XCTAssertEqual(abbreviations.map(\.constraint.base), ["ㄅ"])
            XCTAssertEqual(abbreviations.map(\.tokenRange), [position..<(position + 1)])
            XCTAssertEqual(abbreviations.map(\.parserCost), [SyllableParser.incompleteCost])
        }
        XCTAssertTrue(reachable(from: 0, to: 2, in: lattice))
    }

    func testCompleteSyllableThatIsAlsoAnInitialKeepsBothEdges() {
        let lattice = parser.lattice(for: tokens("ㄓ"))
        XCTAssertEqual(lattice.outgoingEdges[0].count, 2)
        XCTAssertEqual(lattice.outgoingEdges[0].filter { $0.completeness == .complete }.count, 1)
        let abbreviation = lattice.outgoingEdges[0].first { $0.isInitialAbbreviation }
        XCTAssertEqual(abbreviation?.constraint, SyllableConstraint(base: "ㄓ"))
        XCTAssertEqual(abbreviation?.tokenRange, 0..<1)
        XCTAssertEqual(abbreviation?.parserCost, SyllableParser.incompleteCost)
    }

    func testVowelOnlySyllableIsNotAnInitialAbbreviation() {
        let lattice = parser.lattice(for: tokens("ㄧ"))
        XCTAssertEqual(lattice.outgoingEdges[0].count, 1)
        XCTAssertEqual(lattice.outgoingEdges[0][0].completeness, .complete)
        XCTAssertFalse(lattice.outgoingEdges[0][0].isInitialAbbreviation)
    }

    func testTonedSingleInitialIsNotAnInitialAbbreviation() {
        let lattice = parser.lattice(for: tokens("ㄓ", tone: .fourth))
        XCTAssertEqual(lattice.outgoingEdges[0].count, 1)
        XCTAssertFalse(lattice.outgoingEdges[0].contains(where: \.isInitialAbbreviation))
    }

    func testTonelessInputCreatesCompleteEdges() {
        let lattice = parser.lattice(for: tokens("ㄋㄧ"))
        XCTAssertEqual(lattice.outgoingEdges[0].count, 2)
        let edge = lattice.outgoingEdges[0][1]
        XCTAssertEqual(edge.constraint, SyllableConstraint(base: "ㄋㄧ", tone: nil))
        XCTAssertEqual(edge.completeness, .complete)
        XCTAssertEqual(edge.tokenRange, 0..<2)
        XCTAssertEqual(lattice.outgoingEdges[0][0].constraint, SyllableConstraint(base: "ㄋ", tone: nil))
        XCTAssertEqual(lattice.outgoingEdges[0][0].completeness, .incomplete)
    }

    func testToneTokenAttachesToSyllable() {
        let lattice = parser.lattice(for: tokens("ㄋㄧ", tone: .third))
        XCTAssertEqual(lattice.outgoingEdges[0].count, 2)
        let edge = lattice.outgoingEdges[0][1]
        XCTAssertEqual(edge.constraint, SyllableConstraint(base: "ㄋㄧ", tone: .third))
        XCTAssertEqual(edge.completeness, .complete)
        XCTAssertEqual(edge.tokenRange, 0..<3)
        XCTAssertNil(lattice.outgoingEdges[0][0].constraint.tone)
        XCTAssertEqual(lattice.outgoingEdges[0][0].completeness, .incomplete)
    }

    func testIncompletePrefixEdge() {
        let inventoryOnly = SyllableParser(syllableBases: ["ㄅㄨ"])
        let lattice = inventoryOnly.lattice(for: tokens("ㄅ"))
        XCTAssertEqual(lattice.outgoingEdges[0].count, 1)
        let edge = lattice.outgoingEdges[0][0]
        XCTAssertEqual(edge.completeness, .incomplete)
        XCTAssertEqual(edge.parserCost, SyllableParser.incompleteCost)
        XCTAssertEqual(edge.tokenRange, 0..<1)
    }

    func testFallbackForUnknownSymbolAndBareTone() {
        let lattice = parser.lattice(for: [.symbol("ㄫ"), .tone(.fourth)])
        XCTAssertEqual(lattice.outgoingEdges[0].count, 1)
        XCTAssertEqual(lattice.outgoingEdges[0][0].completeness, .fallback)
        XCTAssertEqual(lattice.outgoingEdges[0][0].parserCost, SyllableParser.fallbackCost)
        XCTAssertEqual(lattice.outgoingEdges[1].count, 1)
        XCTAssertEqual(lattice.outgoingEdges[1][0].completeness, .fallback)
    }

    func testUnfinishedSequenceKeepsLatticeConnected() {
        let input = [ZhuyinInputToken.symbol("ㄅ"), .symbol("ㄓ"), .symbol("ㄨ"), .symbol("ㄧ"), .symbol("ㄥ")]
        let lattice = parser.lattice(for: input)
        XCTAssertEqual(lattice.tokenCount, 5)
        for offset in 0..<lattice.tokenCount {
            XCTAssertFalse(lattice.outgoingEdges[offset].isEmpty, "offset \(offset) has no edge")
        }
        XCTAssertTrue(reachable(from: 0, to: lattice.tokenCount, in: lattice))
        for offset in 0..<lattice.tokenCount where reachable(from: 0, to: offset, in: lattice) {
            XCTAssertTrue(reachable(from: offset, to: lattice.tokenCount, in: lattice))
        }
    }

    func testEmptyInput() {
        let lattice = parser.lattice(for: [])
        XCTAssertEqual(lattice.tokenCount, 0)
        XCTAssertEqual(lattice.outgoingEdges.count, 1)
        XCTAssertTrue(lattice.outgoingEdges[0].isEmpty)
    }

    func testParserCanLoadInventoryFromStore() throws {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "flickzhuyin-tests", withExtension: "sqlite3")
        )
        let store = try SQLiteLexiconStore(url: url)
        let storeParser = try SyllableParser(store: store)
        XCTAssertEqual(storeParser.completeSyllables, Set(try store.syllableInventory()))
    }

    private func reachable(from start: Int, to target: Int, in lattice: SyllableLattice) -> Bool {
        var visited: Set<Int> = []
        var stack = [start]
        while let position = stack.popLast() {
            if position == target { return true }
            guard visited.insert(position).inserted, position < lattice.tokenCount else { continue }
            stack.append(contentsOf: lattice.outgoingEdges[position].map { $0.tokenRange.upperBound })
        }
        return false
    }
}

final class DictionaryMatcherTests: XCTestCase {
    private func tokens(_ symbols: String, tone: MandarinTone? = nil) -> [ZhuyinInputToken] {
        var result: [ZhuyinInputToken] = symbols.map { .symbol($0) }
        if let tone {
            result.append(.tone(tone))
        }
        return result
    }

    func testProducesSingleAndMultiCharacterWordEdges() throws {
        let ni3 = SyllableConstraint(base: "ㄋㄧ", tone: .third)
        let hao3 = SyllableConstraint(base: "ㄏㄠ", tone: .third)
        let store = StubLexiconStore(
            inventory: ["ㄋㄧ", "ㄏㄠ"],
            responses: [
                [ni3]: [LexiconMatch(text: "你", pronunciation: [CanonicalSyllable(base: "ㄋㄧ", tone: .third)], sourceWeight: nil)],
                [ni3, hao3]: [LexiconMatch(text: "你好", pronunciation: [
                    CanonicalSyllable(base: "ㄋㄧ", tone: .third),
                    CanonicalSyllable(base: "ㄏㄠ", tone: .third),
                ], sourceWeight: 0.5)],
                [hao3]: [LexiconMatch(text: "好", pronunciation: [CanonicalSyllable(base: "ㄏㄠ", tone: .third)], sourceWeight: nil)],
            ]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        let lattice = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄋㄧ", tone: .third) + tokens("ㄏㄠ", tone: .third))
        )
        XCTAssertEqual(Set(lattice.outgoingEdges[0].map(\.text)), ["你", "你好"])
        XCTAssertEqual(lattice.outgoingEdges[0].first { $0.text == "你好" }?.tokenRange, 0..<6)
        XCTAssertEqual(lattice.outgoingEdges[0].first { $0.text == "你好" }?.sourceWeight, 0.5)
        XCTAssertEqual(lattice.outgoingEdges[3].map(\.text), ["好"])
    }

    func testFallbackEdgeIsNotQueriedButSingleSymbolPrefixIs() throws {
        let store = StubLexiconStore(inventory: ["ㄋㄧ"])
        let parser = SyllableParser(syllableBases: store.inventory)
        let lattice = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄅ") + tokens("ㄋㄧ", tone: .third))
        )
        XCTAssertTrue(lattice.outgoingEdges[0].isEmpty)
        XCTAssertEqual(store.queries, [[SyllableConstraint(base: "ㄋㄧ", tone: .third)]])
        XCTAssertEqual(store.patternQueries, [[.initial("ㄋ")]])
    }

    func testTonelessInputDoesNotExpandFiveToTheN() throws {
        let ni = SyllableConstraint(base: "ㄋㄧ")
        let hao = SyllableConstraint(base: "ㄏㄠ")
        let store = StubLexiconStore(
            inventory: ["ㄋㄧ", "ㄏㄠ"],
            responses: [
                [ni]: [LexiconMatch(text: "你", pronunciation: [CanonicalSyllable(base: "ㄋㄧ", tone: .third)], sourceWeight: nil)],
                [ni, hao]: [LexiconMatch(text: "你好", pronunciation: [
                    CanonicalSyllable(base: "ㄋㄧ", tone: .third),
                    CanonicalSyllable(base: "ㄏㄠ", tone: .third),
                ], sourceWeight: nil)],
                [hao]: [LexiconMatch(text: "好", pronunciation: [CanonicalSyllable(base: "ㄏㄠ", tone: .third)], sourceWeight: nil)],
            ]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        _ = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄋㄧ") + tokens("ㄏㄠ"))
        )
        XCTAssertEqual(store.queries.count, 3)
        XCTAssertTrue(store.queries.allSatisfy { $0.count <= 2 })
    }

    func testMaximumSyllableCountStopsExpansion() throws {
        let first = SyllableConstraint(base: "ㄇㄚ")
        let second = SyllableConstraint(base: "ㄇㄧ")
        let third = SyllableConstraint(base: "ㄇㄨ")
        let store = StubLexiconStore(
            inventory: ["ㄇㄚ", "ㄇㄧ", "ㄇㄨ"],
            responses: [
                [first]: [LexiconMatch(text: "甲", pronunciation: [CanonicalSyllable(base: "ㄇㄚ", tone: .first)], sourceWeight: nil)],
                [first, second]: [LexiconMatch(text: "甲乙", pronunciation: [
                    CanonicalSyllable(base: "ㄇㄚ", tone: .first),
                    CanonicalSyllable(base: "ㄇㄧ", tone: .first),
                ], sourceWeight: nil)],
                [first, second, third]: [LexiconMatch(text: "甲乙丙", pronunciation: [
                    CanonicalSyllable(base: "ㄇㄚ", tone: .first),
                    CanonicalSyllable(base: "ㄇㄧ", tone: .first),
                    CanonicalSyllable(base: "ㄇㄨ", tone: .first),
                ], sourceWeight: nil)],
            ]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        var configuration = DictionaryMatcher.Configuration()
        configuration.maxWordSyllables = 2
        let lattice = try DictionaryMatcher(store: store, configuration: configuration).buildLattice(
            from: parser.lattice(for: tokens("ㄇㄚ") + tokens("ㄇㄧ") + tokens("ㄇㄨ"))
        )
        XCTAssertEqual(Set(lattice.outgoingEdges[0].map(\.text)), ["甲", "甲乙"])
        XCTAssertFalse(store.queries.contains { $0.count == 3 })
    }

    func testDuplicateWordEdgesAreDeduplicated() throws {
        let first = SyllableConstraint(base: "ㄇㄚ")
        let second = SyllableConstraint(base: "ㄇㄧ")
        let match = LexiconMatch(
            text: "甲",
            pronunciation: [CanonicalSyllable(base: "ㄇㄚ", tone: .first)],
            sourceWeight: nil
        )
        let store = StubLexiconStore(
            inventory: ["ㄇㄚ", "ㄇㄧ"],
            responses: [[first]: [match], [second]: [match]]
        )
        let lattice = SyllableLattice(
            tokenCount: 2,
            outgoingEdges: [
                [
                    SyllableEdge(tokenRange: 0..<2, constraint: first, completeness: .complete, parserCost: 0),
                    SyllableEdge(tokenRange: 0..<2, constraint: second, completeness: .complete, parserCost: 0),
                ],
                [],
                [],
            ]
        )
        let wordLattice = try DictionaryMatcher(store: store).buildLattice(from: lattice)
        XCTAssertEqual(wordLattice.outgoingEdges[0].count, 1)
    }

    func testNoMatchesProducesEmptyLattice() throws {
        let store = StubLexiconStore(inventory: ["ㄋㄧ"])
        let parser = SyllableParser(syllableBases: store.inventory)
        let lattice = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄋㄧ", tone: .third))
        )
        XCTAssertTrue(lattice.outgoingEdges.allSatisfy(\.isEmpty))
    }

    func testSingleSymbolIncompleteEdgesUsePatternLookup() throws {
        let bu = SyllableConstraint(base: "ㄅㄨ", tone: .fourth)
        let store = StubLexiconStore(
            inventory: ["ㄅㄨ"],
            responses: [
                [bu]: [LexiconMatch(text: "不", pronunciation: [CanonicalSyllable(base: "ㄅㄨ", tone: .fourth)], sourceWeight: nil)]
            ],
            patternResponses: [
                [.initial("ㄅ")]: [LexiconMatch(text: "不", pronunciation: [CanonicalSyllable(base: "ㄅㄨ", tone: .fourth)], sourceWeight: 0.9)]
            ]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        let lattice = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄅ"))
        )
        XCTAssertEqual(lattice.outgoingEdges[0].map(\.text), ["不"])
        XCTAssertTrue(store.queries.isEmpty)
        XCTAssertEqual(store.patternQueries, [[.initial("ㄅ")]])
        XCTAssertEqual(store.patternResultLimits, [DictionaryMatcher.Configuration.patternMatchResultLimit])
        XCTAssertEqual(store.patternScanLimits, [DictionaryMatcher.Configuration.patternMatchScanLimit])
        let edge = try XCTUnwrap(lattice.outgoingEdges[0].first)
        XCTAssertEqual(edge.tokenRange, 0..<1)
        XCTAssertEqual(edge.syllableEdges.map(\.completeness), [.incomplete])
        XCTAssertEqual(edge.syllableEdges.map(\.parserCost), [SyllableParser.incompleteCost])
        XCTAssertEqual(edge.pronunciation, [CanonicalSyllable(base: "ㄅㄨ", tone: .fourth)])
        XCTAssertEqual(edge.sourceWeight, 0.9)
    }

    func testMultiSymbolPrefixDoesNotUsePatternLookup() throws {
        let store = StubLexiconStore(inventory: ["ㄧㄣ"])
        let multiSymbolEdge = SyllableEdge(
            tokenRange: 0..<2,
            constraint: SyllableConstraint(base: "ㄍㄨ"),
            completeness: .incomplete,
            parserCost: SyllableParser.incompleteCost
        )
        let multiSymbolLattice = SyllableLattice(
            tokenCount: 2,
            outgoingEdges: [[multiSymbolEdge], [], []]
        )
        let wordLattice = try DictionaryMatcher(store: store).buildLattice(from: multiSymbolLattice)
        XCTAssertTrue(wordLattice.outgoingEdges.allSatisfy(\.isEmpty))
        XCTAssertTrue(store.patternQueries.isEmpty)
        XCTAssertTrue(store.queries.isEmpty)
    }

    func testSingleSymbolVowelPrefixUsesPatternLookup() throws {
        let store = StubLexiconStore(
            inventory: ["ㄧㄣ"],
            patternResponses: [
                [.initial("ㄧ")]: [LexiconMatch(
                    text: "因",
                    pronunciation: [CanonicalSyllable(base: "ㄧㄣ", tone: .first)],
                    sourceWeight: 0.7
                )]
            ]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        let lattice = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄧ"))
        )
        XCTAssertEqual(lattice.outgoingEdges[0].map(\.text), ["因"])
        XCTAssertEqual(store.patternQueries, [[.initial("ㄧ")]])
        let edge = try XCTUnwrap(lattice.outgoingEdges[0].first)
        XCTAssertEqual(edge.syllableEdges.map(\.completeness), [.incomplete])
    }

    func testConsecutiveInitialsProduceSingleWordEdge() throws {
        let baba = LexiconMatch(
            text: "爸爸",
            pronunciation: [
                CanonicalSyllable(base: "ㄅㄚ", tone: .fourth),
                CanonicalSyllable(base: "ㄅㄚ", tone: .neutral),
            ],
            sourceWeight: 0.95
        )
        let store = StubLexiconStore(
            inventory: ["ㄅㄚ"],
            patternResponses: [
                [.initial("ㄅ")]: [LexiconMatch(text: "爸", pronunciation: [CanonicalSyllable(base: "ㄅㄚ", tone: .fourth)], sourceWeight: 0.9)],
                [.initial("ㄅ"), .initial("ㄅ")]: [baba],
            ]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        let lattice = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄅㄅ"))
        )
        let edge = try XCTUnwrap(lattice.outgoingEdges[0].first { $0.text == "爸爸" })
        XCTAssertEqual(edge.tokenRange, 0..<2)
        XCTAssertEqual(edge.pronunciation, baba.pronunciation)
        XCTAssertEqual(edge.syllableEdges.map(\.constraint.base), ["ㄅ", "ㄅ"])
        XCTAssertEqual(edge.syllableEdges.map(\.completeness), [.incomplete, .incomplete])
        XCTAssertEqual(store.patternQueries, [[.initial("ㄅ")], [.initial("ㄅ"), .initial("ㄅ")]])
    }

    func testPatternQueryIsMemoizedAcrossStartPositions() throws {
        let store = StubLexiconStore(
            inventory: ["ㄅㄚ"],
            patternResponses: [
                [.initial("ㄅ")]: [LexiconMatch(text: "爸", pronunciation: [CanonicalSyllable(base: "ㄅㄚ", tone: .fourth)], sourceWeight: 0.9)],
            ]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        _ = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄅㄅㄅ"))
        )
        let queries = store.patternQueries
        XCTAssertEqual(Set(queries).count, queries.count)
        XCTAssertEqual(queries.map(\.count), [1, 2, 3])
    }

    func testPatternQueryLimitsAndMaxWordSyllablesAreApplied() throws {
        let matches = (0..<8).map { index in
            LexiconMatch(
                text: "W\(index)",
                pronunciation: [CanonicalSyllable(base: "ㄅㄚ", tone: .fourth)],
                sourceWeight: 0.9 - Double(index) * 0.05
            )
        }
        let store = StubLexiconStore(
            inventory: ["ㄅㄚ"],
            patternResponses: [[.initial("ㄅ")]: matches]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        var configuration = DictionaryMatcher.Configuration()
        configuration.patternMatchResultLimit = 3
        configuration.maxWordSyllables = 2
        let lattice = try DictionaryMatcher(store: store, configuration: configuration).buildLattice(
            from: parser.lattice(for: tokens("ㄅㄅㄅ"))
        )
        XCTAssertEqual(lattice.outgoingEdges[0].count, 3)
        XCTAssertTrue(store.patternResultLimits.allSatisfy { $0 == 3 })
        XCTAssertTrue(store.patternScanLimits.allSatisfy { $0 == configuration.patternMatchScanLimit })
        XCTAssertTrue(store.patternQueries.allSatisfy { $0.count <= 2 })
    }

    func testLongInitialSequenceUsesLinearQueries() throws {
        let store = StubLexiconStore(
            inventory: ["ㄅㄚ"],
            patternResponses: [
                [.initial("ㄅ")]: [LexiconMatch(text: "爸", pronunciation: [CanonicalSyllable(base: "ㄅㄚ", tone: .fourth)], sourceWeight: 0.9)]
            ]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        _ = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens(String(repeating: "ㄅ", count: 8)))
        )
        XCTAssertTrue(store.queries.isEmpty)
        XCTAssertEqual(store.patternQueries.count, 8)
        XCTAssertEqual(store.patternQueries.map(\.count), Array(1...8))
    }

    func testExactMatchDeduplicatesAgainstAbbreviationInterpretation() throws {
        let zh = SyllableConstraint(base: "ㄓ")
        let match = LexiconMatch(
            text: "知",
            pronunciation: [CanonicalSyllable(base: "ㄓ", tone: .first)],
            sourceWeight: nil
        )
        let store = StubLexiconStore(
            inventory: ["ㄓ"],
            responses: [[zh]: [match]],
            patternResponses: [[.initial("ㄓ")]: [match]]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        let lattice = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄓ"))
        )
        XCTAssertEqual(lattice.outgoingEdges[0].map(\.text), ["知"])
        XCTAssertEqual(lattice.outgoingEdges[0].first?.syllableEdges.map(\.completeness), [.complete])
        XCTAssertEqual(lattice.outgoingEdges[0].first?.syllableEdges.map(\.parserCost), [0])
        XCTAssertEqual(store.queries, [[zh]])
        XCTAssertEqual(store.patternQueries, [[.initial("ㄓ")]])
    }

    func testMixedExactAndInitialPatternProducesSingleWordEdge() throws {
        let bu = SyllableConstraint(base: "ㄅㄨ")
        let zh = SyllableConstraint(base: "ㄓ")
        let buZhiDao = LexiconMatch(
            text: "不知道",
            pronunciation: [
                CanonicalSyllable(base: "ㄅㄨ", tone: .second),
                CanonicalSyllable(base: "ㄓ", tone: .first),
                CanonicalSyllable(base: "ㄉㄠ", tone: .fourth),
            ],
            sourceWeight: 0.72
        )
        let store = StubLexiconStore(
            inventory: ["ㄅㄨ", "ㄓ", "ㄉㄠ"],
            patternResponses: [
                [.exact(bu), .exact(zh), .initial("ㄉ")]: [buZhiDao],
            ]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        let lattice = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄅㄨㄓㄉ"))
        )
        let edge = try XCTUnwrap(lattice.outgoingEdges[0].first { $0.text == "不知道" })
        XCTAssertEqual(edge.tokenRange, 0..<4)
        XCTAssertEqual(edge.pronunciation, buZhiDao.pronunciation)
        XCTAssertEqual(edge.sourceWeight, 0.72)
        XCTAssertEqual(edge.syllableEdges.map(\.constraint.base), ["ㄅㄨ", "ㄓ", "ㄉ"])
        XCTAssertEqual(edge.syllableEdges.map(\.completeness), [.complete, .complete, .incomplete])
        XCTAssertEqual(
            edge.syllableEdges.map(\.parserCost),
            [0, 0, SyllableParser.incompleteCost]
        )
        XCTAssertTrue(store.patternQueries.contains([.exact(bu), .exact(zh), .initial("ㄉ")]))
    }

    func testMixedExpansionKeepsCheapestSegmentationForSameWord() throws {
        let zh = SyllableConstraint(base: "ㄓ")
        let d = SyllableConstraint(base: "ㄉ")
        let zhiDao = LexiconMatch(
            text: "知道",
            pronunciation: [
                CanonicalSyllable(base: "ㄓ", tone: .first),
                CanonicalSyllable(base: "ㄉㄠ", tone: .fourth),
            ],
            sourceWeight: 0.77
        )
        let store = StubLexiconStore(
            inventory: ["ㄓ", "ㄉㄠ"],
            patternResponses: [
                [.initial("ㄓ"), .initial("ㄉ")]: [zhiDao],
                [.exact(zh), .initial("ㄉ")]: [zhiDao],
            ]
        )
        let incompleteZh = SyllableEdge(
            tokenRange: 0..<1,
            constraint: zh,
            completeness: .incomplete,
            parserCost: SyllableParser.incompleteCost
        )
        let completeZh = SyllableEdge(
            tokenRange: 0..<1,
            constraint: zh,
            completeness: .complete,
            parserCost: 0
        )
        let initialD = SyllableEdge(
            tokenRange: 1..<2,
            constraint: d,
            completeness: .incomplete,
            parserCost: SyllableParser.incompleteCost
        )
        let lattice = SyllableLattice(
            tokenCount: 2,
            outgoingEdges: [[incompleteZh, completeZh], [initialD], []]
        )
        let wordLattice = try DictionaryMatcher(store: store).buildLattice(from: lattice)
        let edges = wordLattice.outgoingEdges[0].filter { $0.text == "知道" }
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.syllableEdges.map(\.completeness), [.complete, .incomplete])
        XCTAssertEqual(
            edges.first?.syllableEdges.reduce(0) { $0 + $1.parserCost },
            SyllableParser.incompleteCost
        )
    }

    func testCompleteSingleSymbolSyllableUsesSynthesizedAbbreviationEdge() throws {
        let wo = LexiconMatch(
            text: "我",
            pronunciation: [CanonicalSyllable(base: "ㄨㄛ", tone: .third)],
            sourceWeight: 0.9
        )
        let store = StubLexiconStore(
            inventory: ["ㄨ", "ㄨㄛ"],
            patternResponses: [[.initial("ㄨ")]: [wo]]
        )
        let parser = SyllableParser(syllableBases: store.inventory)
        let lattice = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄨ"))
        )
        let edge = try XCTUnwrap(lattice.outgoingEdges[0].first { $0.text == "我" })
        XCTAssertEqual(edge.tokenRange, 0..<1)
        XCTAssertEqual(edge.pronunciation, wo.pronunciation)
        XCTAssertEqual(edge.syllableEdges.map(\.completeness), [.incomplete])
        XCTAssertEqual(edge.syllableEdges.map(\.parserCost), [SyllableParser.incompleteCost])
        XCTAssertEqual(store.patternQueries, [[.initial("ㄨ")]])
    }

    func testTonedSingleSymbolIsNotAnAbbreviation() throws {
        let store = StubLexiconStore(inventory: ["ㄨ", "ㄨㄛ"])
        let parser = SyllableParser(syllableBases: store.inventory)
        _ = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄨ", tone: .fourth))
        )
        XCTAssertEqual(store.queries, [[SyllableConstraint(base: "ㄨ", tone: .fourth)]])
        XCTAssertTrue(store.patternQueries.isEmpty)
    }
}

final class StubLexiconStore: LexiconStore, @unchecked Sendable {
    let inventory: [String]
    let responses: [[SyllableConstraint]: [LexiconMatch]]
    let patternResponses: [[SyllableMatchPattern]: [LexiconMatch]]
    private(set) var queries: [[SyllableConstraint]] = []
    private(set) var patternQueries: [[SyllableMatchPattern]] = []
    private(set) var patternResultLimits: [Int] = []
    private(set) var patternScanLimits: [Int] = []
    private let lock = NSLock()

    init(
        inventory: [String],
        responses: [[SyllableConstraint]: [LexiconMatch]] = [:],
        patternResponses: [[SyllableMatchPattern]: [LexiconMatch]] = [:]
    ) {
        self.inventory = inventory
        self.responses = responses
        self.patternResponses = patternResponses
    }

    func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch] {
        lock.lock()
        defer { lock.unlock() }
        queries.append(syllables)
        return responses[syllables] ?? []
    }

    func patternMatches(
        for patterns: [SyllableMatchPattern],
        resultLimit: Int,
        scanLimit: Int
    ) throws -> [LexiconMatch] {
        lock.lock()
        defer { lock.unlock() }
        patternQueries.append(patterns)
        patternResultLimits.append(resultLimit)
        patternScanLimits.append(scanLimit)
        let matches = (patternResponses[patterns] ?? []).filter { match in
            guard match.pronunciation.count == patterns.count else { return false }
            return zip(patterns, match.pronunciation).allSatisfy { pattern, syllable in
                pattern.accepts(base: syllable.base, tone: syllable.tone)
            }
        }
        return Array(matches.prefix(max(0, resultLimit)))
    }

    func syllableInventory() throws -> [String] {
        inventory
    }
}
