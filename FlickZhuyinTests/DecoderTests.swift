import XCTest

private func makeSyllableLattice(tokenCount: Int, buckets: [Int: [SyllableEdge]]) -> SyllableLattice {
    var outgoing = Array(repeating: [SyllableEdge](), count: tokenCount + 1)
    for (position, edges) in buckets {
        outgoing[position] = edges
    }
    return SyllableLattice(tokenCount: tokenCount, outgoingEdges: outgoing)
}

private func makeWordLattice(tokenCount: Int, buckets: [Int: [WordEdge]]) -> WordLattice {
    var outgoing = Array(repeating: [WordEdge](), count: tokenCount + 1)
    for (position, edges) in buckets {
        outgoing[position] = edges
    }
    return WordLattice(tokenCount: tokenCount, outgoingEdges: outgoing)
}

private func rawEdge(
    _ lower: Int,
    _ upper: Int,
    base: String,
    tone: MandarinTone? = nil,
    completeness: SyllableCompleteness = .complete,
    parserCost: Double = 0
) -> SyllableEdge {
    SyllableEdge(
        tokenRange: lower..<upper,
        constraint: SyllableConstraint(base: base, tone: tone),
        completeness: completeness,
        parserCost: parserCost
    )
}

private func testWord(
    _ lower: Int,
    _ upper: Int,
    text: String,
    syllables: [SyllableConstraint],
    pronunciation: [CanonicalSyllable]? = nil,
    weight: Double?,
    parserCost: Double = 0
) -> WordEdge {
    let edges = syllables.enumerated().map { offset, constraint in
        SyllableEdge(
            tokenRange: (lower + offset)..<(lower + offset + 1),
            constraint: constraint,
            completeness: .complete,
            parserCost: parserCost
        )
    }
    return WordEdge(
        tokenRange: lower..<upper,
        text: text,
        pronunciation: pronunciation ?? syllables.map { CanonicalSyllable(base: $0.base, tone: $0.tone ?? .first) },
        sourceWeight: weight,
        syllableEdges: edges
    )
}

private func assertInvalidLattice<T>(
    _ expression: @autoclosure () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        guard case .invalidLattice = error as? DecoderError else {
            return XCTFail("expected invalidLattice, got \(error)", file: file, line: line)
        }
    }
}

private func assertDecodeError<T>(
    _ expression: @autoclosure () throws -> T,
    _ expected: DecoderError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        XCTAssertEqual(error as? DecoderError, expected, file: file, line: line)
    }
}

private func assertSegmentsCover(_ candidate: DecodedCandidate, tokenCount: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(candidate.tokenRange, 0..<tokenCount, file: file, line: line)
    var cursor = 0
    for segment in candidate.segments {
        XCTAssertEqual(segment.tokenRange.lowerBound, cursor, file: file, line: line)
        cursor = segment.tokenRange.upperBound
    }
    XCTAssertEqual(cursor, tokenCount, file: file, line: line)
}

final class DecoderScorerTests: XCTestCase {
    private let scorer = BaselineDecoderScorer()

    func testWeightedWordCostUsesNegativeLogWeight() throws {
        let word = testWord(0, 1, text: "中", syllables: [SyllableConstraint(base: "ㄓ", tone: .first)], weight: 0.25, parserCost: 0.5)
        XCTAssertEqual(try scorer.cost(for: word), 0.5 + (-log(0.25)) + 0.25, accuracy: 1e-12)
    }

    func testUnweightedWordCostUsesConfigurationValue() throws {
        let word = testWord(
            0,
            3,
            text: "甲乙丙",
            syllables: [
                SyllableConstraint(base: "ㄐㄧㄚ", tone: .third),
                SyllableConstraint(base: "ㄧ", tone: .third),
                SyllableConstraint(base: "ㄅㄧㄥ", tone: .third),
            ],
            weight: nil
        )
        XCTAssertEqual(try scorer.cost(for: word), 8.0 + 0.25, accuracy: 1e-12)
    }

    func testZeroWeightUsesFloorAndStaysFinite() throws {
        let word = testWord(0, 1, text: "中", syllables: [SyllableConstraint(base: "ㄓ", tone: .first)], weight: 0)
        let cost = try scorer.cost(for: word)
        XCTAssertTrue(cost.isFinite)
        XCTAssertEqual(cost, (-log(1e-9)) + 0.25, accuracy: 1e-9)
    }

