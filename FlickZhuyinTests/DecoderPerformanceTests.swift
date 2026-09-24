import XCTest

final class DecoderPerformanceTests: XCTestCase {
    // These broad p95 budgets catch algorithmic blow-ups while tolerating simulator and host
    // scheduling variance. Product latency targets should be benchmarked separately on devices.
#if DEBUG
    private let maximumDecodeP95: TimeInterval = 0.250
    // Unoptimized builds run the grammar beam search about 7x slower than
    // Release; this still catches a blow-up like an order-of-magnitude regression.
    private let maximumGrammarDecodeCPUP95: TimeInterval = 0.500
    private let maximumPipelineP95: TimeInterval = 1.000
    private let decodeSamples = 20
    private let pipelineSamples = 10
#else
    private let maximumDecodeP95: TimeInterval = 0.100
    private let maximumGrammarDecodeCPUP95: TimeInterval = 0.100
    private let maximumPipelineP95: TimeInterval = 0.250
    private let decodeSamples = 20
    private let pipelineSamples = 10
#endif

    private let syllables = ["ㄓㄨ", "ㄅㄚ", "ㄋㄧ", "ㄏㄠ", "ㄧㄣ", "ㄕ", "ㄖ", "ㄩ", "ㄨㄛ", "ㄍㄨㄛ"]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var databaseURL: URL {
        repositoryRoot.appendingPathComponent("Generated/flickzhuyin.sqlite3")
    }

    func testTenTokenTopKDecodeLatency() throws {
        let store = try SQLiteLexiconStore(url: databaseURL)
        let parser = try SyllableParser(store: store)
        let matcher = DictionaryMatcher(store: store)
        let decoder = Decoder()
        var pairs: [(SyllableLattice, WordLattice)] = []
        for syllable in syllables {
            let tokens = String(repeating: syllable, count: 5).map { ZhuyinInputToken.symbol($0) }
            let syllableLattice = parser.lattice(for: tokens)
            let wordLattice = try matcher.buildLattice(from: syllableLattice)
            pairs.append((syllableLattice, wordLattice))
        }
        var durations: [TimeInterval] = []
        for pair in pairs {
            for _ in 0..<decodeSamples {
                let duration = try measure {
                    _ = try decoder.decode(syllableLattice: pair.0, wordLattice: pair.1)
                }
                durations.append(duration)
            }
        }
        durations.sort()
        let p95 = percentile95(durations)
        print(
            "PERF 10-token decoder min: \(milliseconds(durations[0])) ms, "
                + "avg: \(milliseconds(average(durations))) ms, "
                + "p95: \(milliseconds(p95)) ms"
        )
        XCTAssertLessThan(p95, maximumDecodeP95)
    }

