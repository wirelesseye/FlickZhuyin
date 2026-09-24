import Foundation

enum DecoderError: Error, Equatable {
    case invalidConfiguration(String)
    case invalidLattice(String)
    case disconnectedLattice(position: Int)
    case scoringFailed(String)
}

struct DecoderConfiguration: Equatable, Sendable {
    var maximumCandidates = 10
    var weightedEntryFloor = 1e-9
    var unweightedWordCost = 8.0
    var wordBoundaryCost = 0.35
    var completeRawCost = 12.0
    var incompleteRawCost = 16.0
    var fallbackRawCost = 20.0
    /// Scales the grammar cost `-query` (see `GrammarModel`). As in librime,
    /// every segment pays the no-collocation penalty unless it forms a known
    /// collocation, which keeps the search from splitting input into many
    /// short words.
    var grammarWeight = 1.0
    /// Partial sentences kept at each position when decoding with a grammar.
    var beamWidth = 5

    func validate() throws {
        guard maximumCandidates > 0 else {
            throw DecoderError.invalidConfiguration("maximumCandidates must be greater than zero")
        }
        guard weightedEntryFloor > 0, weightedEntryFloor < 1 else {
            throw DecoderError.invalidConfiguration("weightedEntryFloor must be within 0..<1")
        }
        let costs: [(String, Double)] = [
            ("unweightedWordCost", unweightedWordCost),
            ("wordBoundaryCost", wordBoundaryCost),
            ("completeRawCost", completeRawCost),
            ("incompleteRawCost", incompleteRawCost),
            ("fallbackRawCost", fallbackRawCost),
            ("grammarWeight", grammarWeight),
        ]
        for (name, value) in costs {
            guard value.isFinite, value >= 0 else {
                throw DecoderError.invalidConfiguration("\(name) must be finite and non-negative")
            }
        }
        guard beamWidth > 0 else {
            throw DecoderError.invalidConfiguration("beamWidth must be greater than zero")
        }
    }
}

struct Decoder: Sendable {
    let scorer: any DecoderScorer
    let configuration: DecoderConfiguration
    let grammar: (any GrammarModel)?

    init(
        scorer: any DecoderScorer = BaselineDecoderScorer(),
        configuration: DecoderConfiguration = DecoderConfiguration(),
        grammar: (any GrammarModel)? = nil
    ) {
        self.scorer = scorer
        self.configuration = configuration
        self.grammar = grammar
    }

    init(configuration: DecoderConfiguration, grammar: (any GrammarModel)? = nil) {
        self.init(
            scorer: BaselineDecoderScorer(configuration: configuration),
            configuration: configuration,
            grammar: grammar
        )
    }

    /// Decodes whole-input candidates. `precedingText` is committed text to the
    /// left of the input; it only matters when a grammar is present.
    func decode(
        syllableLattice: SyllableLattice,
        wordLattice: WordLattice,
        precedingText: String = ""
    ) throws -> [DecodedCandidate] {
        try configuration.validate()
        try Self.validate(syllableLattice: syllableLattice, wordLattice: wordLattice)
        let tokenCount = syllableLattice.tokenCount
        guard tokenCount > 0 else { return [] }
        let transitions = try buildTransitions(syllableLattice: syllableLattice, wordLattice: wordLattice)
        try Self.verifyConnectivity(transitions: transitions, tokenCount: tokenCount)
        if let grammar {
            let paths = try beamSearchPaths(
                transitions: transitions,
                tokenCount: tokenCount,
                grammar: grammar,
                precedingText: precedingText
            )
            return try Self.candidates(from: paths, tokenCount: tokenCount)
        }
        return try decodePaths(transitions: transitions, tokenCount: tokenCount)
    }

    /// The grammar cost of `word` after `context`, as `grammarWeight × -query`.
    func grammarCost(context: String, word: String, isRear: Bool) -> Double {
        guard let grammar else { return 0 }
        return -configuration.grammarWeight * grammar.query(context: context, word: word, isRear: isRear)
    }

