import Foundation

extension UserWordKey {
    init?(text: String, pronunciation: [SyllableConstraint]) {
        guard !pronunciation.isEmpty,
              pronunciation.allSatisfy({ $0.tone != nil })
        else { return nil }
        self.init(
            text: text,
            baseKey: pronunciation.map(\.base).joined(separator: "\u{1f}"),
            toneKey: pronunciation.compactMap { $0.tone.map { String($0.digit) } }.joined()
        )
        guard isValid else { return nil }
    }

    init?(text: String, pronunciation: [CanonicalSyllable]) {
        self.init(
            text: text,
            baseKey: pronunciation.map(\.base).joined(separator: "\u{1f}"),
            toneKey: pronunciation.map { String($0.tone.digit) }.joined()
        )
        guard isValid else { return nil }
    }
}

struct CombinedLexiconStore: LexiconStore {
    let bundled: any LexiconStore
    let learned: UserLearningStore?

    func syllableInventory() throws -> [String] { try bundled.syllableInventory() }

    func exactMatches(for syllables: [SyllableConstraint]) throws -> [LexiconMatch] {
        let bundledMatches = try bundled.exactMatches(for: syllables)
        guard let learned, !syllables.isEmpty else { return bundledMatches }
        guard let records = try? learned.exactRecords(
            baseKey: syllables.map(\.base).joined(separator: "\u{1f}"),
            syllableCount: syllables.count
        ) else { return bundledMatches }
        return bundledMatches + records.compactMap(Self.match).filter { match in
            zip(syllables, match.pronunciation).allSatisfy { constraint, syllable in
                constraint.tone == nil || constraint.tone == syllable.tone
            }
        }
    }

    func patternMatches(
        for patterns: [SyllableMatchPattern],
        resultLimit: Int,
        scanLimit: Int
    ) throws -> [LexiconMatch] {
        let bundledMatches = try bundled.patternMatches(
            for: patterns, resultLimit: resultLimit, scanLimit: scanLimit
        )
        guard let learned, resultLimit > 0, scanLimit > 0,
              let initialKey = SQLiteLexiconStore.initialKey(for: patterns)
        else { return bundledMatches }
        guard let records = try? learned.patternRecords(
            initialKey: initialKey,
            syllableCount: patterns.count,
            scanLimit: scanLimit
        ) else { return bundledMatches }
        let personal = records.compactMap(Self.match).filter { match in
            zip(patterns, match.pronunciation).allSatisfy { pattern, syllable in
                pattern.accepts(base: syllable.base, tone: syllable.tone)
            }
        }
        return Array((personal + bundledMatches).prefix(resultLimit))
    }

    private static func match(_ record: UserWordRecord) -> LexiconMatch? {
        let bases = record.key.baseKey.split(separator: "\u{1f}").map(String.init)
        let tones = record.key.toneKey.compactMap(MandarinTone.init(digit:))
        guard bases.count == tones.count, !bases.isEmpty else { return nil }
        let pronunciation = zip(bases, tones).map { CanonicalSyllable(base: $0, tone: $1) }
        return LexiconMatch(
            text: record.key.text,
            pronunciation: pronunciation,
            sourceWeight: 0.01
        )
    }
}

struct UserFrequencyScorer: DecoderScorer {
    let base: any DecoderScorer
    let counts: [UserWordKey: Int]

    func cost(for word: WordEdge) throws -> Double {
        let cost = try base.cost(for: word)
        guard let key = UserWordKey(text: word.text, pronunciation: word.pronunciation),
              let count = counts[key], count >= 2
        else { return cost }
        return max(0, cost - min(2.5, 0.75 * log2(Double(count))))
    }

    func cost(forRaw edge: SyllableEdge) throws -> Double {
        try base.cost(forRaw: edge)
    }
}
