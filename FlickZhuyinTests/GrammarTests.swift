import XCTest

private func fixtureGramURL(for testCase: XCTestCase) throws -> URL {
    try XCTUnwrap(
        Bundle(for: type(of: testCase)).url(forResource: "flickzhuyin-tests", withExtension: "gram"),
        "flickzhuyin-tests.gram is missing from the test bundle"
    )
}

final class MappedGramStoreTests: XCTestCase {
    func testLooksUpFixtureKeysAcrossBlocks() throws {
        let store = try MappedGramStore(url: try fixtureGramURL(for: self))
        XCTAssertEqual(store.keyCount, 10)
        // Values are stored as `(value - smallest) >> 1`; the smallest (〇點,
        // 69697) is odd, so odd values survive exactly and even ones lose 1.
        XCTAssertEqual(store.value(forKey: "〇點"), 69697)
        XCTAssertEqual(store.value(forKey: "天氣很"), 110235)
        XCTAssertEqual(store.value(forKey: "中文"), 99999)
        XCTAssertEqual(store.value(forKey: "𠀀字"), 79999)
        XCTAssertEqual(store.value(forKey: "的$"), 188027)
        XCTAssertNil(store.value(forKey: "$我"), "sentence-start keys are dropped at build time")
        XCTAssertNil(store.value(forKey: "天氣"))
        XCTAssertNil(store.value(forKey: "天氣很好好"))
        XCTAssertNil(store.value(forKey: "一"))
        XCTAssertNil(store.value(forKey: "龘"))
    }

    func testReportsWhetherLongerKeysExist() throws {
        let store = try MappedGramStore(url: try fixtureGramURL(for: self))
        XCTAssertEqual(store.lookup(Array("天氣".utf8)), .init(value: nil, hasExtensions: true))
        XCTAssertEqual(store.lookup(Array("天氣很".utf8)), .init(value: 110235, hasExtensions: true))
        XCTAssertEqual(store.lookup(Array("我們今天".utf8)).hasExtensions, false)
        XCTAssertEqual(store.lookup(Array("天".utf8)).hasExtensions, true)
        XCTAssertEqual(store.lookup(Array("〇".utf8)).hasExtensions, true, "the first key extends a target that sorts before it")
        XCTAssertEqual(store.lookup(Array("天空".utf8)), .init(value: nil, hasExtensions: false))
    }

    func testRejectsInvalidFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = try Data(contentsOf: try fixtureGramURL(for: self))
        var badMagic = valid
        badMagic[0] = UInt8(ascii: "X")
        let cases: [(String, Data)] = [
            ("empty", Data()),
            ("bad-magic", badMagic),
            ("truncated", valid.prefix(valid.count - 8)),
        ]
        for (name, data) in cases {
            let url = directory.appendingPathComponent("\(name).gram")
            try data.write(to: url)
            XCTAssertThrowsError(try MappedGramStore(url: url), name) { error in
                XCTAssertTrue(error is GramStoreError, "\(name): \(error)")
            }
        }
        XCTAssertThrowsError(try MappedGramStore(url: directory.appendingPathComponent("missing.gram")))
    }
}

final class OctagramGrammarTests: XCTestCase {
    private func grammar() throws -> OctagramGrammar {
        OctagramGrammar(store: try MappedGramStore(url: try fixtureGramURL(for: self)))
    }

    func testCollocationUsesLongestContextAndWordPrefix() throws {
        // 天氣+很: context 2 + match 1 reaches the minimum length 3.
        XCTAssertEqual(try grammar().query(context: "天氣", word: "很好", isRear: false), 11.0235 - 12, accuracy: 1e-9)
        // Only the last three characters of context are read.
        XCTAssertEqual(try grammar().query(context: "今天天氣", word: "很好", isRear: false), 11.0235 - 12, accuracy: 1e-9)
    }