    private static func validate(syllableLattice: SyllableLattice, wordLattice: WordLattice) throws {
        guard syllableLattice.tokenCount == wordLattice.tokenCount else {
            throw DecoderError.invalidLattice(
                "token counts differ: \(syllableLattice.tokenCount) and \(wordLattice.tokenCount)"
            )
        }
        let tokenCount = syllableLattice.tokenCount
        guard syllableLattice.outgoingEdges.count == tokenCount + 1 else {
            throw DecoderError.invalidLattice(
                "syllable lattice has \(syllableLattice.outgoingEdges.count) buckets for \(tokenCount) tokens"
            )
        }
        guard wordLattice.outgoingEdges.count == tokenCount + 1 else {
            throw DecoderError.invalidLattice(
                "word lattice has \(wordLattice.outgoingEdges.count) buckets for \(tokenCount) tokens"
            )
        }
        for position in 0...tokenCount {
            for edge in syllableLattice.outgoingEdges[position] {
                try validate(syllableEdge: edge, at: position, tokenCount: tokenCount)
            }
            for edge in wordLattice.outgoingEdges[position] {
                try validate(wordEdge: edge, at: position, tokenCount: tokenCount)
            }
        }
    }

    private static func validate(syllableEdge: SyllableEdge, at position: Int, tokenCount: Int) throws {
        let range = syllableEdge.tokenRange
        guard range.lowerBound == position,
              range.lowerBound >= 0,
              range.lowerBound < range.upperBound,
              range.upperBound <= tokenCount
        else {
            throw DecoderError.invalidLattice(
                "syllable edge \(range) is invalid in bucket \(position) of \(tokenCount) tokens"
            )
        }
        guard syllableEdge.parserCost.isFinite, syllableEdge.parserCost >= 0 else {
            throw DecoderError.invalidLattice("syllable edge \(range) has invalid parser cost")
        }
    }

    private static func validate(wordEdge: WordEdge, at position: Int, tokenCount: Int) throws {
        let range = wordEdge.tokenRange
        guard range.lowerBound == position,
              range.lowerBound >= 0,
              range.lowerBound < range.upperBound,
              range.upperBound <= tokenCount
        else {
            throw DecoderError.invalidLattice(
                "word edge \(range) is invalid in bucket \(position) of \(tokenCount) tokens"
            )
        }
        guard !wordEdge.syllableEdges.isEmpty else {
            throw DecoderError.invalidLattice("word edge \(range) has no syllable edges")
        }
        guard wordEdge.pronunciation.count == wordEdge.syllableEdges.count else {
            throw DecoderError.invalidLattice("word edge \(range) pronunciation count does not match its syllables")
        }
        var cursor = range.lowerBound
        for syllableEdge in wordEdge.syllableEdges {
            let syllableRange = syllableEdge.tokenRange
            guard syllableRange.lowerBound == cursor,
                  syllableRange.lowerBound < syllableRange.upperBound,
                  syllableRange.upperBound <= tokenCount
            else {
                throw DecoderError.invalidLattice("word edge \(range) has non-contiguous syllable edges")
            }
            cursor = syllableRange.upperBound
        }
        guard cursor == range.upperBound else {
            throw DecoderError.invalidLattice("word edge \(range) syllable edges do not cover the word range")
        }
    }

    private func buildTransitions(
        syllableLattice: SyllableLattice,
        wordLattice: WordLattice
    ) throws -> [[PreparedTransition]] {
        let tokenCount = syllableLattice.tokenCount
        var outgoing = Array(repeating: [PreparedTransition](), count: tokenCount + 1)
        for position in 0...tokenCount {
            for wordEdge in wordLattice.outgoingEdges[position] {
                let cost = try Self.validatedCost(try scorer.cost(for: wordEdge))
                let transition = DecoderTransition(
                    tokenRange: wordEdge.tokenRange,
                    text: wordEdge.text,
                    pronunciation: wordEdge.pronunciation.map {
                        SyllableConstraint(base: $0.base, tone: $0.tone)
                    },
                    cost: cost,
                    payload: .word(wordEdge)
                )
                outgoing[position].append(PreparedTransition(transition: transition))
            }
            for syllableEdge in syllableLattice.outgoingEdges[position] {
                let cost = try Self.validatedCost(try scorer.cost(forRaw: syllableEdge))
                let transition = DecoderTransition(
                    tokenRange: syllableEdge.tokenRange,
                    text: DecodedSegment.rawText(for: syllableEdge.constraint),
                    pronunciation: [syllableEdge.constraint],
                    cost: cost,
                    payload: .raw(syllableEdge)
                )
                outgoing[position].append(PreparedTransition(transition: transition))
            }
        }
        return outgoing
    }

