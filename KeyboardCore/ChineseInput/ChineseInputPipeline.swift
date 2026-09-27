import Foundation
import os

protocol ChineseInputPipeline: Sendable {
    /// `precedingText` is committed text immediately left of the input, used
    /// as grammar context. It is never stored.
    func candidates(for tokens: [ZhuyinInputToken], precedingText: String) async throws -> [InputCandidate]
    func suggestions(after precedingText: String) async throws -> [String]
    func recordCommittedSelection(chunks: [SelectedChunk], fullySelected: Bool) async throws
}

extension ChineseInputPipeline {
    func candidates(for tokens: [ZhuyinInputToken]) async throws -> [InputCandidate] {
        try await candidates(for: tokens, precedingText: "")
    }

    func suggestions(after precedingText: String) async throws -> [String] { [] }

    func recordCommittedSelection(chunks: [SelectedChunk], fullySelected: Bool) async throws {}
}

final class LexiconChineseInputPipeline: ChineseInputPipeline, @unchecked Sendable {
    private let parser: SyllableParser
    private let matcher: DictionaryMatcher
    private let decoder: Decoder
    private let store: any LexiconStore
    private let bundledStore: any LexiconStore
    private let userLearningStore: UserLearningStore?
    private let queue = DispatchQueue(
        label: "com.wirelesseye.FlickZhuyin.ChineseInputPipeline",
        qos: .userInitiated
    )

    convenience init(
        bundle: Bundle,
        resourceName: String = "flickzhuyin",
        resourceExtension: String = "sqlite3",
        grammarResourceExtension: String? = "gram",
        decoder: Decoder = Decoder(),
        userLearningStore: UserLearningStore? = nil
    ) throws {
        let store = try SQLiteLexiconStore(
            bundle: bundle,
            resourceName: resourceName,
            resourceExtension: resourceExtension
        )
        var decoder = decoder
        if decoder.grammar == nil, let grammarResourceExtension {
            do {
                let grammarStore = try MappedGramStore(
                    bundle: bundle,
                    resourceName: resourceName,
                    resourceExtension: grammarResourceExtension
                )
                decoder = Decoder(
                    scorer: decoder.scorer,
                    configuration: decoder.configuration,
                    grammar: OctagramGrammar(store: grammarStore)
                )
            } catch {
                // Ranking without a grammar is still usable; keep typing working.
                Logger(subsystem: "com.wirelesseye.FlickZhuyin", category: "ChineseInput")
                    .error("grammar unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        try self.init(store: store, decoder: decoder, userLearningStore: userLearningStore)
    }

    init(
        store: any LexiconStore,
        decoder: Decoder = Decoder(),
        userLearningStore: UserLearningStore? = nil
    ) throws {
        bundledStore = store
        self.userLearningStore = userLearningStore
        let combined = CombinedLexiconStore(bundled: store, learned: userLearningStore)
        self.store = combined
        parser = try SyllableParser(store: combined)
        matcher = DictionaryMatcher(store: combined)
        self.decoder = decoder
    }

    func recordCommittedSelection(chunks: [SelectedChunk], fullySelected: Bool) async throws {
        guard let userLearningStore, !chunks.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let entries = try self.learningEntries(chunks: chunks, fullySelected: fullySelected)
                    try userLearningStore.record(entries)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func learningEntries(
        chunks: [SelectedChunk],
        fullySelected: Bool
    ) throws -> [(key: UserWordKey, isLearned: Bool)] {
        var entries: [(key: UserWordKey, isLearned: Bool)] = chunks.compactMap { chunk in
            UserWordKey(text: chunk.text, pronunciation: chunk.pronunciation).map { ($0, false) }
        }
        guard fullySelected else { return entries }
        let text = chunks.map(\.text).joined()
        let pronunciation = chunks.flatMap(\.pronunciation)
        guard let key = UserWordKey(text: text, pronunciation: pronunciation),
              (2...8).contains(key.syllableCount)
        else { return entries }
        guard let bundled = try? bundledStore.exactMatches(for: pronunciation) else {
            return entries
        }
        let exists = bundled.contains { match in
            match.text == text && match.pronunciation.map { String($0.tone.digit) }.joined() == key.toneKey
        }
        guard !exists else { return entries }
        if entries.count == 1 && entries[0].key == key {
            entries[0].isLearned = true
        } else {
            entries.append((key, true))
        }
        return entries
    }

    func candidates(for tokens: [ZhuyinInputToken], precedingText: String) async throws -> [InputCandidate] {
        guard !tokens.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(
                        returning: try self.makeCandidates(for: tokens, precedingText: precedingText)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func suggestions(after precedingText: String) async throws -> [String] {
        guard let grammar = decoder.grammar as? OctagramGrammar else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: grammar.suggestions(after: precedingText))
            }
        }
    }

    private func makeCandidates(
        for tokens: [ZhuyinInputToken],
        precedingText: String
    ) throws -> [InputCandidate] {
        let counts = (try? userLearningStore?.countSnapshot()) ?? [:]
        let decoder = Decoder(
            scorer: UserFrequencyScorer(base: self.decoder.scorer, counts: counts),
            configuration: self.decoder.configuration,
            grammar: self.decoder.grammar
        )
        let syllableLattice = parser.lattice(for: tokens)
        let wordLattice = try matcher.buildLattice(from: syllableLattice)
        let decoded = try decoder.decode(
            syllableLattice: syllableLattice,
            wordLattice: wordLattice,
            precedingText: precedingText
        )
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
        let exactCharacters = try exactSingleCharacterCandidates(
            lattice: syllableLattice,
            precedingText: precedingText,
            excludingTexts: Set(result.map(\.text)),
            decoder: decoder
        )
        let promoted = exactCharacters.filter { candidate in
            guard let key = UserWordKey(text: candidate.text, pronunciation: candidate.pronunciation) else {
                return false
            }
            return (counts[key] ?? 0) >= 2
        }
        if promoted.isEmpty {
            result.append(contentsOf: exactCharacters)
            return result
        }
        let ranked = (result.filter { !$0.isRawFallback } + promoted).sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.text < rhs.text : lhs.score < rhs.score
        }
        let promotedTexts = Set(promoted.map(\.text))
        result = ranked + result.filter(\.isRawFallback)
        result.append(contentsOf: exactCharacters.filter { !promotedTexts.contains($0.text) })
        return result
    }

    private func exactSingleCharacterCandidates(
        lattice: SyllableLattice,
        precedingText: String,
        excludingTexts excluded: Set<String>,
        decoder: Decoder
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
                ) + decoder.grammarCost(context: precedingText, word: match.text, isRear: true)
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