    func testShortMatchIsWeakUnlessItCoversTheWholeQuery() throws {
        // 氣+很 covers all of context "氣" and all of word "很": a full collocation.
        XCTAssertEqual(try grammar().query(context: "氣", word: "很", isRear: false), 8.9999 - 12, accuracy: 1e-9)
        // 氣+很 is only part of word "很好": weak (9 - 24), so the floor wins.
        XCTAssertEqual(try grammar().query(context: "氣", word: "很好", isRear: false), -12)
    }

    func testRearUsesSentenceEndKeys() throws {
        let grammar = try grammar()
        XCTAssertEqual(grammar.query(context: "我們", word: "的", isRear: true), 18.8028 - 18, accuracy: 2e-4)
        XCTAssertEqual(grammar.query(context: "我們", word: "的", isRear: false), -12)
        XCTAssertEqual(grammar.query(context: "我", word: "你好", isRear: true), 15.0 - 18, accuracy: 2e-4)
    }

    func testMissingContextOrCollocationReturnsTheFloor() throws {
        let grammar = try grammar()
        XCTAssertEqual(grammar.query(context: "", word: "的", isRear: true), -12)
        XCTAssertEqual(grammar.query(context: "天氣", word: "", isRear: false), -12)
        XCTAssertEqual(grammar.query(context: "天空", word: "很好", isRear: false), -12)
    }
}

final class GrammarContextTests: XCTestCase {
    func testTailStopsAtNonLetters() {
        XCTAssertEqual(GrammarContext.tail(of: nil), "")
        XCTAssertEqual(GrammarContext.tail(of: "今天天氣"), "今天天氣")
        XCTAssertEqual(GrammarContext.tail(of: "好。天氣"), "天氣")
        XCTAssertEqual(GrammarContext.tail(of: "第一行\n天氣"), "天氣")
        XCTAssertEqual(GrammarContext.tail(of: "天氣 "), "")
        XCTAssertEqual(GrammarContext.tail(of: "一二三四五六七八九十"), "三四五六七八九十")
    }

    func testCompositionContextStopsAtUnconvertedTokens() {
        var composition = ZhuyinComposition()
        composition.pieces = [
            .selected(SelectedChunk(text: "甲", sourceTokens: [.symbol("ㄐ")], pronunciation: [])),
            .token(.symbol("ㄅ")),
            .selected(SelectedChunk(text: "乙", sourceTokens: [.symbol("ㄧ")], pronunciation: [])),
            .selected(SelectedChunk(text: "丙", sourceTokens: [.symbol("ㄅ")], pronunciation: [])),
            .token(.symbol("ㄉ")),
        ]
        composition.caretIndex = 5
        XCTAssertEqual(composition.precedingContext.text, "乙丙")
        XCTAssertFalse(composition.precedingContext.reachesStart)

        composition.pieces.remove(at: 1)
        composition.caretIndex = 4
        XCTAssertEqual(composition.precedingContext.text, "甲乙丙")
        XCTAssertTrue(composition.precedingContext.reachesStart)
    }
}

/// Returns fixed scores for `context|word` pairs and records every query.
private final class StubGrammar: GrammarModel, @unchecked Sendable {
    private final class Scorer: GrammarContextScorer {
        let grammar: StubGrammar
        let context: String

        init(grammar: StubGrammar, context: String) {
            self.grammar = grammar
            self.context = context
        }

        func score(word: String, isRear: Bool) -> Double {
            grammar.queries.append("\(context)|\(word)")
            return grammar.scores["\(context)|\(word)"] ?? grammar.nonCollocationPenalty
        }
    }

    let nonCollocationPenalty = -12.0
    let contextWindow = 8
    let scores: [String: Double]
    fileprivate(set) var queries: [String] = []

    init(_ scores: [String: Double]) {
        self.scores = scores
    }

    func scorer(forContext context: String) -> any GrammarContextScorer {
        Scorer(grammar: self, context: context)
    }
}

final class GrammarDecoderTests: XCTestCase {
    private let first = SyllableConstraint(base: "ㄅ", tone: .first)
    private let second = SyllableConstraint(base: "ㄆ", tone: .first)

