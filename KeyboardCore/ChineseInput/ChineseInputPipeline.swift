import Foundation

protocol ChineseInputPipeline: Sendable {
    func candidates(for tokens: [ZhuyinInputToken]) async throws -> [InputCandidate]
}

final class LexiconChineseInputPipeline: ChineseInputPipeline, @unchecked Sendable {
    private let parser: SyllableParser
    private let matcher: DictionaryMatcher
    private let decoder: Decoder
    private let queue = DispatchQueue(
        label: "com.wirelesseye.FlickZhuyin.ChineseInputPipeline",
        qos: .userInitiated
    )

    convenience init(
        bundle: Bundle,
        resourceName: String = "flickzhuyin",
        resourceExtension: String = "sqlite3"
    ) throws {
        let store = try SQLiteLexiconStore(
            bundle: bundle,
            resourceName: resourceName,
            resourceExtension: resourceExtension
        )
        try self.init(store: store)
    }

    init(store: any LexiconStore, decoder: Decoder = Decoder()) throws {
        parser = try SyllableParser(store: store)
        matcher = DictionaryMatcher(store: store)
        self.decoder = decoder
    }

    func candidates(for tokens: [ZhuyinInputToken]) async throws -> [InputCandidate] {
        guard !tokens.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.makeCandidates(for: tokens))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func makeCandidates(for tokens: [ZhuyinInputToken]) throws -> [InputCandidate] {
        let syllableLattice = parser.lattice(for: tokens)
        let wordLattice = try matcher.buildLattice(from: syllableLattice)
        let decoded = try decoder.decode(syllableLattice: syllableLattice, wordLattice: wordLattice)
        var candidates = decoded.map(InputCandidate.init(decoded:))
        guard !candidates.contains(where: \.isRawFallback) else {
            return candidates
        }
        let limit = decoder.configuration.maximumCandidates
        candidates = Array(candidates.prefix(max(0, limit - 1)))
        if let fallback = rawFallback(for: tokens, lattice: syllableLattice) {
            candidates.append(fallback)
        }
        return candidates
    }

    private func rawFallback(
        for tokens: [ZhuyinInputToken],
        lattice: SyllableLattice
    ) -> InputCandidate? {
        let path = coveragePath(for: lattice)
        guard !path.isEmpty else { return nil }
        let configuration = decoder.configuration
        let score = path.reduce(0.0) { total, edge in
            let penalty: Double
            switch edge.completeness {
            case .complete: penalty = configuration.completeRawCost
            case .incomplete: penalty = configuration.incompleteRawCost
            case .fallback: penalty = configuration.fallbackRawCost
            }
            return total + edge.parserCost + penalty
        }
        return InputCandidate.rawFallback(
            tokens: tokens,
            pronunciation: path.map(\.constraint),
            score: score
        )
    }

    private func coveragePath(for lattice: SyllableLattice) -> [SyllableEdge] {
        let tokenCount = lattice.tokenCount
        var canReachEnd = Array(repeating: false, count: tokenCount + 1)
        canReachEnd[tokenCount] = true
        for position in stride(from: tokenCount - 1, through: 0, by: -1) {
            canReachEnd[position] = lattice.outgoingEdges[position].contains {
                canReachEnd[$0.tokenRange.upperBound]
            }
        }
        var path: [SyllableEdge] = []
        var position = 0
        while position < tokenCount {
            guard let edge = lattice.outgoingEdges[position]
                .filter({ canReachEnd[$0.tokenRange.upperBound] })
                .sorted(by: Self.pathPreference)
                .first
            else {
                return []
            }
            path.append(edge)
            position = edge.tokenRange.upperBound
        }
        return path
    }

    private static func pathPreference(_ lhs: SyllableEdge, _ rhs: SyllableEdge) -> Bool {
        if completenessRank(lhs.completeness) != completenessRank(rhs.completeness) {
            return completenessRank(lhs.completeness) < completenessRank(rhs.completeness)
        }
        if lhs.tokenRange.upperBound != rhs.tokenRange.upperBound {
            return lhs.tokenRange.upperBound > rhs.tokenRange.upperBound
        }
        if lhs.parserCost != rhs.parserCost {
            return lhs.parserCost < rhs.parserCost
        }
        return lhs.tokenRange.lowerBound < rhs.tokenRange.lowerBound
    }

    private static func completenessRank(_ completeness: SyllableCompleteness) -> Int {
        switch completeness {
        case .complete: 0
        case .incomplete: 1
        case .fallback: 2
        }
    }
}