    func testIllegalWeightsThrow() {
        for weight in [-0.1, 1.1, Double.nan, Double.infinity, -Double.infinity] {
            let word = testWord(0, 1, text: "中", syllables: [SyllableConstraint(base: "ㄓ", tone: .first)], weight: weight)
            XCTAssertThrowsError(try scorer.cost(for: word), "weight \(weight)") { error in
                guard case .scoringFailed = error as? DecoderError else {
                    return XCTFail("expected scoringFailed, got \(error)")
                }
            }
        }
    }

    func testWordCostIncludesEveryParserCostAndOneBoundaryCost() throws {
        let word = testWord(
            0,
            2,
            text: "甲乙",
            syllables: [SyllableConstraint(base: "ㄓ", tone: .first), SyllableConstraint(base: "ㄨ", tone: .first)],
            weight: nil,
            parserCost: 1.5
        )
        XCTAssertEqual(try scorer.cost(for: word), 3.0 + 8.0 + 0.25, accuracy: 1e-12)
    }

    func testRawCompletenessPenalties() throws {
        XCTAssertEqual(try scorer.cost(forRaw: rawEdge(0, 1, base: "ㄅ", completeness: .complete, parserCost: 2)), 2 + 12)
        XCTAssertEqual(try scorer.cost(forRaw: rawEdge(0, 1, base: "ㄅ", completeness: .incomplete, parserCost: 4)), 4 + 16)
        XCTAssertEqual(try scorer.cost(forRaw: rawEdge(0, 1, base: "ㄅ", completeness: .fallback, parserCost: 12)), 12 + 20)
    }

    func testInvalidParserCostThrows() {
        let word = testWord(0, 1, text: "中", syllables: [SyllableConstraint(base: "ㄓ", tone: .first)], weight: nil, parserCost: -1)
        XCTAssertThrowsError(try scorer.cost(for: word))
        XCTAssertThrowsError(try scorer.cost(forRaw: rawEdge(0, 1, base: "ㄅ", parserCost: Double.nan)))
    }
}

final class DecoderGraphValidationTests: XCTestCase {
    func testTokenCountMismatchThrows() {
        let syllable = makeSyllableLattice(tokenCount: 1, buckets: [0: [rawEdge(0, 1, base: "ㄅ")]])
        let word = makeWordLattice(tokenCount: 2, buckets: [:])
        assertInvalidLattice(try Decoder().decode(syllableLattice: syllable, wordLattice: word))
    }

    func testBucketCountMismatchThrows() {
        let syllable = SyllableLattice(tokenCount: 1, outgoingEdges: [[rawEdge(0, 1, base: "ㄅ")]])
        let word = makeWordLattice(tokenCount: 1, buckets: [:])
        assertInvalidLattice(try Decoder().decode(syllableLattice: syllable, wordLattice: word))

        let goodSyllable = makeSyllableLattice(tokenCount: 1, buckets: [0: [rawEdge(0, 1, base: "ㄅ")]])
        let badWord = WordLattice(tokenCount: 1, outgoingEdges: [])
        assertInvalidLattice(try Decoder().decode(syllableLattice: goodSyllable, wordLattice: badWord))
    }

    func testBackwardZeroLengthAndOutOfBoundsEdgesThrow() {
        assertInvalidLattice(
            try Decoder().decode(
                syllableLattice: makeSyllableLattice(tokenCount: 2, buckets: [0: [rawEdge(1, 2, base: "ㄨ")], 1: [rawEdge(1, 2, base: "ㄨ")]]),
                wordLattice: makeWordLattice(tokenCount: 2, buckets: [:])
            )
        )
        assertInvalidLattice(
            try Decoder().decode(
                syllableLattice: makeSyllableLattice(tokenCount: 2, buckets: [0: [rawEdge(0, 0, base: "ㄅ")], 1: [rawEdge(1, 2, base: "ㄨ")]]),
                wordLattice: makeWordLattice(tokenCount: 2, buckets: [:])
            )
        )
        assertInvalidLattice(
            try Decoder().decode(
                syllableLattice: makeSyllableLattice(tokenCount: 2, buckets: [0: [rawEdge(0, 3, base: "ㄅ")], 1: [rawEdge(1, 2, base: "ㄨ")]]),
                wordLattice: makeWordLattice(tokenCount: 2, buckets: [:])
            )
        )
    }

