import Foundation

struct DictionaryMatcher: Sendable {
    struct Configuration: Sendable {
        static let maxWordSyllables = 8
        static let patternMatchResultLimit = 64
        static let patternMatchScanLimit = 2048
        var maxWordSyllables: Int = Configuration.maxWordSyllables
        var patternMatchResultLimit: Int = Configuration.patternMatchResultLimit
        var patternMatchScanLimit: Int = Configuration.patternMatchScanLimit
    }

    let store: any LexiconStore
    let configuration: Configuration

    init(store: any LexiconStore, configuration: Configuration = Configuration()) {
        self.store = store
        self.configuration = configuration
    }

    func buildLattice(from lattice: SyllableLattice) throws -> WordLattice {
        var outgoing = Array(repeating: [WordEdge](), count: lattice.tokenCount + 1)
        var edgeIndices = Array(repeating: [WordEdgeKey: Int](), count: lattice.tokenCount + 1)
        var memo: [[SyllableMatchPattern]: [LexiconMatch]] = [:]
        for start in 0..<lattice.tokenCount {
            var visited = Set<PatternExpansionState>()
            try expandPatterns(
                start: start,
                position: start,
                patterns: [],
                syllableEdges: [],
                lattice: lattice,
                outgoing: &outgoing,
                edgeIndices: &edgeIndices,
                visited: &visited,
                memo: &memo
            )
        }
        return WordLattice(tokenCount: lattice.tokenCount, outgoingEdges: outgoing)
    }

    private func expandPatterns(
        start: Int,
        position: Int,
        patterns: [SyllableMatchPattern],
        syllableEdges: [SyllableEdge],
        lattice: SyllableLattice,
        outgoing: inout [[WordEdge]],
        edgeIndices: inout [[WordEdgeKey: Int]],
        visited: inout Set<PatternExpansionState>,
        memo: inout [[SyllableMatchPattern]: [LexiconMatch]]
    ) throws {
        for edge in lattice.outgoingEdges[position] {
            for (pattern, matchedEdge) in Self.interpretations(
                of: edge,
                hasLongerCompleteEdge: Self.hasLongerCompleteEdge(at: position, than: edge, in: lattice)
            ) {
                let nextPatterns = patterns + [pattern]
                let nextSyllableEdges = syllableEdges + [matchedEdge]
                let end = matchedEdge.tokenRange.upperBound
                let state = PatternExpansionState(position: end, patterns: nextPatterns)
                guard visited.insert(state).inserted else { continue }
                let matches = try matches(for: nextPatterns, memo: &memo)
                for match in matches where Self.accepts(match: match, patterns: nextPatterns) {
                    Self.emit(
                        start: start,
                        end: end,
                        match: match,
                        syllableEdges: nextSyllableEdges,
                        outgoing: &outgoing,
                        edgeIndices: &edgeIndices
                    )
                }
                guard nextPatterns.count < configuration.maxWordSyllables else { continue }
                try expandPatterns(
                    start: start,
                    position: end,
                    patterns: nextPatterns,
                    syllableEdges: nextSyllableEdges,
                    lattice: lattice,
                    outgoing: &outgoing,
                    edgeIndices: &edgeIndices,
                    visited: &visited,
                    memo: &memo
                )
            }
        }
    }

    private func matches(
        for patterns: [SyllableMatchPattern],
        memo: inout [[SyllableMatchPattern]: [LexiconMatch]]
    ) throws -> [LexiconMatch] {
        if let cached = memo[patterns] {
            return cached
        }
        let matches: [LexiconMatch]
        if patterns.allSatisfy(\.isExact) {
            matches = try store.exactMatches(for: patterns.compactMap(\.exactConstraint))
        } else {
            matches = try store.patternMatches(
                for: patterns,
                resultLimit: configuration.patternMatchResultLimit,
                scanLimit: configuration.patternMatchScanLimit
            )
        }
        memo[patterns] = matches
        return matches
    }