    private func decodePaths(
        transitions: [[PreparedTransition]],
        tokenCount: Int
    ) throws -> [DecodedCandidate] {
        var best = Array(repeating: [DecodedPath](), count: tokenCount + 1)
        best[tokenCount] = [.empty]
        for position in stride(from: tokenCount - 1, through: 0, by: -1) {
            best[position] = Self.mergedTopPaths(
                transitions: transitions[position],
                best: best,
                limit: configuration.maximumCandidates
            )
        }
        return try Self.candidates(from: best[0], tokenCount: tokenCount)
    }

    private static func candidates(from paths: [DecodedPath], tokenCount: Int) throws -> [DecodedCandidate] {
        var candidates: [DecodedCandidate] = []
        candidates.reserveCapacity(paths.count)
        for path in paths {
            guard path.score.isFinite else {
                throw DecoderError.scoringFailed("decoded path score is not finite")
            }
            candidates.append(
                DecodedCandidate(
                    text: path.text,
                    pronunciation: path.pronunciation,
                    tokenRange: 0..<tokenCount,
                    score: path.score,
                    segments: path.segments
                )
            )
        }
        return candidates
    }

    /// Forward beam search in the style of librime's `Poet`: each word is
    /// scored against the text of the (up to) two words before it, so the DP
    /// state is a partial sentence rather than a position.
    ///
    /// Every surviving line is extended by every transition, so extensions
    /// are kept cheap: a line's strings are built only if it survives pruning.
    private func beamSearchPaths(
        transitions: [[PreparedTransition]],
        tokenCount: Int,
        grammar: any GrammarModel,
        precedingText: String
    ) throws -> [DecodedPath] {
        var lines = Array(repeating: [BeamLine](), count: tokenCount + 1)
        lines[0] = [BeamLine(context: precedingText)]
        var scorers: [String: any GrammarContextScorer] = [:]
        let window = grammar.contextWindow

        for position in 0..<tokenCount {
            let beam = Self.survivors(of: lines[position], limit: configuration.beamWidth) {
                BeamLineIdentity(text: $0.text, pronunciationKey: $0.pronunciationKey, context: $0.context)
            }
            lines[position] = []
            for line in beam {
                let context = String(String.UnicodeScalarView(line.context.unicodeScalars.suffix(window)))
                var scorer: (any GrammarContextScorer)?
                if !context.isEmpty {
                    if let cached = scorers[context] {
                        scorer = cached
                    } else {
                        let created = grammar.scorer(forContext: context)
                        scorers[context] = created
                        scorer = created
                    }
                }
                for prepared in transitions[position] {
                    let end = prepared.transition.tokenRange.upperBound
                    // Raw syllables and words without context score the
                    // no-collocation floor, so every segment pays it.
                    var score = grammar.nonCollocationPenalty
                    if let scorer, !prepared.isRaw {
                        score = scorer.score(word: prepared.transition.text, isRear: end == tokenCount)
                    }
                    let grammarCost = -configuration.grammarWeight * score
                    guard grammarCost.isFinite else {
                        throw DecoderError.scoringFailed("grammar cost \(grammarCost) is not finite")
                    }
                    lines[end].append(
                        BeamLine(prepared: prepared, predecessor: line, grammarCost: grammarCost)
                    )
                }
            }
        }

        let finished = Self.survivors(of: lines[tokenCount], limit: configuration.maximumCandidates) {
            PathKey(text: $0.text, pronunciationKey: $0.pronunciationKey)
        }
        return finished.map(\.decodedPath).sorted(by: DecodedPath.orderedBefore)
    }

    /// The best `limit` lines with distinct identities. Lines are ordered by
    /// score first, so identities (which build strings) are computed only
    /// while walking down from the best.
    private static func survivors<Identity: Hashable>(
        of lines: [BeamLine],
        limit: Int,
        identity: (BeamLine) -> Identity
    ) -> [BeamLine] {
        var seen = Set<Identity>()
        var result: [BeamLine] = []
        result.reserveCapacity(limit)
        for line in lines.sorted(by: BeamLine.orderedBefore) {
            guard result.count < limit else { break }
            if seen.insert(identity(line)).inserted {
                result.append(line)
            }
        }
        return result
    }