    func testTenTokenGrammarDecodeLatency() throws {
        let grammarURL = repositoryRoot.appendingPathComponent("Generated/flickzhuyin.gram")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: grammarURL.path),
            "run build-grammar to generate Generated/flickzhuyin.gram"
        )
        let store = try SQLiteLexiconStore(url: databaseURL)
        let parser = try SyllableParser(store: store)
        let matcher = DictionaryMatcher(store: store)
        // Match the keyboard: 30 candidates, with committed text as context.
        let decoder = Decoder(
            configuration: DecoderConfiguration(maximumCandidates: 30),
            grammar: OctagramGrammar(store: try MappedGramStore(url: grammarURL))
        )
        var pairs: [(SyllableLattice, WordLattice)] = []
        for syllable in syllables {
            let tokens = String(repeating: syllable, count: 5).map { ZhuyinInputToken.symbol($0) }
            let syllableLattice = parser.lattice(for: tokens)
            pairs.append((syllableLattice, try matcher.buildLattice(from: syllableLattice)))
        }
        // Thread CPU time, not wall time: the grammar decode is pure CPU work
        // (the store is memory-mapped and warm), and wall time on a shared
        // host mostly measured how long the thread waited to be scheduled.
        var durations: [TimeInterval] = []
        for pair in pairs {
            for _ in 0..<decodeSamples {
                durations.append(
                    try measureThreadCPU {
                        _ = try decoder.decode(
                            syllableLattice: pair.0,
                            wordLattice: pair.1,
                            precedingText: "我們今天"
                        )
                    }
                )
            }
        }
        durations.sort()
        let p95 = percentile95(durations)
        print(
            "PERF 10-token grammar decoder CPU min: \(milliseconds(durations[0])) ms, "
                + "avg: \(milliseconds(average(durations))) ms, "
                + "p95: \(milliseconds(p95)) ms"
        )
        XCTAssertLessThan(p95, maximumGrammarDecodeCPUP95)
    }

    func testTenTokenPipelineLatency() throws {
        let store = try SQLiteLexiconStore(url: databaseURL)
        let parser = try SyllableParser(store: store)
        let matcher = DictionaryMatcher(store: store)
        let decoder = Decoder()
        var durations: [TimeInterval] = []
        for syllable in syllables {
            let tokens = String(repeating: syllable, count: 5).map { ZhuyinInputToken.symbol($0) }
            for _ in 0..<pipelineSamples {
                let duration = try measure {
                    let syllableLattice = parser.lattice(for: tokens)
                    let wordLattice = try matcher.buildLattice(from: syllableLattice)
                    _ = try decoder.decode(syllableLattice: syllableLattice, wordLattice: wordLattice)
                }
                durations.append(duration)
            }
        }
        durations.sort()
        let p95 = percentile95(durations)
        print(
            "PERF 10-token parser+matcher+decoder min: \(milliseconds(durations[0])) ms, "
                + "avg: \(milliseconds(average(durations))) ms, "
                + "p95: \(milliseconds(p95)) ms"
        )
        XCTAssertLessThan(p95, maximumPipelineP95)
    }

    func testCandidateLimitKeepsSearchBounded() throws {
        let firstSyllable = SyllableEdge(
            tokenRange: 0..<1,
            constraint: SyllableConstraint(base: "ㄓ", tone: .first),
            completeness: .complete,
            parserCost: 0
        )
        let secondSyllable = SyllableEdge(
            tokenRange: 1..<2,
            constraint: SyllableConstraint(base: "ㄨ", tone: .first),
            completeness: .complete,
            parserCost: 0
        )
        let wordEdges = (0..<20).map { index in
            WordEdge(
                tokenRange: 0..<2,
                text: "W\(index)",
                pronunciation: [
                    CanonicalSyllable(base: "ㄓ", tone: .first),
                    CanonicalSyllable(base: "ㄨ", tone: .first),
                ],
                sourceWeight: 0.9 - Double(index) * 0.02,
                syllableEdges: [firstSyllable, secondSyllable]
            )
        }
        let syllableLattice = SyllableLattice(
            tokenCount: 2,
            outgoingEdges: [
                [firstSyllable, SyllableEdge(tokenRange: 0..<2, constraint: SyllableConstraint(base: "ㄓㄨ", tone: .first), completeness: .complete, parserCost: 0)],
                [secondSyllable],
                [],
            ]
        )
        let wordLattice = WordLattice(tokenCount: 2, outgoingEdges: [wordEdges, [], []])
        var configuration = DecoderConfiguration()
        configuration.maximumCandidates = 10
        let candidates = try Decoder(configuration: configuration).decode(
            syllableLattice: syllableLattice,
            wordLattice: wordLattice
        )
        XCTAssertEqual(candidates.count, 10)
        XCTAssertEqual(candidates.map(\.text), (0..<10).map { "W\($0)" })
    }

    private func measure(_ body: () throws -> Void) rethrows -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        try body()
        return ProcessInfo.processInfo.systemUptime - start
    }

    private func measureThreadCPU(_ body: () throws -> Void) rethrows -> TimeInterval {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        try body()
        return TimeInterval(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000_000
    }

    private func average(_ durations: [TimeInterval]) -> TimeInterval {
        durations.reduce(0, +) / Double(durations.count)
    }

    private func percentile95(_ sortedDurations: [TimeInterval]) -> TimeInterval {
        sortedDurations[min(sortedDurations.count - 1, Int(Double(sortedDurations.count) * 0.95))]
    }

    private func milliseconds(_ interval: TimeInterval) -> String {
        String(format: "%.3f", interval * 1000)
    }
}