    func testWordSyllableEdgesMustBeContiguous() {
        let first = rawEdge(0, 1, base: "ㄓ")
        let second = rawEdge(2, 3, base: "ㄨ")
        let word = WordEdge(
            tokenRange: 0..<3,
            text: "甲乙",
            pronunciation: [
                CanonicalSyllable(base: "ㄓ", tone: .first),
                CanonicalSyllable(base: "ㄨ", tone: .first),
            ],
            sourceWeight: nil,
            syllableEdges: [first, second]
        )
        assertInvalidLattice(
            try Decoder().decode(
                syllableLattice: makeSyllableLattice(tokenCount: 3, buckets: [0: [rawEdge(0, 1, base: "ㄓ"), rawEdge(0, 3, base: "ㄓㄨ")], 1: [rawEdge(1, 2, base: "ㄨ")], 2: [rawEdge(2, 3, base: "ㄨ")]]),
                wordLattice: makeWordLattice(tokenCount: 3, buckets: [0: [word]])
            )
        )
    }

    func testWordPronunciationCountMustMatchSyllableEdges() {
        let word = WordEdge(
            tokenRange: 0..<2,
            text: "甲乙",
            pronunciation: [CanonicalSyllable(base: "ㄓ", tone: .first)],
            sourceWeight: nil,
            syllableEdges: [rawEdge(0, 1, base: "ㄓ"), rawEdge(1, 2, base: "ㄨ")]
        )
        assertInvalidLattice(
            try Decoder().decode(
                syllableLattice: makeSyllableLattice(tokenCount: 2, buckets: [0: [rawEdge(0, 1, base: "ㄓ"), rawEdge(0, 2, base: "ㄓㄨ")], 1: [rawEdge(1, 2, base: "ㄨ")]]),
                wordLattice: makeWordLattice(tokenCount: 2, buckets: [0: [word]])
            )
        )
    }

    func testDisconnectedLatticeThrows() {
        assertDecodeError(
            try Decoder().decode(
                syllableLattice: makeSyllableLattice(tokenCount: 2, buckets: [0: [rawEdge(0, 1, base: "ㄅ")]]),
                wordLattice: makeWordLattice(tokenCount: 2, buckets: [:])
            ),
            .disconnectedLattice(position: 1)
        )
        assertDecodeError(
            try Decoder().decode(
                syllableLattice: makeSyllableLattice(tokenCount: 1, buckets: [:]),
                wordLattice: makeWordLattice(tokenCount: 1, buckets: [:])
            ),
            .disconnectedLattice(position: 0)
        )
    }

    func testInvalidConfigurationThrows() {
        var zeroCandidates = DecoderConfiguration()
        zeroCandidates.maximumCandidates = 0
        assertInvalidConfiguration(zeroCandidates)

        for floor in [0.0, 1.0, Double.nan] {
            var badFloor = DecoderConfiguration()
            badFloor.weightedEntryFloor = floor
            assertInvalidConfiguration(badFloor)
        }

        for cost in [-1.0, Double.nan, Double.infinity] {
            var badCost = DecoderConfiguration()
            badCost.unweightedWordCost = cost
            assertInvalidConfiguration(badCost)
        }
    }

    private func assertInvalidConfiguration(_ configuration: DecoderConfiguration, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(
            try Decoder(configuration: configuration).decode(
                syllableLattice: makeSyllableLattice(tokenCount: 1, buckets: [0: [rawEdge(0, 1, base: "ㄅ")]]),
                wordLattice: makeWordLattice(tokenCount: 1, buckets: [:])
            ),
            file: file,
            line: line
        ) { error in
            guard case .invalidConfiguration = error as? DecoderError else {
                return XCTFail("expected invalidConfiguration, got \(error)", file: file, line: line)
            }
        }
    }
}

