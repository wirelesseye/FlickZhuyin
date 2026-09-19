import XCTest

final class ChineseInputPerformanceTests: XCTestCase {
#if DEBUG
    // These are catastrophic-regression guards, not product latency targets. Debug
    // instrumentation and simulator scheduling make tighter budgets too volatile.
    private let maximumOpenP95: TimeInterval = 0.250
    private let maximumColdLookupP95: TimeInterval = 0.050
    private let maximumWarmLookupP95: TimeInterval = 0.010
    private let maximumParserAverage: TimeInterval = 0.020
    private let maximumMatcherMaximum: TimeInterval = 0.500
#else
    private let maximumOpenP95: TimeInterval = 0.100
    private let maximumColdLookupP95: TimeInterval = 0.025
    private let maximumWarmLookupP95: TimeInterval = 0.005
    private let maximumParserAverage: TimeInterval = 0.010
    private let maximumMatcherMaximum: TimeInterval = 0.250
#endif

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var databaseURL: URL {
        repositoryRoot.appendingPathComponent("Generated/flickzhuyin.sqlite3")
    }

    func testDatabaseOpenTime() throws {
        var durations: [TimeInterval] = []
        for _ in 0..<20 {
            durations.append(try measure { _ = try SQLiteLexiconStore(url: databaseURL) })
        }
        durations.sort()
        let p95 = percentile95(durations)
        print("PERF database open average: \(milliseconds(average(durations))) ms, p95: \(milliseconds(p95)) ms")
        XCTAssertLessThan(p95, maximumOpenP95)
    }

    func testColdCacheExactLookupLatency() throws {
        // Capacity one plus round-robin constraints guarantees that every lookup misses the cache.
        let store = try SQLiteLexiconStore(url: databaseURL, cacheCapacity: 1)
        let constraints: [[SyllableConstraint]] = [
            [SyllableConstraint(base: "ㄓㄨㄥ", tone: .first)],
            [SyllableConstraint(base: "ㄓㄨㄥ")],
            [SyllableConstraint(base: "ㄅㄚ", tone: .fourth), SyllableConstraint(base: "ㄅㄚ", tone: .neutral)],
            [SyllableConstraint(base: "ㄕ", tone: .fourth)],
            [SyllableConstraint(base: "ㄧ", tone: .first)],
        ]
        var durations: [TimeInterval] = []
        for index in 0..<200 {
            let constraint = constraints[index % constraints.count]
            durations.append(try measure { _ = try store.exactMatches(for: constraint) })
        }
        durations.sort()
        print(
            "PERF cold-cache exact lookup average: \(milliseconds(average(durations))) ms, "
                + "p50: \(milliseconds(durations[100])) ms, p95: \(milliseconds(durations[190])) ms"
        )
        XCTAssertLessThan(percentile95(durations), maximumColdLookupP95)
    }

    func testColdCacheInitialLookupLatency() throws {
        let store = try SQLiteLexiconStore(url: databaseURL, cacheCapacity: 1)
        let initials: [[Character]] = [
            ["ㄅ"], ["ㄆ"], ["ㄇ"], ["ㄈ"], ["ㄉ"], ["ㄊ"], ["ㄋ"], ["ㄌ"], ["ㄓ"], ["ㄕ"],
        ]
        var durations: [TimeInterval] = []
        for index in 0..<200 {
            let query = initials[index % initials.count]
            durations.append(try measure { _ = try store.initialMatches(for: query, limit: 64) })
        }
        durations.sort()
        print(
            "PERF cold-cache initial lookup average: \(milliseconds(average(durations))) ms, "
                + "p50: \(milliseconds(durations[100])) ms, p95: \(milliseconds(durations[190])) ms"
        )
        XCTAssertLessThan(percentile95(durations), maximumColdLookupP95)
    }

    func testInitialQueryHonorsLimit() throws {
        let store = try SQLiteLexiconStore(url: databaseURL)
        for limit in [1, 5, 64] {
            let matches = try store.initialMatches(for: ["ㄅ"], limit: limit)
            XCTAssertLessThanOrEqual(matches.count, limit)
        }
    }

    func testConsecutiveInitialPipelineLatency() throws {
        let store = try SQLiteLexiconStore(url: databaseURL)
        let parser = try SyllableParser(store: store)
        let matcher = DictionaryMatcher(store: store)
        let decoder = Decoder()
        var durations: [TimeInterval] = []
        for count in [2, 4, 8] {
            let tokens = String(repeating: "ㄅ", count: count).map { ZhuyinInputToken.symbol($0) }
            for _ in 0..<10 {
                let syllableLattice = parser.lattice(for: tokens)
                durations.append(
                    try measure {
                        let wordLattice = try matcher.buildLattice(from: syllableLattice)
                        _ = try decoder.decode(
                            syllableLattice: syllableLattice,
                            wordLattice: wordLattice
                        )
                    }
                )
            }
        }
        durations.sort()
        print(
            "PERF consecutive-initial parser+matcher+decoder average: "
                + "\(milliseconds(average(durations))) ms, max: \(milliseconds(durations.max() ?? 0)) ms"
        )
        XCTAssertLessThan(durations.max() ?? 0, maximumMatcherMaximum)
    }

    func testWarmCacheExactLookupLatency() throws {
        let store = try SQLiteLexiconStore(url: databaseURL)
        let constraint = [SyllableConstraint(base: "ㄓㄨㄥ")]
        _ = try store.exactMatches(for: constraint)
        var durations: [TimeInterval] = []
        for _ in 0..<200 {
            durations.append(try measure { _ = try store.exactMatches(for: constraint) })
        }
        durations.sort()
        let p95 = percentile95(durations)
        print("PERF warm-cache exact lookup p95: \(milliseconds(p95)) ms")
        XCTAssertLessThan(p95, maximumWarmLookupP95)
    }

    func testTenTokenParser() throws {
        let store = try SQLiteLexiconStore(url: databaseURL)
        let parser = try SyllableParser(store: store)
        let tokens = String(repeating: "ㄓㄨ", count: 5).map { ZhuyinInputToken.symbol($0) }
        var durations: [TimeInterval] = []
        for _ in 0..<100 {
            durations.append(measure { _ = parser.lattice(for: tokens) })
        }
        let mean = average(durations)
        print("PERF 10-token parser average: \(milliseconds(mean)) ms")
        XCTAssertLessThan(mean, maximumParserAverage)
    }

    func testTenTokenDictionaryMatcher() throws {
        let store = try SQLiteLexiconStore(url: databaseURL)
        let parser = try SyllableParser(store: store)
        let matcher = DictionaryMatcher(store: store)
        let syllables = ["ㄓㄨ", "ㄅㄚ", "ㄋㄧ", "ㄏㄠ", "ㄧㄣ", "ㄕ", "ㄖ", "ㄩ", "ㄨㄛ", "ㄍㄨㄛ"]
        var durations: [TimeInterval] = []
        for syllable in syllables {
            let tokens = String(repeating: syllable, count: 5).map { ZhuyinInputToken.symbol($0) }
            let lattice = parser.lattice(for: tokens)
            durations.append(try measure { _ = try matcher.buildLattice(from: lattice) })
        }
        print(
            "PERF 10-token matcher average: \(milliseconds(average(durations))) ms, "
                + "max: \(milliseconds(durations.max() ?? 0)) ms"
        )
        XCTAssertLessThan(durations.max() ?? 0, maximumMatcherMaximum)
    }

    private func measure(_ body: () throws -> Void) rethrows -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        try body()
        return ProcessInfo.processInfo.systemUptime - start
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