    private func edge(_ lower: Int, _ constraint: SyllableConstraint) -> SyllableEdge {
        SyllableEdge(tokenRange: lower..<(lower + 1), constraint: constraint, completeness: .complete, parserCost: 0)
    }

    private func word(_ lower: Int, _ text: String, _ constraint: SyllableConstraint, weight: Double) -> WordEdge {
        WordEdge(
            tokenRange: lower..<(lower + 1),
            text: text,
            pronunciation: [CanonicalSyllable(base: constraint.base, tone: constraint.tone ?? .first)],
            sourceWeight: weight,
            pronunciationWeight: nil,
            syllableEdges: [edge(lower, constraint)]
        )
    }

    /// Two positions; 甲 beats 乙 on its own, and 丙 is the only second word.
    private func lattices() -> (SyllableLattice, WordLattice) {
        let syllable = SyllableLattice(
            tokenCount: 2,
            outgoingEdges: [[edge(0, first)], [edge(1, second)], []]
        )
        let words = WordLattice(
            tokenCount: 2,
            outgoingEdges: [
                [word(0, "甲", first, weight: 0.5), word(0, "乙", first, weight: 0.4)],
                [word(1, "丙", second, weight: 0.5)],
                [],
            ]
        )
        return (syllable, words)
    }

    func testNeutralGrammarChargesEverySegmentTheFloor() throws {
        let (syllable, words) = lattices()
        let baseline = try Decoder().decode(syllableLattice: syllable, wordLattice: words)
        let neutral = try Decoder(grammar: StubGrammar([:]))
            .decode(syllableLattice: syllable, wordLattice: words, precedingText: "前")
        // Every candidate here has two segments, words or raw syllables alike,
        // so each pays the floor (-(-12)) twice and the order is unchanged.
        XCTAssertEqual(neutral.map(\.text), baseline.map(\.text))
        for (lhs, rhs) in zip(neutral, baseline) {
            XCTAssertEqual(lhs.score, rhs.score + 24, accuracy: 1e-9)
            XCTAssertEqual(lhs.segments, rhs.segments)
        }
    }

    func testFloorFavorsFewerSegments() throws {
        let syllable = SyllableLattice(
            tokenCount: 2,
            outgoingEdges: [[edge(0, first)], [edge(1, second)], []]
        )
        let whole = WordEdge(
            tokenRange: 0..<2,
            text: "甲乙",
            pronunciation: [first, second].map { CanonicalSyllable(base: $0.base, tone: $0.tone ?? .first) },
            sourceWeight: 0.2,
            pronunciationWeight: nil,
            syllableEdges: [edge(0, first), edge(1, second)]
        )
        let words = WordLattice(
            tokenCount: 2,
            outgoingEdges: [[word(0, "丙", first, weight: 0.9), whole], [word(1, "丁", second, weight: 0.9)], []]
        )
        XCTAssertEqual(try Decoder().decode(syllableLattice: syllable, wordLattice: words).first?.text, "丙丁")
        XCTAssertEqual(
            try Decoder(grammar: StubGrammar([:])).decode(syllableLattice: syllable, wordLattice: words).first?.text,
            "甲乙"
        )
    }

    func testCollocationWithNextWordFlipsTheBest() throws {
        let (syllable, words) = lattices()
        let grammar = StubGrammar(["乙|丙": -10])
        let candidates = try Decoder(grammar: grammar).decode(syllableLattice: syllable, wordLattice: words)
        XCTAssertEqual(candidates.first?.text, "乙丙")
        let baseline = try Decoder().decode(syllableLattice: syllable, wordLattice: words)
        let baselineScore = try XCTUnwrap(baseline.first { $0.text == "乙丙" }).score
        // Two segments at the floor (24), minus the 2-point collocation gain.
        XCTAssertEqual(candidates[0].score, baselineScore + 24 - 2, accuracy: 1e-9)
    }

