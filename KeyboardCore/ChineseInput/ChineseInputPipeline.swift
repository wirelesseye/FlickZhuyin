import Foundation

protocol ChineseInputPipeline: Sendable {
    func candidates(for tokens: [ZhuyinInputToken]) async throws -> [InputCandidate]
}

final class LexiconChineseInputPipeline: ChineseInputPipeline, @unchecked Sendable {
    private let parser: SyllableParser
    private let matcher: DictionaryMatcher
    private let decoder: Decoder
    private let store: any LexiconStore
    private let queue = DispatchQueue(
        label: "com.wirelesseye.FlickZhuyin.ChineseInputPipeline",
        qos: .userInitiated
    )

    convenience init(
        bundle: Bundle,
        resourceName: String = "flickzhuyin",
        resourceExtension: String = "sqlite3",
        decoder: Decoder = Decoder()
    ) throws {
        let store = try SQLiteLexiconStore(
            bundle: bundle,
            resourceName: resourceName,
            resourceExtension: resourceExtension
        )
        try self.init(store: store, decoder: decoder)
    }

    init(store: any LexiconStore, decoder: Decoder = Decoder()) throws {
        self.store = store
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
        let candidates = Self.mergedByText(decoded.map(InputCandidate.init(decoded:)))
        var result: [InputCandidate]
        if candidates.contains(where: \.isRawFallback) {
            result = candidates
        } else {
            let limit = decoder.configuration.maximumCandidates
            result = Array(candidates.prefix(max(0, limit - 1)))
            if let fallback = rawFallback(for: tokens, lattice: syllableLattice) {
                result.append(fallback)
            }
        }
        result.append(contentsOf: try exactSingleCharacterCandidates(
            lattice: syllableLattice,
            excludingTexts: Set(result.map(\.text))
        ))
        return result
    }

    private func exactSingleCharacterCandidates(
        lattice: SyllableLattice,
        excludingTexts excluded: Set<String>
    ) throws -> [InputCandidate] {
        let tokenCount = lattice.tokenCount
        guard tokenCount > 0 else { return [] }
        let tokenRange = 0..<tokenCount
        var bestByText: [String: (score: Double, constraint: SyllableConstraint)] = [:]
        for edge in lattice.outgoingEdges[0]
        where edge.tokenRange == tokenRange && edge.completeness == .complete {
            for match in try store.exactMatches(for: [edge.constraint]) {
                guard match.text.count == 1,
                      match.pronunciation.count == 1,
                      let syllable = match.pronunciation.first,
                      !excluded.contains(match.text)
                else { continue }
                let score = try decoder.scorer.cost(
                    for: WordEdge(
                        tokenRange: tokenRange,
                        text: match.text,
                        pronunciation: match.pronunciation,
                        sourceWeight: match.sourceWeight,
                        pronunciationWeight: match.pronunciationWeight,
                        syllableEdges: [edge]
                    )
                )
                if let existing = bestByText[match.text], existing.score <= score {
                    continue
                }
                bestByText[match.text] = (
                    score,
                    SyllableConstraint(base: syllable.base, tone: syllable.tone)
                )
            }
        }
        return bestByText
            .map { text, entry in
                InputCandidate(
                    id: CandidateID(
                        text: text,
                        pronunciation: [entry.constraint],
                        tokenRange: tokenRange
                    ),
                    text: text,
                    pronunciation: [entry.constraint],
                    score: entry.score,
                    isRawFallback: false
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                return lhs.text < rhs.text
            }
    }

    private static func mergedByText(_ candidates: [InputCandidate]) -> [InputCandidate] {
        var bestIndexByText: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() where !candidate.isRawFallback {
            guard let bestIndex = bestIndexByText[candidate.text] else {
                bestIndexByText[candidate.text] = index
                continue
            }
            if candidate.score < candidates[bestIndex].score {
                bestIndexByText[candidate.text] = index
            }
        }
        return candidates.enumerated().compactMap { index, candidate in
            guard candidate.isRawFallback || bestIndexByText[candidate.text] == index else {
                return nil
            }
            return candidate
        }
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