    private static func verifyConnectivity(transitions: [[PreparedTransition]], tokenCount: Int) throws {
        var canReachEnd = Array(repeating: false, count: tokenCount + 1)
        canReachEnd[tokenCount] = true
        for position in stride(from: tokenCount - 1, through: 0, by: -1) {
            guard transitions[position].contains(where: { canReachEnd[$0.transition.tokenRange.upperBound] }) else {
                throw DecoderError.disconnectedLattice(position: position)
            }
            canReachEnd[position] = true
        }
    }

    private static func mergedTopPaths(
        transitions: [PreparedTransition],
        best: [[DecodedPath]],
        limit: Int
    ) -> [DecodedPath] {
        var streamIndices: [Int] = []
        var streamBounds: [Double] = []
        streamIndices.reserveCapacity(transitions.count)
        streamBounds.reserveCapacity(transitions.count)
        for (index, prepared) in transitions.enumerated() {
            let suffixes = best[prepared.transition.tokenRange.upperBound]
            guard let first = suffixes.first else { continue }
            streamIndices.append(index)
            streamBounds.append(prepared.transition.cost + first.score)
        }
        guard !streamIndices.isEmpty else { return [] }
        let order = streamIndices.indices.sorted { lhs, rhs in
            if streamBounds[lhs] != streamBounds[rhs] {
                return streamBounds[lhs] < streamBounds[rhs]
            }
            return streamIndices[lhs] < streamIndices[rhs]
        }

        var heap = PathHeap()
        var nextStream = 0
        var seen = Set<PathIdentity>()
        var result: [DecodedPath] = []
        result.reserveCapacity(limit)

        func initializeStreams(upToScore threshold: Double) {
            while nextStream < order.count, streamBounds[order[nextStream]] <= threshold {
                let transitionIndex = streamIndices[order[nextStream]]
                let prepared = transitions[transitionIndex]
                let suffixes = best[prepared.transition.tokenRange.upperBound]
                heap.push(
                    MergeItem(
                        transitionIndex: transitionIndex,
                        suffixIndex: 0,
                        path: DecodedPath(prepared: prepared, suffix: suffixes[0])
                    )
                )
                nextStream += 1
            }
        }

        while result.count < limit {
            if heap.isEmpty {
                guard nextStream < order.count else { break }
                initializeStreams(upToScore: streamBounds[order[nextStream]])
                continue
            }
            initializeStreams(upToScore: heap.topScore ?? .infinity)
            guard let item = heap.pop() else { break }
            let identity = PathIdentity(text: item.path.text, pronunciation: item.path.pronunciation)
            if seen.insert(identity).inserted {
                result.append(item.path)
            }
            let prepared = transitions[item.transitionIndex]
            let suffixes = best[prepared.transition.tokenRange.upperBound]
            let nextIndex = item.suffixIndex + 1
            guard nextIndex < suffixes.count else { continue }
            heap.push(
                MergeItem(
                    transitionIndex: item.transitionIndex,
                    suffixIndex: nextIndex,
                    path: DecodedPath(prepared: prepared, suffix: suffixes[nextIndex])
                )
            )
        }
        return result
    }

    private static func validatedCost(_ cost: Double) throws -> Double {
        guard cost.isFinite, cost >= 0 else {
            throw DecoderError.scoringFailed("transition cost \(cost) must be finite and non-negative")
        }
        return cost
    }
}

private final class PreparedTransition {
    let transition: DecoderTransition
    let segment: DecodedSegment
    let isRaw: Bool
    lazy var pronunciationKey = transition.pronunciation.map(\.canonicalKey).joined(separator: "\u{1f}")
    lazy var segmentSignature = segment.canonicalSignature

    init(transition: DecoderTransition) {
        self.transition = transition
        segment = transition.segment
        isRaw = transition.isRaw
    }
}

private final class DecodedPath {
    let prepared: PreparedTransition?
    let suffix: DecodedPath?
    let score: Double
    let rawSegmentCount: Int
    let segmentCount: Int

    private var cachedText: String?
    private var cachedPronunciation: [SyllableConstraint]?
    private var cachedPronunciationKey: String?
    private var cachedSegmentSignature: String?