final class DecoderTests: XCTestCase {
    func testSinglePathProducesSingleCandidate() throws {
        let syllable = makeSyllableLattice(tokenCount: 1, buckets: [0: [rawEdge(0, 1, base: "ㄅ")]])
        let word = makeWordLattice(tokenCount: 1, buckets: [:])
        let candidates = try Decoder().decode(syllableLattice: syllable, wordLattice: word)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].text, "ㄅ")
        XCTAssertEqual(candidates[0].pronunciation, [SyllableConstraint(base: "ㄅ")])
        XCTAssertEqual(candidates[0].score, 12, accuracy: 1e-12)
        assertSegmentsCover(candidates[0], tokenCount: 1)
    }

    func testWordPathsAreOrderedByScore() throws {
        let syllable = makeSyllableLattice(
            tokenCount: 2,
            buckets: [
                0: [
                    rawEdge(0, 1, base: "ㄓ", tone: .first),
                    rawEdge(0, 2, base: "ㄓㄨ", tone: .first),
                ],
                1: [rawEdge(1, 2, base: "ㄨ", tone: .first)],
            ]
        )
        let word = makeWordLattice(
            tokenCount: 2,
            buckets: [
                0: [
                    testWord(0, 2, text: "甲", syllables: [SyllableConstraint(base: "ㄓ", tone: .first), SyllableConstraint(base: "ㄨ", tone: .first)], weight: 0.5),
                    testWord(0, 2, text: "乙", syllables: [SyllableConstraint(base: "ㄓ", tone: .first), SyllableConstraint(base: "ㄨ", tone: .first)], weight: 0.25),
                ],
            ]
        )
        let candidates = try Decoder().decode(syllableLattice: syllable, wordLattice: word)
        XCTAssertEqual(candidates.prefix(2).map(\.text), ["甲", "乙"])
        XCTAssertLessThan(candidates[0].score, candidates[1].score)
        XCTAssertTrue(candidates.contains { $0.text == "ㄓㄨˉ" })
    }

    func testTopKLimitIsEnforced() throws {
        let syllable = makeSyllableLattice(
            tokenCount: 2,
            buckets: [
                0: [
                    rawEdge(0, 1, base: "ㄓ", tone: .first),
                    rawEdge(0, 2, base: "ㄓㄨ", tone: .first),
                ],
                1: [rawEdge(1, 2, base: "ㄨ", tone: .first)],
            ]
        )
        let weights = (0..<12).map { 0.9 - Double($0) * 0.05 }
        let word = makeWordLattice(
            tokenCount: 2,
            buckets: [
                0: weights.enumerated().map { index, weight in
                    testWord(
                        0,
                        2,
                        text: "W\(index)",
                        syllables: [
                            SyllableConstraint(base: "ㄓ", tone: .first),
                            SyllableConstraint(base: "ㄨ", tone: .first),
                        ],
                        weight: weight
                    )
                },
            ]
        )
        let candidates = try Decoder().decode(syllableLattice: syllable, wordLattice: word)
        XCTAssertEqual(candidates.count, 10)
        XCTAssertEqual(candidates[0].text, "W0")
        XCTAssertTrue(candidates.allSatisfy { $0.score.isFinite })
    }

    func testSameTextAndPronunciationKeepsBestSegmentation() throws {
        let syllable = makeSyllableLattice(
            tokenCount: 2,
            buckets: [
                0: [rawEdge(0, 1, base: "ㄓ", tone: .first)],
                1: [rawEdge(1, 2, base: "ㄨ", tone: .first)],
            ]
        )
        let word = makeWordLattice(
            tokenCount: 2,
            buckets: [
                0: [
                    testWord(0, 2, text: "甲乙", syllables: [SyllableConstraint(base: "ㄓ", tone: .first), SyllableConstraint(base: "ㄨ", tone: .first)], weight: 0.9),
                    testWord(0, 1, text: "甲", syllables: [SyllableConstraint(base: "ㄓ", tone: .first)], weight: 0.5),
                ],
                1: [
                    testWord(1, 2, text: "乙", syllables: [SyllableConstraint(base: "ㄨ", tone: .first)], weight: 0.5),
                ],
            ]
        )
        let candidates = try Decoder().decode(syllableLattice: syllable, wordLattice: word)
        let merged = candidates.filter { $0.text == "甲乙" }
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].pronunciation, [
            SyllableConstraint(base: "ㄓ", tone: .first),
            SyllableConstraint(base: "ㄨ", tone: .first),
        ])
        XCTAssertEqual(merged[0].score, (-log(0.9)) + 0.25, accuracy: 1e-12)
        XCTAssertEqual(merged[0].segments.count, 1)
    }

    func testSameTextWithDifferentPronunciationIsKeptSeparately() throws {
        let syllable = makeSyllableLattice(
            tokenCount: 2,
            buckets: [
                0: [rawEdge(0, 1, base: "ㄓ", tone: .first)],
                1: [rawEdge(1, 2, base: "ㄨ", tone: .first)],
            ]
        )
        let firstPronunciation = [
            CanonicalSyllable(base: "ㄓ", tone: .first),
            CanonicalSyllable(base: "ㄨ", tone: .first),
        ]
        let secondPronunciation = [
            CanonicalSyllable(base: "ㄓ", tone: .fourth),
            CanonicalSyllable(base: "ㄨ", tone: .first),
        ]
        let word = makeWordLattice(
            tokenCount: 2,
            buckets: [
                0: [
                    testWord(0, 2, text: "重音", syllables: [SyllableConstraint(base: "ㄓ", tone: .first), SyllableConstraint(base: "ㄨ", tone: .first)], pronunciation: firstPronunciation, weight: 0.5),
                    testWord(0, 2, text: "重音", syllables: [SyllableConstraint(base: "ㄓ", tone: .fourth), SyllableConstraint(base: "ㄨ", tone: .first)], pronunciation: secondPronunciation, weight: 0.5),
                ],
            ]
        )
        let candidates = try Decoder().decode(syllableLattice: syllable, wordLattice: word)
        let matching = candidates.filter { $0.text == "重音" }
        XCTAssertEqual(matching.count, 2)
        XCTAssertEqual(Set(matching.map(\.pronunciation)), [firstPronunciation.map { SyllableConstraint(base: $0.base, tone: $0.tone) }, secondPronunciation.map { SyllableConstraint(base: $0.base, tone: $0.tone) }])
    }

    func testWordAndRawCandidatesCoexist() throws {
        let syllable = makeSyllableLattice(
            tokenCount: 2,
            buckets: [
                0: [rawEdge(0, 2, base: "ㄓㄨ", tone: .first)],
                1: [rawEdge(1, 2, base: "ㄨ", tone: .first)],
            ]
        )
        let word = makeWordLattice(
            tokenCount: 2,
            buckets: [
                0: [
                    testWord(0, 2, text: "甲乙", syllables: [SyllableConstraint(base: "ㄓ", tone: .first), SyllableConstraint(base: "ㄨ", tone: .first)], weight: 0.9),
                ],
            ]
        )
        let candidates = try Decoder().decode(syllableLattice: syllable, wordLattice: word)
        XCTAssertEqual(Array(candidates.map(\.text).prefix(2)), ["甲乙", "ㄓㄨˉ"])
        XCTAssertEqual(candidates[1].segments, [.raw(syllable.outgoingEdges[0][0])])
    }

    func testRawTextKeepsExplicitTonesOnly() throws {
        let withTone = makeSyllableLattice(tokenCount: 1, buckets: [0: [rawEdge(0, 1, base: "ㄅ", tone: .first)]])
        let withoutTone = makeSyllableLattice(tokenCount: 1, buckets: [0: [rawEdge(0, 1, base: "ㄅ")]])
        let emptyWord = makeWordLattice(tokenCount: 1, buckets: [:])
        XCTAssertEqual(try Decoder().decode(syllableLattice: withTone, wordLattice: emptyWord)[0].text, "ㄅˉ")
        XCTAssertEqual(try Decoder().decode(syllableLattice: withoutTone, wordLattice: emptyWord)[0].text, "ㄅ")
    }

    func testBareToneFallbackKeepsTone() throws {
        let syllable = makeSyllableLattice(
            tokenCount: 1,
            buckets: [0: [rawEdge(0, 1, base: "", tone: .fourth, completeness: .fallback, parserCost: 12)]]
        )
        let candidates = try Decoder().decode(syllableLattice: syllable, wordLattice: makeWordLattice(tokenCount: 1, buckets: [:]))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].text, "ˋ")
        XCTAssertEqual(candidates[0].pronunciation, [SyllableConstraint(base: "", tone: .fourth)])
    }

    func testEmptyInputReturnsNoCandidates() throws {
        let syllable = makeSyllableLattice(tokenCount: 0, buckets: [:])
        let word = makeWordLattice(tokenCount: 0, buckets: [:])
        XCTAssertEqual(try Decoder().decode(syllableLattice: syllable, wordLattice: word), [])
    }

    func testRepeatedDecodeIsDeterministic() throws {
        let syllable = makeSyllableLattice(
            tokenCount: 3,
            buckets: [
                0: [rawEdge(0, 1, base: "ㄓ", tone: .first), rawEdge(0, 2, base: "ㄓㄨ", tone: .first)],
                1: [rawEdge(1, 2, base: "ㄨ", tone: .first), rawEdge(1, 3, base: "ㄨㄛ", tone: .third)],
                2: [rawEdge(2, 3, base: "ㄛ", tone: .third)],
            ]
        )
        let word = makeWordLattice(
            tokenCount: 3,
            buckets: [
                0: [
                    testWord(0, 2, text: "甲乙", syllables: [SyllableConstraint(base: "ㄓ", tone: .first), SyllableConstraint(base: "ㄨ", tone: .first)], weight: 0.5),
                    testWord(0, 3, text: "甲丙丁", syllables: [SyllableConstraint(base: "ㄓ", tone: .first), SyllableConstraint(base: "ㄨㄛ", tone: .third), SyllableConstraint(base: "ㄛ", tone: .third)], weight: 0.5),
                ],
                2: [
                    testWord(2, 3, text: "丁", syllables: [SyllableConstraint(base: "ㄛ", tone: .third)], weight: 0.8),
                ],
            ]
        )
        let decoder = Decoder()
        let first = try decoder.decode(syllableLattice: syllable, wordLattice: word)
        for _ in 0..<4 {
            XCTAssertEqual(try decoder.decode(syllableLattice: syllable, wordLattice: word), first)
        }
    }
}