    private static func interpretations(
        of edge: SyllableEdge,
        hasLongerCompleteEdge: Bool
    ) -> [(pattern: SyllableMatchPattern, edge: SyllableEdge)] {
        var result: [(pattern: SyllableMatchPattern, edge: SyllableEdge)] = []
        if edge.completeness == .complete {
            result.append((.exact(edge.constraint), edge))
        }
        if let abbreviation = abbreviationInterpretation(
            of: edge,
            hasLongerCompleteEdge: hasLongerCompleteEdge
        ) {
            result.append(abbreviation)
        }
        return result
    }

    private static func abbreviationInterpretation(
        of edge: SyllableEdge,
        hasLongerCompleteEdge: Bool
    ) -> (pattern: SyllableMatchPattern, edge: SyllableEdge)? {
        guard edge.completeness != .fallback,
              edge.constraint.tone == nil,
              edge.constraint.base.count == 1,
              let initial = edge.constraint.base.first
        else {
            return nil
        }
        if edge.isInitialAbbreviation {
            return (.initial(initial), edge)
        }
        // A complete one-symbol syllable (for example ㄨ) is only treated as an
        // abbreviation when no longer complete syllable starts at the same token.
        // Otherwise typing the full syllable (for example ㄨㄛ) would also expand
        // into unrelated mixed segmentations.
        guard !hasLongerCompleteEdge else { return nil }
        let abbreviated = SyllableEdge(
            tokenRange: edge.tokenRange,
            constraint: edge.constraint,
            completeness: .incomplete,
            parserCost: SyllableParser.incompleteCost
        )
        return (.initial(initial), abbreviated)
    }

    private static func hasLongerCompleteEdge(
        at position: Int,
        than edge: SyllableEdge,
        in lattice: SyllableLattice
    ) -> Bool {
        guard edge.completeness == .complete, edge.constraint.base.count == 1 else { return false }
        return lattice.outgoingEdges[position].contains {
            $0.completeness == .complete && $0.tokenRange.upperBound > edge.tokenRange.upperBound
        }
    }

    private static func accepts(match: LexiconMatch, patterns: [SyllableMatchPattern]) -> Bool {
        guard match.pronunciation.count == patterns.count else { return false }
        for (pattern, syllable) in zip(patterns, match.pronunciation) {
            guard pattern.accepts(base: syllable.base, tone: syllable.tone) else { return false }
        }
        return true
    }

    private static func emit(
        start: Int,
        end: Int,
        match: LexiconMatch,
        syllableEdges: [SyllableEdge],
        outgoing: inout [[WordEdge]],
        edgeIndices: inout [[WordEdgeKey: Int]]
    ) {
        let key = WordEdgeKey(
            tokenRange: start..<end,
            text: match.text,
            pronunciation: match.pronunciation
        )
        if let index = edgeIndices[start][key] {
            let parserCost = syllableEdges.reduce(0) { $0 + $1.parserCost }
            let existingCost = outgoing[start][index].syllableEdges.reduce(0) { $0 + $1.parserCost }
            guard parserCost < existingCost else { return }
            outgoing[start][index] = WordEdge(
                tokenRange: start..<end,
                text: match.text,
                pronunciation: match.pronunciation,
                sourceWeight: match.sourceWeight,
                syllableEdges: syllableEdges
            )
            return
        }
        edgeIndices[start][key] = outgoing[start].count
        outgoing[start].append(
            WordEdge(
                tokenRange: start..<end,
                text: match.text,
                pronunciation: match.pronunciation,
                sourceWeight: match.sourceWeight,
                syllableEdges: syllableEdges
            )
        )
    }
}

private struct WordEdgeKey: Hashable {
    let tokenRange: Range<Int>
    let text: String
    let pronunciation: [CanonicalSyllable]
}

private struct PatternExpansionState: Hashable {
    let position: Int
    let patterns: [SyllableMatchPattern]
}