    static let empty = DecodedPath()

    init(prepared: PreparedTransition, suffix: DecodedPath, adjustment: Double = 0) {
        self.prepared = prepared
        self.suffix = suffix
        score = prepared.transition.cost + adjustment + suffix.score
        rawSegmentCount = (prepared.isRaw ? 1 : 0) + suffix.rawSegmentCount
        segmentCount = 1 + suffix.segmentCount
    }

    private init() {
        prepared = nil
        suffix = nil
        score = 0
        rawSegmentCount = 0
        segmentCount = 0
    }

    var text: String {
        if let cachedText {
            return cachedText
        }
        let computed = (prepared?.transition.text ?? "") + (suffix?.text ?? "")
        cachedText = computed
        return computed
    }

    var pronunciation: [SyllableConstraint] {
        if let cachedPronunciation {
            return cachedPronunciation
        }
        let computed = (prepared?.transition.pronunciation ?? []) + (suffix?.pronunciation ?? [])
        cachedPronunciation = computed
        return computed
    }

    var segments: [DecodedSegment] {
        var result: [DecodedSegment] = []
        result.reserveCapacity(segmentCount)
        var node: DecodedPath? = self
        while let current = node, let prepared = current.prepared {
            result.append(prepared.segment)
            node = current.suffix
        }
        return result
    }

    private var pronunciationKey: String {
        if let cachedPronunciationKey {
            return cachedPronunciationKey
        }
        let computed = (prepared?.pronunciationKey ?? "") + Self.joinedKey(
            leading: prepared?.pronunciationKey.isEmpty ?? true,
            trailing: suffix?.pronunciationKey ?? ""
        )
        cachedPronunciationKey = computed
        return computed
    }

    private var segmentSignature: String {
        if let cachedSegmentSignature {
            return cachedSegmentSignature
        }
        let computed = (prepared?.segmentSignature ?? "") + Self.joinedKey(
            leading: prepared?.segmentSignature.isEmpty ?? true,
            trailing: suffix?.segmentSignature ?? ""
        )
        cachedSegmentSignature = computed
        return computed
    }

    static func orderedBefore(_ lhs: DecodedPath, _ rhs: DecodedPath) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score < rhs.score
        }
        if lhs.rawSegmentCount != rhs.rawSegmentCount {
            return lhs.rawSegmentCount < rhs.rawSegmentCount
        }
        if lhs.segmentCount != rhs.segmentCount {
            return lhs.segmentCount < rhs.segmentCount
        }
        if lhs.text != rhs.text {
            return lhs.text < rhs.text
        }
        if lhs.pronunciationKey != rhs.pronunciationKey {
            return lhs.pronunciationKey < rhs.pronunciationKey
        }
        return lhs.segmentSignature < rhs.segmentSignature
    }

    private static func joinedKey(leading: Bool, trailing: String) -> String {
        if leading || trailing.isEmpty {
            return trailing
        }
        return "\u{1f}" + trailing
    }
}

/// A partial sentence in the beam search, linked to the line it extends.
/// Only the numeric fields are set eagerly; strings are built on demand.
private final class BeamLine {
    let prepared: PreparedTransition?
    let predecessor: BeamLine?
    let grammarCost: Double
    let score: Double
    let rawSegmentCount: Int
    let segmentCount: Int
    private let rootContext: String

    init(context: String) {
        prepared = nil
        predecessor = nil
        grammarCost = 0
        score = 0
        rawSegmentCount = 0
        segmentCount = 0
        rootContext = context
    }

    init(prepared: PreparedTransition, predecessor: BeamLine, grammarCost: Double) {
        self.prepared = prepared
        self.predecessor = predecessor
        self.grammarCost = grammarCost
        score = predecessor.score + prepared.transition.cost + grammarCost
        rawSegmentCount = predecessor.rawSegmentCount + (prepared.isRaw ? 1 : 0)
        segmentCount = predecessor.segmentCount + 1
        rootContext = ""
    }

    lazy var text: String = (predecessor?.text ?? "") + (prepared?.transition.text ?? "")