final class DecoderFixtureIntegrationTests: ChineseInputTestCase {
    private func decode(_ tokens: [ZhuyinInputToken]) throws -> [DecodedCandidate] {
        let store = try makeFixtureStore()
        let parser = try SyllableParser(store: store)
        let matcher = DictionaryMatcher(store: store)
        let syllableLattice = parser.lattice(for: tokens)
        let wordLattice = try matcher.buildLattice(from: syllableLattice)
        return try Decoder().decode(syllableLattice: syllableLattice, wordLattice: wordLattice)
    }

    private func tokens(_ symbols: String, tones: [MandarinTone?] = []) -> [ZhuyinInputToken] {
        var result: [ZhuyinInputToken] = symbols.map { .symbol($0) }
        for tone in tones {
            if let tone {
                result.append(.tone(tone))
            }
        }
        return result
    }

    func testExplicitTonesProduceZhuyinWord() throws {
        let candidates = try decode(
            [.symbol("ㄓ"), .symbol("ㄨ"), .tone(.fourth), .symbol("ㄧ"), .symbol("ㄣ"), .tone(.first)]
        )
        XCTAssertEqual(candidates.first?.text, "注音")
        XCTAssertEqual(candidates.first?.pronunciation, [
            SyllableConstraint(base: "ㄓㄨ", tone: .fourth),
            SyllableConstraint(base: "ㄧㄣ", tone: .first),
        ])
        guard case .word? = candidates.first?.segments.first else {
            return XCTFail("expected 注音 to come from a dictionary word edge")
        }
    }

