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
            ["ㄉㄜ", "ㄋㄧ", "ㄋㄩ", "ㄌㄩ", "ㄍㄨㄛ", "ㄏㄠ", "ㄐㄧㄝ", "ㄓ", "ㄓㄨ", "ㄓㄨㄥ",
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
        execute("PRAGMA user_version = 2", at: userVersion)
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
        let bases = Set(lattice.outgoingEdges[0].map(\.constraint.base))
        XCTAssertEqual(bases, ["ㄓ", "ㄓㄨ", "ㄓㄨㄥ"])
        XCTAssertTrue(lattice.outgoingEdges[0].allSatisfy { $0.completeness == .complete && $0.parserCost == 0 })
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

    func testIncompleteAndFallbackEdgesAreNotQueried() throws {
        let store = StubLexiconStore(inventory: ["ㄋㄧ"])
        let parser = SyllableParser(syllableBases: store.inventory)
        let lattice = try DictionaryMatcher(store: store).buildLattice(
            from: parser.lattice(for: tokens("ㄅ") + tokens("ㄋㄧ", tone: .third))
        )
        XCTAssertTrue(lattice.outgoingEdges[0].isEmpty)
        XCTAssertEqual(store.queries, [[SyllableConstraint(base: "ㄋㄧ", tone: .third)]])
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
}

final class StubLexiconStore: LexiconStore, @unchecked Sendable {
    let inventory: [String]
    let responses: [[SyllableConstraint]: [LexiconMatch]]
    private(set) var queries: [[SyllableConstraint]] = []
    private let lock = NSLock()

    init(inventory: [String], responses: [[SyllableConstraint]: [LexiconMatch]] = [:]) {
        self.inventory = inventory
        self.responses = responses
    }

    func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch] {
        lock.lock()
        defer { lock.unlock() }
        queries.append(syllables)
        return responses[syllables] ?? []
    }

    func syllableInventory() throws -> [String] {
        inventory
    }
}