    func testPrecedingTextConditionsTheFirstWord() throws {
        let (syllable, words) = lattices()
        let grammar = StubGrammar(["前|乙": -10])
        let withContext = try Decoder(grammar: grammar)
            .decode(syllableLattice: syllable, wordLattice: words, precedingText: "前")
        XCTAssertEqual(withContext.first?.text, "乙丙")
        let withoutContext = try Decoder(grammar: grammar).decode(syllableLattice: syllable, wordLattice: words)
        XCTAssertEqual(withoutContext.first?.text, "甲丙")
    }

    func testContextIsTheLastTwoWords() throws {
        let third = SyllableConstraint(base: "ㄇ", tone: .first)
        let syllable = SyllableLattice(
            tokenCount: 3,
            outgoingEdges: [[edge(0, first)], [edge(1, second)], [edge(2, third)], []]
        )
        let words = WordLattice(
            tokenCount: 3,
            outgoingEdges: [
                [word(0, "甲", first, weight: 0.5)],
                [word(1, "乙", second, weight: 0.5)],
                [word(2, "丙", third, weight: 0.5)],
                [],
            ]
        )
        let grammar = StubGrammar([:])
        _ = try Decoder(grammar: grammar).decode(syllableLattice: syllable, wordLattice: words, precedingText: "前")
        XCTAssertTrue(grammar.queries.contains("前|甲"))
        XCTAssertTrue(grammar.queries.contains("前甲|乙"))
        XCTAssertTrue(grammar.queries.contains("甲乙|丙"))
    }

    func testRawSyllablesResetContext() throws {
        let (syllable, _) = lattices()
        let words = WordLattice(
            tokenCount: 2,
            outgoingEdges: [[], [word(1, "丙", second, weight: 0.5)], []]
        )
        let grammar = StubGrammar([:])
        let candidates = try Decoder(grammar: grammar)
            .decode(syllableLattice: syllable, wordLattice: words, precedingText: "前")
        XCTAssertTrue(candidates.contains { $0.text == "ㄅˉ丙" })
        XCTAssertFalse(grammar.queries.contains { $0.hasSuffix("|丙") }, "丙 follows a raw syllable")
    }

    func testInvalidBeamWidthIsRejected() {
        var configuration = DecoderConfiguration()
        configuration.beamWidth = 0
        let (syllable, words) = lattices()
        XCTAssertThrowsError(
            try Decoder(configuration: configuration, grammar: StubGrammar([:]))
                .decode(syllableLattice: syllable, wordLattice: words)
        )
    }
}