    func testTonelessInputStillProducesZhuyinWord() throws {
        let candidates = try decode(tokens("ㄓㄨㄧㄣ"))
        XCTAssertTrue(candidates.contains { $0.text == "注音" })
    }

    func testNiHaoWithTones() throws {
        let candidates = try decode(
            [.symbol("ㄋ"), .symbol("ㄧ"), .tone(.third), .symbol("ㄏ"), .symbol("ㄠ"), .tone(.third)]
        )
        XCTAssertTrue(candidates.contains { $0.text == "你好" })
    }

    func testPartiallySpecifiedToneMatches() throws {
        let tokens: [ZhuyinInputToken] = [
            .symbol("ㄓ"), .symbol("ㄨ"), .tone(.fourth), .symbol("ㄧ"), .symbol("ㄣ"),
        ]
        let candidates = try decode(tokens)
        let zhuyin = candidates.first { $0.text == "注音" }
        XCTAssertNotNil(zhuyin)
        XCTAssertEqual(zhuyin?.pronunciation, [
            SyllableConstraint(base: "ㄓㄨ", tone: .fourth),
            SyllableConstraint(base: "ㄧㄣ", tone: .first),
        ])
        for candidate in candidates {
            assertSegmentsCover(candidate, tokenCount: tokens.count)
        }
    }

    func testMismatchedToneFallsBackToRaw() throws {
        let tokens: [ZhuyinInputToken] = [
            .symbol("ㄓ"), .symbol("ㄨ"), .tone(.second), .symbol("ㄧ"), .symbol("ㄣ"), .tone(.first),
        ]
        let candidates = try decode(tokens)
        XCTAssertFalse(candidates.contains { $0.text == "注音" })
        XCTAssertFalse(candidates.isEmpty)
        for candidate in candidates {
            assertSegmentsCover(candidate, tokenCount: tokens.count)
            XCTAssertTrue(candidate.score.isFinite)
        }
    }

