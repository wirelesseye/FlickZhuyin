import Foundation

enum ZhuyinInputToken: Hashable, Sendable {
    case symbol(Character)
    case tone(MandarinTone)
}

struct SyllableParser: Sendable {
    static let maximumSyllableLength = 3
    static let incompleteCost = 4.0
    static let fallbackCost = 12.0

    let completeSyllables: Set<String>
    let syllablePrefixes: Set<String>

    init(syllableBases: [String]) {
        var complete = Set<String>()
        var prefixes = Set<String>()
        for base in syllableBases {
            var prefix = ""
            for character in base {
                prefix.append(character)
                prefixes.insert(prefix)
            }
            complete.insert(base)
        }
        completeSyllables = complete
        syllablePrefixes = prefixes
    }

    init(store: any LexiconStore) throws {
        self.init(syllableBases: try store.syllableInventory())
    }

    func lattice(for tokens: [ZhuyinInputToken]) -> SyllableLattice {
        var outgoing = Array(repeating: [SyllableEdge](), count: tokens.count + 1)
        var index = 0
        while index < tokens.count {
            switch tokens[index] {
            case let .tone(tone):
                outgoing[index].append(
                    SyllableEdge(
                        tokenRange: index..<(index + 1),
                        constraint: SyllableConstraint(base: "", tone: tone),
                        completeness: .fallback,
                        parserCost: Self.fallbackCost
                    )
                )
            case .symbol:
                var runEnd = index
                while runEnd < tokens.count, case .symbol = tokens[runEnd] {
                    runEnd += 1
                }
                var createdEdge = false
                var length = 1
                while length <= Self.maximumSyllableLength, index + length <= runEnd {
                    let base = Self.text(of: tokens, in: index..<(index + length))
                    let tone: MandarinTone?
                    if index + length < tokens.count, case let .tone(value) = tokens[index + length] {
                        tone = value
                    } else {
                        tone = nil
                    }
                    let isComplete = completeSyllables.contains(base)
                    if isComplete || syllablePrefixes.contains(base) {
                        createdEdge = true
                        outgoing[index].append(
                            SyllableEdge(
                                tokenRange: index..<(index + length + (tone == nil ? 0 : 1)),
                                constraint: SyllableConstraint(base: base, tone: tone),
                                completeness: isComplete ? .complete : .incomplete,
                                parserCost: isComplete ? 0 : Self.incompleteCost
                            )
                        )
                    }
                    length += 1
                }
                if !createdEdge {
                    outgoing[index].append(
                        SyllableEdge(
                            tokenRange: index..<(index + 1),
                            constraint: SyllableConstraint(
                                base: Self.text(of: tokens, in: index..<(index + 1)),
                                tone: nil
                            ),
                            completeness: .fallback,
                            parserCost: Self.fallbackCost
                        )
                    )
                }
            }
            index += 1
        }
        return SyllableLattice(tokenCount: tokens.count, outgoingEdges: outgoing)
    }

    private static func text(of tokens: [ZhuyinInputToken], in range: Range<Int>) -> String {
        var result = ""
        for token in tokens[range] {
            if case let .symbol(character) = token {
                result.append(character)
            }
        }
        return result
    }
}
