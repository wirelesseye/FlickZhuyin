import Foundation

struct DictionaryMatcher: Sendable {
    struct Configuration: Sendable {
        static let maxWordSyllables = 8
        static let initialMatchLimit = 64
        var maxWordSyllables: Int = Configuration.maxWordSyllables
        var initialMatchLimit: Int = Configuration.initialMatchLimit
    }

    let store: any LexiconStore
    let configuration: Configuration

    init(store: any LexiconStore, configuration: Configuration = Configuration()) {
        self.store = store
        self.configuration = configuration
    }

    func buildLattice(from lattice: SyllableLattice) throws -> WordLattice {
        var outgoing = Array(repeating: [WordEdge](), count: lattice.tokenCount + 1)
        var seenEdges = Array(repeating: Set<WordEdgeKey>(), count: lattice.tokenCount + 1)
        var exactMemo: [[SyllableConstraint]: [LexiconMatch]] = [:]
        var initialMemo: [[Character]: [LexiconMatch]] = [:]
        for start in 0..<lattice.tokenCount {
            var exactVisited = Set<ExpansionState>()
            try expand(
                start: start,
                position: start,
                constraints: [],
                syllableEdges: [],
                lattice: lattice,
                outgoing: &outgoing,
                seenEdges: &seenEdges,
                visited: &exactVisited,
                memo: &exactMemo
            )
            var initialVisited = Set<InitialExpansionState>()
            try expandInitial(
                start: start,
                position: start,
                initials: [],
                syllableEdges: [],
                lattice: lattice,
                outgoing: &outgoing,
                seenEdges: &seenEdges,
                visited: &initialVisited,
                memo: &initialMemo
            )
        }
        return WordLattice(tokenCount: lattice.tokenCount, outgoingEdges: outgoing)
    }

    private func expand(
        start: Int,
        position: Int,
        constraints: [SyllableConstraint],
        syllableEdges: [SyllableEdge],
        lattice: SyllableLattice,
        outgoing: inout [[WordEdge]],
        seenEdges: inout [Set<WordEdgeKey>],
        visited: inout Set<ExpansionState>,
        memo: inout [[SyllableConstraint]: [LexiconMatch]]
    ) throws {
        for edge in lattice.outgoingEdges[position] where edge.completeness == .complete {
            let nextConstraints = constraints + [edge.constraint]
            let nextSyllableEdges = syllableEdges + [edge]
            let end = edge.tokenRange.upperBound
            let state = ExpansionState(position: end, constraints: nextConstraints)
            guard visited.insert(state).inserted else { continue }
            let matches: [LexiconMatch]
            if let cached = memo[nextConstraints] {
                matches = cached
            } else {
                matches = try store.exactMatches(for: nextConstraints)
                memo[nextConstraints] = matches
            }
            for match in matches {
                let key = WordEdgeKey(
                    tokenRange: start..<end,
                    text: match.text,
                    pronunciation: match.pronunciation
                )
                guard seenEdges[start].insert(key).inserted else { continue }
                outgoing[start].append(
                    WordEdge(
                        tokenRange: start..<end,
                        text: match.text,
                        pronunciation: match.pronunciation,
                        sourceWeight: match.sourceWeight,
                        syllableEdges: nextSyllableEdges
                    )
                )
            }
            guard nextConstraints.count < configuration.maxWordSyllables else { continue }
            try expand(
                start: start,
                position: end,
                constraints: nextConstraints,
                syllableEdges: nextSyllableEdges,
                lattice: lattice,
                outgoing: &outgoing,
                seenEdges: &seenEdges,
                visited: &visited,
                memo: &memo
            )
        }
    }

    private func expandInitial(
        start: Int,
        position: Int,
        initials: [Character],
        syllableEdges: [SyllableEdge],
        lattice: SyllableLattice,
        outgoing: inout [[WordEdge]],
        seenEdges: inout [Set<WordEdgeKey>],
        visited: inout Set<InitialExpansionState>,
        memo: inout [[Character]: [LexiconMatch]]
    ) throws {
        for edge in lattice.outgoingEdges[position] where edge.isInitialAbbreviation {
            guard let initial = edge.constraint.base.first else { continue }
            let nextInitials = initials + [initial]
            let nextSyllableEdges = syllableEdges + [edge]
            let end = edge.tokenRange.upperBound
            let state = InitialExpansionState(position: end, initials: nextInitials)
            guard visited.insert(state).inserted else { continue }
            let matches: [LexiconMatch]
            if let cached = memo[nextInitials] {
                matches = cached
            } else {
                matches = try store.initialMatches(
                    for: nextInitials,
                    limit: configuration.initialMatchLimit
                )
                memo[nextInitials] = matches
            }
            for match in matches where match.pronunciation.count == nextInitials.count {
                let key = WordEdgeKey(
                    tokenRange: start..<end,
                    text: match.text,
                    pronunciation: match.pronunciation
                )
                guard seenEdges[start].insert(key).inserted else { continue }
                outgoing[start].append(
                    WordEdge(
                        tokenRange: start..<end,
                        text: match.text,
                        pronunciation: match.pronunciation,
                        sourceWeight: match.sourceWeight,
                        syllableEdges: nextSyllableEdges
                    )
                )
            }
            guard nextInitials.count < configuration.maxWordSyllables else { continue }
            try expandInitial(
                start: start,
                position: end,
                initials: nextInitials,
                syllableEdges: nextSyllableEdges,
                lattice: lattice,
                outgoing: &outgoing,
                seenEdges: &seenEdges,
                visited: &visited,
                memo: &memo
            )
        }
    }
}

private struct WordEdgeKey: Hashable {
    let tokenRange: Range<Int>
    let text: String
    let pronunciation: [CanonicalSyllable]
}

private struct ExpansionState: Hashable {
    let position: Int
    let constraints: [SyllableConstraint]
}

private struct InitialExpansionState: Hashable {
    let position: Int
    let initials: [Character]
}