final class GrammarProductionIntegrationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeDecoderInputs() throws -> (SQLiteLexiconStore, OctagramGrammar) {
        let grammarURL = repositoryRoot.appendingPathComponent("Generated/flickzhuyin.gram")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: grammarURL.path),
            "run build-grammar to generate Generated/flickzhuyin.gram"
        )
        let store = try SQLiteLexiconStore(url: repositoryRoot.appendingPathComponent("Generated/flickzhuyin.sqlite3"))
        return (store, OctagramGrammar(store: try MappedGramStore(url: grammarURL)))
    }

    private func decode(
        _ tokens: [ZhuyinInputToken],
        precedingText: String,
        store: SQLiteLexiconStore,
        grammar: OctagramGrammar?
    ) throws -> [DecodedCandidate] {
        let parser = try SyllableParser(store: store)
        let syllableLattice = parser.lattice(for: tokens)
        let wordLattice = try DictionaryMatcher(store: store).buildLattice(from: syllableLattice)
        return try Decoder(configuration: DecoderConfiguration(maximumCandidates: 30), grammar: grammar)
            .decode(syllableLattice: syllableLattice, wordLattice: wordLattice, precedingText: precedingText)
    }

    func testGoldenCollocationsMatchUpstreamValues() throws {
        let (_, grammar) = try makeDecoderInputs()
        XCTAssertEqual(try XCTUnwrap(grammar.store.value(forKey: "天氣很")), 110235, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(grammar.store.value(forKey: "我們今天")), 122373, accuracy: 1)
        XCTAssertEqual(grammar.query(context: "天氣", word: "很好", isRear: false), 11.0235 - 12, accuracy: 2e-4)
    }

    private struct GoldEntry {
        let precedingText: String
        let input: String
        let tokens: [ZhuyinInputToken]
        let expected: String
    }

    private func goldEntries() throws -> [GoldEntry] {
        let url = repositoryRoot.appendingPathComponent("FlickZhuyinTests/Fixtures/ranking-gold.tsv")
        let tones = Dictionary(uniqueKeysWithValues: MandarinTone.allCases.map { ($0.symbol, $0) })
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") }
            .map { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                XCTAssertEqual(fields.count, 3, "malformed gold line: \(line)")
                let tokens: [ZhuyinInputToken] = fields[1].map { character in
                    tones[String(character)].map(ZhuyinInputToken.tone) ?? .symbol(character)
                }
                return GoldEntry(precedingText: fields[0], input: fields[1], tokens: tokens, expected: fields[2])
            }
    }

    private func topCandidates(
        for entries: [GoldEntry],
        store: SQLiteLexiconStore,
        grammar: OctagramGrammar?,
        grammarWeight: Double = DecoderConfiguration().grammarWeight
    ) async throws -> [String?] {
        var configuration = DecoderConfiguration(maximumCandidates: 30)
        configuration.grammarWeight = grammarWeight
        let pipeline = try LexiconChineseInputPipeline(
            store: store,
            decoder: Decoder(configuration: configuration, grammar: grammar)
        )
        var result: [String?] = []
        for entry in entries {
            let candidates = try await pipeline.candidates(for: entry.tokens, precedingText: entry.precedingText)
            result.append(candidates.first?.text)
        }
        return result
    }

    /// Reports top-1 accuracy on `ranking-gold.tsv` with and without the
    /// language model (and at a few grammar weights, for calibration).
    func testRankingGoldSet() async throws {
        let (store, grammar) = try makeDecoderInputs()
        let entries = try goldEntries()
        XCTAssertFalse(entries.isEmpty)

        func accuracy(_ tops: [String?]) -> Int {
            zip(entries, tops).filter { $0.expected == $1 }.count
        }
        let baseline = try await topCandidates(for: entries, store: store, grammar: nil)
        let withGrammar = try await topCandidates(for: entries, store: store, grammar: grammar)
        print("GOLD baseline: \(accuracy(baseline))/\(entries.count), grammar: \(accuracy(withGrammar))/\(entries.count)")
        for weight in [0.02, 0.05, 0.1, 0.2, 0.5] {
            let tops = try await topCandidates(for: entries, store: store, grammar: grammar, grammarWeight: weight)
            print("GOLD grammarWeight \(weight): \(accuracy(tops))/\(entries.count)")
        }
        for (index, entry) in entries.enumerated() where withGrammar[index] != entry.expected || baseline[index] != entry.expected {
            print(
                "GOLD \(entry.precedingText)|\(entry.input): expected \(entry.expected), "
                    + "baseline \(baseline[index] ?? "-"), grammar \(withGrammar[index] ?? "-")"
            )
        }
        XCTAssertGreaterThanOrEqual(accuracy(withGrammar), accuracy(baseline))
    }

    func testGrammarDecodesSentencesAndKeepsCandidateCount() throws {
        let (store, grammar) = try makeDecoderInputs()
        let tokens: [ZhuyinInputToken] = [
            .symbol("ㄏ"), .symbol("ㄣ"), .tone(.third), .symbol("ㄏ"), .symbol("ㄠ"), .tone(.third),
        ]
        let candidates = try decode(tokens, precedingText: "天氣", store: store, grammar: grammar)
        XCTAssertEqual(candidates.first?.text, "很好")
        XCTAssertGreaterThan(candidates.count, 5)
        XCTAssertLessThanOrEqual(candidates.count, 30)
    }
}
