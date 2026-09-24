import Foundation

/// Scores how well a word follows some context, on librime's grammar scale:
/// higher is better, and a score is never below `nonCollocationPenalty`.
protocol GrammarModel: Sendable {
    var nonCollocationPenalty: Double { get }
    /// Characters of context the model reads; longer contexts can be trimmed
    /// to their last `contextWindow` characters without changing any score.
    var contextWindow: Int { get }
    /// A scorer for many words after one context. It may cache lookups, so
    /// use it on one thread and only for the duration of one decode.
    func scorer(forContext context: String) -> any GrammarContextScorer
}

protocol GrammarContextScorer: AnyObject {
    func score(word: String, isRear: Bool) -> Double
}

extension GrammarModel {
    func query(context: String, word: String, isRear: Bool) -> Double {
        scorer(forContext: context).score(word: word, isRear: isRear)
    }
}

struct OctagramConfiguration: Equatable, Sendable {
    var collocationMaxLength = 4
    var collocationMinLength = 3
    var collocationPenalty = -12.0
    var nonCollocationPenalty = -12.0
    var weakCollocationPenalty = -24.0
    var rearPenalty = -18.0
}

/// Port of librime-octagram's `Octagram::Query` over an FZGram store.
struct OctagramGrammar: GrammarModel {
    static let maxEncodedUnicode = 8
    static let valueScale = 10_000.0
    static let sentenceEnd = Array("$".utf8)

    let store: MappedGramStore
    let configuration: OctagramConfiguration

    init(store: MappedGramStore, configuration: OctagramConfiguration = OctagramConfiguration()) {
        self.store = store
        self.configuration = configuration
    }

    var nonCollocationPenalty: Double {
        configuration.nonCollocationPenalty
    }

    var contextWindow: Int {
        max(0, min(Self.maxEncodedUnicode, configuration.collocationMaxLength - 1))
    }

    func scorer(forContext context: String) -> any GrammarContextScorer {
        OctagramContextScorer(grammar: self, context: context)
    }

    fileprivate static func scaled(_ value: Int) -> Double {
        Double(value) / valueScale
    }
}

/// Scores words after one context. Octagram looks up `C[i...] + W[..<m]` for
/// every context suffix and word prefix; words in a candidate lattice share
/// few distinct first characters, so the first, usually failing, lookup of
/// each suffix is cached by that character.
private final class OctagramContextScorer: GrammarContextScorer {
    private struct Suffix {
        let bytes: [UInt8]
        let length: Int
        let isWholeContext: Bool
    }

    private let grammar: OctagramGrammar
    private let limit: Int
    /// Octagram scores nothing, not even a sentence end, without context.
    private let hasContext: Bool
    /// Context suffixes that begin at least one key, longest first.
    private let suffixes: [Suffix]
    private var firstCharacterLookups: [Unicode.Scalar: [MappedGramStore.LookupResult]] = [:]

    init(grammar: OctagramGrammar, context: String) {
        self.grammar = grammar
        limit = grammar.contextWindow
        hasContext = !context.isEmpty
        var suffixes: [Suffix] = []
        if limit > 0 {
            let tail = Array(context.unicodeScalars.suffix(limit))
            for start in tail.indices {
                let bytes = Self.utf8(tail[start...])
                if grammar.store.lookup(bytes).hasExtensions {
                    suffixes.append(Suffix(bytes: bytes, length: tail.count - start, isWholeContext: start == 0))
                }
            }
        }
        self.suffixes = suffixes
    }

    func score(word: String, isRear: Bool) -> Double {
        let configuration = grammar.configuration
        var result = configuration.nonCollocationPenalty
        let scalars = word.unicodeScalars
        guard hasContext, limit > 0, let first = scalars.first else { return result }
        let isSingleScalar = scalars.index(after: scalars.startIndex) == scalars.endIndex

        // Most words fail here, on a cached lookup, without allocating.
        let firstLookups = lookups(startingWith: first)
        var prefixes: [[UInt8]]?
        for (index, suffix) in suffixes.enumerated() {
            var lookup = firstLookups[index]
            var matchLength = 1
            while true {
                if let value = lookup.value {
                    let coversWord = matchLength == limit || (matchLength == 1 && isSingleScalar)
                        || (prefixes.map { matchLength == $0.count } ?? false)
                    let isCollocation = suffix.length + matchLength >= configuration.collocationMinLength
                        || (suffix.isWholeContext && coversWord)
                    let penalty = isCollocation
                        ? configuration.collocationPenalty
                        : configuration.weakCollocationPenalty
                    result = max(result, OctagramGrammar.scaled(value) + penalty)
                }
                guard lookup.hasExtensions, !isSingleScalar, matchLength < limit else { break }
                if prefixes == nil { prefixes = Self.utf8Prefixes(of: scalars.prefix(limit)) }
                guard matchLength < prefixes!.count else { break }
                matchLength += 1
                lookup = grammar.store.lookup(suffix.bytes + prefixes![matchLength - 1])
            }
        }

        if isRear, scalars.count <= limit {
            if prefixes == nil { prefixes = Self.utf8Prefixes(of: scalars.prefix(limit)) }
            if let value = grammar.store.lookup(prefixes!.last! + OctagramGrammar.sentenceEnd).value {
                result = max(result, OctagramGrammar.scaled(value) + configuration.rearPenalty)
            }
        }
        return result
    }

    private func lookups(startingWith first: Unicode.Scalar) -> [MappedGramStore.LookupResult] {
        if let cached = firstCharacterLookups[first] {
            return cached
        }
        let bytes = Self.utf8([first])
        let lookups = suffixes.map { grammar.store.lookup($0.bytes + bytes) }
        firstCharacterLookups[first] = lookups
        return lookups
    }

    private static func utf8<S: Sequence>(_ scalars: S) -> [UInt8] where S.Element == Unicode.Scalar {
        var bytes: [UInt8] = []
        for scalar in scalars {
            bytes.append(contentsOf: UTF8.encode(scalar)!)
        }
        return bytes
    }

    private static func utf8Prefixes<S: Sequence>(of scalars: S) -> [[UInt8]] where S.Element == Unicode.Scalar {
        var prefixes: [[UInt8]] = []
        var bytes: [UInt8] = []
        for scalar in scalars {
            bytes.append(contentsOf: UTF8.encode(scalar)!)
            prefixes.append(bytes)
        }
        return prefixes
    }
}

enum GrammarContext {
    /// Characters of committed text kept as grammar context; octagram reads at most 8.
    static let maximumLength = 8

    /// The trailing run of letters in `text`, cut at whitespace, punctuation or
    /// symbols so context never crosses a sentence or field boundary.
    static func tail(of text: String?) -> String {
        guard let text else { return "" }
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars.reversed() {
            guard scalars.count < maximumLength, scalar.properties.isAlphabetic else { break }
            scalars.append(scalar)
        }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars.reversed())
        return String(result)
    }
}