    func testUnfinishedSequenceStillProducesFullCoverage() throws {
        let tokens: [ZhuyinInputToken] = [
            .symbol("ㄅ"), .symbol("ㄓ"), .symbol("ㄨ"), .symbol("ㄧ"), .symbol("ㄥ"),
        ]
        let candidates = try decode(tokens)
        XCTAssertFalse(candidates.isEmpty)
        for candidate in candidates {
            assertSegmentsCover(candidate, tokenCount: tokens.count)
            XCTAssertTrue(candidate.score.isFinite)
        }
    }

}

final class DecoderProductionIntegrationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var databaseURL: URL {
        repositoryRoot.appendingPathComponent("Generated/flickzhuyin.sqlite3")
    }

    private func decode(_ tokens: [ZhuyinInputToken]) throws -> [DecodedCandidate] {
        let store = try SQLiteLexiconStore(url: databaseURL)
        let parser = try SyllableParser(store: store)
        let matcher = DictionaryMatcher(store: store)
        let syllableLattice = parser.lattice(for: tokens)
        let wordLattice = try matcher.buildLattice(from: syllableLattice)
        return try Decoder().decode(syllableLattice: syllableLattice, wordLattice: wordLattice)
    }

    private func tokens(_ symbols: String, tones: [MandarinTone?] = []) -> [ZhuyinInputToken] {
        var result: [ZhuyinInputToken] = symbols.map { .symbol($0) }
        for tone in tones {
            if let tone {
                result.append(.tone(tone))
            }
        }
        return result
    }

    func testZhuyinWordAppearsWithExplicitTones() throws {
        let tokens: [ZhuyinInputToken] = [
            .symbol("ㄓ"), .symbol("ㄨ"), .tone(.fourth), .symbol("ㄧ"), .symbol("ㄣ"), .tone(.first),
        ]
        let candidates = try decode(tokens)
        XCTAssertLessThanOrEqual(candidates.count, 10)
        let zhuyin = try XCTUnwrap(candidates.first { $0.text == "注音" })
        XCTAssertEqual(zhuyin.pronunciation, [
            SyllableConstraint(base: "ㄓㄨ", tone: .fourth),
            SyllableConstraint(base: "ㄧㄣ", tone: .first),
        ])
        XCTAssertEqual(zhuyin.segments.count, 1)
        guard case .word? = zhuyin.segments.first else {
            return XCTFail("expected 注音 to come from a dictionary word edge")
        }
        XCTAssertEqual(candidates, try decode(tokens))
    }

    func testTonelessInputContainsZhuyinWord() throws {
        let candidates = try decode(tokens("ㄓㄨㄧㄣ"))
        XCTAssertLessThanOrEqual(candidates.count, 10)
        XCTAssertTrue(candidates.contains { $0.text == "注音" })
        XCTAssertEqual(candidates, try decode(tokens("ㄓㄨㄧㄣ")))
    }

    func testRawFallbackRemainsAvailable() throws {
        let candidates = try decode(tokens("ㄅㄆ"))
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(
            candidates.allSatisfy { candidate in
                candidate.segments.contains { segment in
                    if case .raw = segment {
                        return true
                    }
                    return false
                }
            }
        )
    }

    func testTonelessInputStaysBoundedAndFinite() throws {
        let tokens: [ZhuyinInputToken] = [.symbol("ㄓ"), .symbol("ㄨ"), .symbol("ㄧ"), .symbol("ㄣ")]
        let candidates = try decode(tokens)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertLessThanOrEqual(candidates.count, 10)
        for candidate in candidates {
            assertSegmentsCover(candidate, tokenCount: tokens.count)
            XCTAssertTrue(candidate.score.isFinite)
        }
    }

    func testEveryCandidateCoversTheWholeInput() throws {
        let tokens: [ZhuyinInputToken] = [.symbol("ㄋ"), .symbol("ㄧ"), .symbol("ㄏ"), .symbol("ㄠ")]
        let candidates = try decode(tokens)
        XCTAssertFalse(candidates.isEmpty)
        for candidate in candidates {
            assertSegmentsCover(candidate, tokenCount: tokens.count)
        }
    }
}