    lazy var pronunciationKey: String = {
        guard let prepared else { return "" }
        let previous = predecessor?.pronunciationKey ?? ""
        return previous.isEmpty ? prepared.pronunciationKey : previous + "\u{1f}" + prepared.pronunciationKey
    }()

    /// Grammar context for the next word: the last two words, or the text
    /// before the input while fewer than two words are decoded. Empty after a
    /// raw syllable, which has no text to condition on.
    lazy var context: String = {
        guard let prepared, let predecessor else { return rootContext }
        if prepared.isRaw {
            return ""
        }
        if let previousWord = predecessor.prepared {
            return (previousWord.isRaw ? "" : previousWord.transition.text) + prepared.transition.text
        }
        return predecessor.context + prepared.transition.text
    }()

    var decodedPath: DecodedPath {
        var path = DecodedPath.empty
        var node: BeamLine? = self
        while let current = node, let prepared = current.prepared {
            path = DecodedPath(prepared: prepared, suffix: path, adjustment: current.grammarCost)
            node = current.predecessor
        }
        return path
    }

    static func orderedBefore(_ lhs: BeamLine, _ rhs: BeamLine) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score < rhs.score
        }
        if lhs.rawSegmentCount != rhs.rawSegmentCount {
            return lhs.rawSegmentCount < rhs.rawSegmentCount
        }
        if lhs.segmentCount != rhs.segmentCount {
            return lhs.segmentCount < rhs.segmentCount
        }
        if lhs.text != rhs.text {
            return lhs.text < rhs.text
        }
        if lhs.pronunciationKey != rhs.pronunciationKey {
            return lhs.pronunciationKey < rhs.pronunciationKey
        }
        return lhs.context < rhs.context
    }
}

/// Lines with the same text, reading and grammar context score every
/// continuation identically, so only the best of them needs to stay in the beam.
private struct BeamLineIdentity: Hashable {
    let text: String
    let pronunciationKey: String
    let context: String
}

private struct PathKey: Hashable {
    let text: String
    let pronunciationKey: String
}

private struct PathIdentity: Hashable {
    let text: String
    let pronunciation: [SyllableConstraint]
}

private struct MergeItem {
    let transitionIndex: Int
    let suffixIndex: Int
    let path: DecodedPath
}

private struct PathHeap {
    private var items: [MergeItem] = []

    var isEmpty: Bool {
        items.isEmpty
    }

    var topScore: Double? {
        items.first?.path.score
    }

    mutating func push(_ item: MergeItem) {
        items.append(item)
        siftUp(from: items.count - 1)
    }

    mutating func pop() -> MergeItem? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let last = items.removeLast()
        if !items.isEmpty {
            siftDown(from: 0)
        }
        return last
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.orderedBefore(items[child], items[parent]) else { return }
            items.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var candidate = parent
            if left < items.count, Self.orderedBefore(items[left], items[candidate]) {
                candidate = left
            }
            if right < items.count, Self.orderedBefore(items[right], items[candidate]) {
                candidate = right
            }
            guard candidate != parent else { return }
            items.swapAt(parent, candidate)
            parent = candidate
        }
    }

    private static func orderedBefore(_ lhs: MergeItem, _ rhs: MergeItem) -> Bool {
        if DecodedPath.orderedBefore(lhs.path, rhs.path) {
            return true
        }
        if DecodedPath.orderedBefore(rhs.path, lhs.path) {
            return false
        }
        if lhs.transitionIndex != rhs.transitionIndex {
            return lhs.transitionIndex < rhs.transitionIndex
        }
        return lhs.suffixIndex < rhs.suffixIndex
    }
}

private extension SyllableConstraint {
    var canonicalKey: String {
        base + (tone.map { String($0.rawValue) } ?? "*")
    }
}

private extension DecodedSegment {
    var canonicalSignature: String {
        switch self {
        case let .word(edge):
            "w|\(edge.tokenRange.lowerBound)|\(edge.tokenRange.upperBound)|\(edge.text)|"
                + edge.pronunciation.map { "\($0.base)\($0.tone.rawValue)" }.joined(separator: "\u{1f}")
        case let .raw(edge):
            "r|\(edge.tokenRange.lowerBound)|\(edge.tokenRange.upperBound)|\(edge.constraint.base)|"
                + (edge.constraint.tone.map { String($0.rawValue) } ?? "*")
        }
    }
}
